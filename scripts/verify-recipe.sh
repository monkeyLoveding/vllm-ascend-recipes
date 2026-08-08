#!/usr/bin/env bash
# verify-recipe.sh — Run a recipe's vllm serve commands and verify the service.
#
# Usage:
#   ./scripts/verify-recipe.sh models/qwen/Qwen3-30B-A3B.yaml
#
# Exit codes:
#   0 — all scenarios verified successfully
#   1 — one or more scenario failed
#   2 — recipe skipped (no compatible hardware / unsupported / cache miss / multi-node only)
set -euo pipefail

RECIPE="$1"
STATUS=0
SKIPPED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*"; }

if [[ ! -f "$RECIPE" ]]; then
  log_error "Recipe file not found: $RECIPE"
  exit 1
fi

# Resolve the cache-paths alias file relative to this script's own location
# so it works in CI (working-directory=./recipes) and locally. Override via
# CACHE_PATHS_FILE for unusual layouts.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export CACHE_PATHS_FILE="${CACHE_PATHS_FILE:-${SCRIPT_DIR}/../models/_cache_paths.yaml}"
if [[ ! -f "$CACHE_PATHS_FILE" ]]; then
  log_error "Cache alias file not found: $CACHE_PATHS_FILE"
  exit 1
fi

# Determine Python to use (container may have multiple versions)
PYTHON=$(command -v python3.12 || command -v python3)
log_info "Using Python: $PYTHON ($($PYTHON --version 2>&1))"
log_info "=== Verifying recipe: $RECIPE ==="

# Determine which NPU hardware is available on this runner
# Use RECIPE_HW_KEY env var if set, otherwise default to atlas_800_a2
HW_KEY="${RECIPE_HW_KEY:-atlas_800_a2}"
log_info "Hardware key: $HW_KEY"

# Quick check that NPU is accessible
npu-smi info 2>/dev/null > /dev/null || {
  log_error "npu-smi not accessible. Is ascend-toolkit sourced?"
  exit 2
}

# ─────────────────────────────────────────────────────────────
# Parse YAML with Python helper (new structured format)
# ─────────────────────────────────────────────────────────────
parse_recipe() {
  $PYTHON - "$RECIPE" "$HW_KEY" "$CACHE_PATHS_FILE" <<'PYEOF'
import sys, os, re, json
import yaml

recipe_path, hw_key, cache_paths_file = sys.argv[1], sys.argv[2], sys.argv[3]

with open(recipe_path, 'r') as f:
    data = yaml.safe_load(f)

meta = data.get('meta', {})
model = data.get('model', {})
features = data.get('features', {}) or {}
opt_in_features = data.get('opt_in_features', []) or []
variants = data.get('variants', {}) or {}
compatible_strategies = data.get('compatible_strategies', []) or []
hw_overrides = data.get('hardware_overrides', {}) or {}

# ── 1. Hardware compatibility check ──────────────────────────
hardware = meta.get('hardware', {})
hw_status = hardware.get(hw_key, None)
if hw_status == 'unsupported':
    print(json.dumps({'action': 'skip', 'reason': f'Recipe marks {hw_key} as unsupported'}))
    sys.exit(0)

# ── 2. Resolve cache path ────────────────────────────────────
CACHE_BASE = '/root/.cache/modelscope/hub/models'
CACHE_PREFIXES = ('Eco-Tech', 'models')

model_id = model.get('model_id', '')
try:
    with open(cache_paths_file, 'r') as f:
        aliases_data = (yaml.safe_load(f) or {}).get('aliases') or []
except Exception as e:
    print(json.dumps({'action': 'skip', 'reason': f'cache_paths file parse error: {e}'}))
    sys.exit(0)

CACHE_DIR_BY_MODEL = {a['model_id']: a['cache_dir'] for a in aliases_data}
if model_id not in CACHE_DIR_BY_MODEL:
    print(json.dumps({
        'action': 'skip',
        'reason': f'weights not pre-cached, contact maintainer (model_id={model_id})',
    }))
    sys.exit(0)

cache_dir = CACHE_DIR_BY_MODEL[model_id]
CACHE_PATH = None
for prefix in CACHE_PREFIXES:
    candidate = os.path.join(CACHE_BASE, prefix, cache_dir)
    if os.path.isdir(candidate):
        CACHE_PATH = candidate
        if prefix != CACHE_PREFIXES[0]:
            print(f"DEBUG: cache resolved under non-default prefix '{prefix}/' for {model_id}", file=sys.stderr)
        break

if CACHE_PATH is None:
    print(json.dumps({
        'action': 'skip',
        'reason': f'weights not in runner image (model_id={model_id}, dir={cache_dir}, tried {list(CACHE_PREFIXES)})',
    }))
    sys.exit(0)

# ── 3. Hardware info ─────────────────────────────────────────
# NPU counts per hardware profile
HW_NPU_COUNT = {'atlas_800_a2': 8, 'atlas_800_a3': 16}
HW_PER_NPU_VRAM_GB = {'atlas_800_a2': 64, 'atlas_800_a3': 64}
npu_count = HW_NPU_COUNT.get(hw_key, 8)
per_npu_vram_gb = HW_PER_NPU_VRAM_GB.get(hw_key, 64)

architecture = model.get('architecture', 'dense')
is_moe = architecture == 'moe'

# ── 4. Select eligible strategy ──────────────────────────────
# Only run single_node_tp for automated verification.
# Multi-node and PD strategies require manual orchestration.
SINGLE_NODE_STRATEGIES = {'single_node_tp', 'single_node_tep', 'single_node_dep'}
eligible_strategy = None
for s in compatible_strategies:
    if s in SINGLE_NODE_STRATEGIES:
        eligible_strategy = s
        break

if eligible_strategy is None:
    print(json.dumps({
        'action': 'skip',
        'reason': f'no single-node strategy in compatible_strategies (found: {compatible_strategies})',
    }))
    sys.exit(0)

# ── 5. Merge args and env helpers ────────────────────────────
def merge_args(base, feat_args, variant_extra, hw_extra, smoke_args):
    """Merge args from all layers. Later layers can override earlier ones."""
    all_args = []
    all_args.extend(base)
    all_args.extend(feat_args)
    all_args.extend(variant_extra)
    all_args.extend(hw_extra)
    # Add smoke-test defaults after explicit args so they supplement, not override
    all_args.extend(smoke_args)
    return all_args

def merge_env(base_env, feat_env, variant_env, hw_env):
    """Merge env dicts. Later dicts override earlier ones."""
    merged = {}
    merged.update(base_env)
    merged.update(feat_env)
    merged.update(variant_env)
    merged.update(hw_env)
    return merged

def format_serve_command(cache_path, args_list):
    """Format a vllm serve command as a multi-line shell string."""
    lines = ['vllm serve ' + shquote(cache_path) + ' \\']
    for i, arg in enumerate(args_list):
        prefix = '    '
        suffix = ' \\' if i < len(args_list) - 1 else ''
        lines.append(prefix + shquote(str(arg)) + suffix)
    return '\n'.join(lines)

def shquote(s):
    """Shell-safe single-quote wrapping."""
    return "'" + str(s).replace("'", "'\"'\"'") + "'"

def format_env_block(env_dict):
    """Format env dict as shell export lines."""
    lines = []
    for k, v in sorted(env_dict.items()):
        lines.append(f"export {k}={shquote(str(v))}")
    return '\n'.join(lines)

# ── 6. Build scenarios per variant ───────────────────────────
# Pick TP size:
#   MoE on A2: TP=8 (all NPUs, with EP)
#   MoE on A3: TP=8 (half the chips, conservative smoke test)
#   Dense on A2: TP=8 (all NPUs)
#   Dense on A3: TP=8 (half, enough for any model < 512G)
# Smoke test uses TP=8 max to leave headroom; not optimizing for throughput.
tp_size = min(npu_count, 8)  # Cap at 8 for conservative smoke test

scenarios = []
for var_name, var in variants.items():
    precision = var.get('precision', 'bf16')
    vram_total_gb = var.get('vram_minimum_gb', 0)
    var_desc = var.get('description', var_name)

    # Per-NPU VRAM check
    vram_per_npu = vram_total_gb / tp_size if tp_size > 0 else vram_total_gb
    if vram_per_npu > per_npu_vram_gb * 0.85:
        print(f"DEBUG: skipping variant '{var_name}' — "
              f"VRAM per NPU {vram_per_npu:.0f}G > {per_npu_vram_gb * 0.85:.0f}G available",
              file=sys.stderr)
        continue

    # --- Collect features that are always-on (not opt-in) ---
    always_on_feat_args = []
    always_on_feat_env = {}
    for feat_name, feat in features.items():
        if feat_name not in opt_in_features:
            always_on_feat_args.extend(feat.get('args', []))
            always_on_feat_env.update(feat.get('env', {}))

    # --- Variant-specific ---
    var_extra_args = var.get('extra_args', [])
    var_extra_env = var.get('extra_env', {})

    # Check for variant model_id override (different checkpoint)
    var_model_id = var.get('model_id', None)
    if var_model_id:
        # Variant uses a different HF repo — need its own cache path
        if var_model_id in CACHE_DIR_BY_MODEL:
            var_cache_dir = CACHE_DIR_BY_MODEL[var_model_id]
            var_cache_path = None
            for prefix in CACHE_PREFIXES:
                candidate = os.path.join(CACHE_BASE, prefix, var_cache_dir)
                if os.path.isdir(candidate):
                    var_cache_path = candidate
                    break
            if var_cache_path is None:
                print(f"DEBUG: skipping variant '{var_name}' — "
                      f"variant model_id '{var_model_id}' not cached on runner",
                      file=sys.stderr)
                continue
            use_cache_path = var_cache_path
        else:
            print(f"DEBUG: skipping variant '{var_name}' — "
                  f"variant model_id '{var_model_id}' not in cache_paths",
                  file=sys.stderr)
            continue
    else:
        use_cache_path = CACHE_PATH

    # --- Hardware overrides ---
    hw = hw_overrides.get(hw_key, {}) or {}
    hw_extra_args = hw.get('extra_args', [])
    hw_extra_env = hw.get('extra_env', {})

    # --- Base ---
    base_args = model.get('base_args', [])
    base_env = model.get('base_env', {})

    # --- Smoke-test defaults ---
    smoke_args = [
        '--host', '0.0.0.0',
        '--port', '8000',
        '--tensor-parallel-size', str(tp_size),
        '--max-model-len', '8192',
        '--max-num-seqs', '4',
        '--gpu-memory-utilization', '0.9',
    ]
    if is_moe:
        # Ensure EP is present (may already be in base_args or features)
        if '--enable-expert-parallel' not in base_args + always_on_feat_args:
            smoke_args.insert(0, '--enable-expert-parallel')

    # --- Merge ---
    all_args = merge_args(base_args, always_on_feat_args, var_extra_args, hw_extra_args, smoke_args)
    all_env = merge_env(base_env, always_on_feat_env, var_extra_env, hw_extra_env)

    # --- Build serve command ---
    serve_cmd = format_serve_command(use_cache_path, all_args)
    env_block = format_env_block(all_env)

    # --- Build verification curl command ---
    # Auto-generate a standard chat completions smoke test
    verify_curl = (
        'curl -sf http://localhost:8000/v1/chat/completions '
        '-H "Content-Type: application/json" '
        '-d \'{"messages":[{"role":"user","content":"Hello"}],"max_tokens":32}\''
    )

    scenarios.append({
        'variant': var_name,
        'precision': precision,
        'strategy': eligible_strategy,
        'tp': tp_size,
        'description': var_desc,
        'vram_per_npu_gb': round(vram_per_npu, 1),
        'serve_cmd': serve_cmd,
        'verify_cmds': [verify_curl],
        'env_block': env_block,
        'cache_path': use_cache_path,
    })

if not scenarios:
    # All variants skipped (VRAM or cache issues)
    reasons = []
    for var_name, var in variants.items():
        vram_total_gb = var.get('vram_minimum_gb', 0)
        vram_per_npu = vram_total_gb / tp_size if tp_size > 0 else vram_total_gb
        if vram_per_npu > per_npu_vram_gb * 0.85:
            reasons.append(f"{var_name}: VRAM {vram_per_npu:.0f}G/npu > {per_npu_vram_gb * 0.85:.0f}G")
        else:
            reasons.append(f"{var_name}: weight not cached")
    print(json.dumps({
        'action': 'skip',
        'reason': f'no variant fits on {hw_key} ({"; ".join(reasons) if reasons else "unknown"})',
    }))
    sys.exit(0)

result = {
    'action': 'verify',
    'model_id': model_id,
    'min_vllm_version': model.get('min_vllm_version', ''),
    'hw_key': hw_key,
    'architecture': architecture,
    'cache_path': CACHE_PATH,
    'scenarios': scenarios,
}
print(json.dumps(result))
PYEOF
}

# ─────────────────────────────────────────────────────────────
# Execute parse_recipe and dispatch
# ─────────────────────────────────────────────────────────────
RECIPE_INFO=$(parse_recipe 2>/tmp/recipe-parse-debug.log || echo '{"action":"skip","reason":"parse error"}')

ACTION=$(echo "$RECIPE_INFO" | $PYTHON -c "import sys,json; print(json.loads(sys.stdin.read()).get('action','skip'))" 2>/dev/null || echo "skip")

if [[ "$ACTION" == "skip" ]]; then
  REASON=$(echo "$RECIPE_INFO" | $PYTHON -c "import sys,json; print(json.loads(sys.stdin.read()).get('reason','unknown'))" 2>/dev/null || echo "unknown")
  log_warn "Skipping recipe: $REASON"

  # Write a minimal params.json so publish-status.yml can refresh this
  # recipe's last_nightly_run.
  RECIPE_SLUG=$(basename "$RECIPE" .yaml)
  RUN_PARAMS_DIR="${RUN_PARAMS_DIR:-/tmp/verify-results}"
  mkdir -p "$RUN_PARAMS_DIR"
  MODEL_ID=$(echo "$RECIPE_INFO" | $PYTHON -c "import sys,json; print(json.loads(sys.stdin.read()).get('model_id',''))" 2>/dev/null || echo "")
  RECIPE_SLUG="$RECIPE_SLUG" MODEL_ID="$MODEL_ID" REASON="$REASON" RECIPE="$RECIPE" RUN_PARAMS_DIR="$RUN_PARAMS_DIR" \
  RECIPE_HW_KEY="$HW_KEY" HEAD_SHA="${HEAD_SHA:-}" TRIGGER_TYPE="${TRIGGER_TYPE:-nightly}" \
  VLLM_ASCEND_IMAGE="${VLLM_ASCEND_IMAGE:-}" STARTED_AT_ISO="${STARTED_AT_ISO:-}" \
  $PYTHON - <<'PYEOF' || log_warn "  Failed to write minimal params.json for skipped recipe"
import sys, json, os
out = os.path.join(os.environ['RUN_PARAMS_DIR'], f"{os.environ['RECIPE_SLUG']}.params.json")
with open(out, 'w') as f:
    json.dump({
        'recipe_path': os.environ['RECIPE'],
        'model_id': os.environ.get('MODEL_ID', ''),
        'hw_key': os.environ.get('RECIPE_HW_KEY', 'atlas_800_a2'),
        'head_sha': os.environ.get('HEAD_SHA', ''),
        'trigger_type': os.environ.get('TRIGGER_TYPE', 'nightly'),
        'image': os.environ.get('VLLM_ASCEND_IMAGE', ''),
        'started_at': os.environ.get('STARTED_AT_ISO', ''),
        'scenarios': [],
        'skip_reason': os.environ['REASON'],
    }, f, indent=2, ensure_ascii=False)
print(f'[PARAMS] wrote (skip) {out}', file=sys.stderr)
PYEOF

  exit 2
fi

MODEL_ID=$(echo "$RECIPE_INFO" | $PYTHON -c "import sys,json; print(json.loads(sys.stdin.read()).get('model_id',''))")
CACHE_PATH=$(echo "$RECIPE_INFO" | $PYTHON -c "import sys,json; print(json.loads(sys.stdin.read()).get('cache_path',''))")
export CACHE_PATH
log_info "Model: $MODEL_ID"
log_info "Cached weights: $CACHE_PATH"
log_info "Hardware: $(echo "$RECIPE_INFO" | $PYTHON -c "import sys,json; print(json.loads(sys.stdin.read()).get('hw_key',''))")"
log_info "Architecture: $(echo "$RECIPE_INFO" | $PYTHON -c "import sys,json; print(json.loads(sys.stdin.read()).get('architecture',''))")"

# ── Verify vllm is installed ─────────────────────────────────
if command -v vllm &>/dev/null; then
  log_info "vllm ready: $(vllm --version 2>&1 | head -1 || true)"
else
  log_error "vllm not found in image, cannot proceed"
  exit 1
fi

# ── Verify each scenario ─────────────────────────────────────
SCENARIO_COUNT=$(echo "$RECIPE_INFO" | $PYTHON -c "
import sys,json
print(len(json.loads(sys.stdin.read()).get('scenarios',[])))
")
log_info "Found $SCENARIO_COUNT scenario(s) to verify"

# For smoke test, only verify the first scenario per recipe
if [[ "${CI_RUNNER_SMOKE:-0}" == "1" ]]; then
  log_info "SMOKE MODE: verifying first scenario only"
fi

echo "$RECIPE_INFO" | $PYTHON -c "
import sys,json,os
info = json.loads(sys.stdin.read())
with open('/tmp/scenario_list.txt', 'w') as flist:
    for i, s in enumerate(info.get('scenarios',[])):
        serve = s.get('serve_cmd','')
        verify = '\n'.join(s.get('verify_cmds',[]))
        env_block = s.get('env_block','')
        with open(f'/tmp/scenario_{i}_serve.sh', 'w') as f:
            f.write(serve)
        with open(f'/tmp/scenario_{i}_verify.sh', 'w') as f:
            f.write(verify)
        with open(f'/tmp/scenario_{i}_env.sh', 'w') as f:
            f.write(env_block)
        flist.write(
            f\"{i}|{s['variant']}|{s['precision']}|{s['strategy']}|{s['description']}|{s['tp']}|{s.get('vram_per_npu_gb','')}\n\"
        )

# === Dump execution params (consumed by publish-status workflow) ===
PARAMS_DIR = os.environ.get('RUN_PARAMS_DIR', '/tmp/verify-results')
HEAD_SHA = os.environ.get('HEAD_SHA', '')
TRIGGER_TYPE = os.environ.get('TRIGGER_TYPE', 'pr')
VLLM_IMAGE = os.environ.get('VLLM_ASCEND_IMAGE', '')
RECIPE_PATH_IN = os.environ.get('RECIPE_YAML_PATH', '')

out_scenarios = []
for i, s in enumerate(info.get('scenarios', [])):
    out_scenarios.append({
        'index': i,
        'variant': s.get('variant', ''),
        'precision': s.get('precision', ''),
        'strategy': s.get('strategy', ''),
        'tp': s.get('tp', 0),
        'vram_per_npu_gb': s.get('vram_per_npu_gb', 0),
        'serve_cmd': s.get('serve_cmd', ''),
    })

recipe_slug = os.path.basename(RECIPE_PATH_IN).replace('.yaml', '') if RECIPE_PATH_IN else 'recipe'
if recipe_slug == 'recipe':
    recipe_slug = os.environ.get('RECIPE_YAML_PATH', 'recipe').split('/')[-1].replace('.yaml', '')

import os as _os
_os.makedirs(PARAMS_DIR, exist_ok=True)
params_doc = {
    'recipe_path': RECIPE_PATH_IN,
    'model_id': info.get('model_id', ''),
    'hw_key': info.get('hw_key', ''),
    'head_sha': HEAD_SHA,
    'trigger_type': TRIGGER_TYPE,
    'image': VLLM_IMAGE,
    'started_at': os.environ.get('STARTED_AT_ISO', ''),
    'scenarios': out_scenarios,
}
out_path = _os.path.join(PARAMS_DIR, f'{recipe_slug}.params.json')
with open(out_path, 'w') as fp:
    json.dump(params_doc, fp, indent=2, ensure_ascii=False)
print(f'[PARAMS] wrote {out_path}', file=sys.stderr)
"

# ── Run each scenario ────────────────────────────────────────
while IFS='|' read -r idx variant precision strategy desc tp vram_npu; do
  [ -z "$idx" ] && continue

  if [[ "${CI_RUNNER_SMOKE:-0}" == "1" ]] && [[ "$idx" != "0" ]]; then
    continue
  fi

  SERVE_CMD=$(cat "/tmp/scenario_${idx}_serve.sh" 2>/dev/null || echo "")
  VERIFY_CMD=$(cat "/tmp/scenario_${idx}_verify.sh" 2>/dev/null || echo "")
  ENV_BLOCK=$(cat "/tmp/scenario_${idx}_env.sh" 2>/dev/null || echo "")

  log_info "--- Scenario [$idx]: $variant / $precision / $strategy / $desc ---"
  log_info "  TP=$tp, VRAM/npu ~${vram_npu}G"

  if [[ -z "$SERVE_CMD" ]]; then
    log_warn "  No vllm serve command, skipping"
    SKIPPED=1
    continue
  fi

  # ── Build the run script ────────────────────────────────────
  VLLM_SCRIPT="/tmp/vllm_serve_${idx}.sh"
  cat > "$VLLM_SCRIPT" <<SCRIPT_HEREDOC
#!/usr/bin/env bash
set -eo pipefail
. /usr/local/Ascend/ascend-toolkit/set_env.sh 2>/dev/null || true
export PATH="/usr/local/bin:/root/.local/bin:\$PATH"
SCRIPT_HEREDOC

  # Append env vars before serve command
  if [[ -n "$ENV_BLOCK" ]]; then
    echo "$ENV_BLOCK" >> "$VLLM_SCRIPT"
  fi
  # Append serve command
  echo "$SERVE_CMD" >> "$VLLM_SCRIPT"
  chmod +x "$VLLM_SCRIPT"

  log_info "  Starting vllm serve..."
  bash "$VLLM_SCRIPT" &
  SERVE_PID=$!

  # Wait for /v1/models to become ready
  log_info "  Waiting for server ready..."
  READY=0
  for i in $(seq 1 300); do
    if curl -sf http://localhost:8000/v1/models > /dev/null 2>&1; then
      READY=1
      log_info "  Server ready after ${i}s"
      break
    fi
    if [[ $((i % 30)) -eq 0 ]]; then
      log_info "  Still waiting... (${i}s elapsed)"
    fi
    sleep 2
  done

  if [[ "$READY" -eq 0 ]]; then
    log_error "  Server failed to become ready within 600s"
    kill $SERVE_PID 2>/dev/null || true
    STATUS=1
    continue
  fi

  # Verify /v1/models returns expected content
  MODELS_RESP=$(curl -sf http://localhost:8000/v1/models)
  if echo "$MODELS_RESP" | grep -qi "model"; then
    log_info "  /v1/models OK"
  else
    log_error "  /v1/models returned unexpected response"
    kill $SERVE_PID 2>/dev/null || true
    STATUS=1
    continue
  fi

  # Run curl verification commands
  if [[ -n "$VERIFY_CMD" ]]; then
    log_info "  Running recipe verification commands..."
    CURL_SCRIPT="/tmp/curl_verify_${idx}.sh"
    echo "#!/usr/bin/env bash" > "$CURL_SCRIPT"
    echo "set -eo pipefail" >> "$CURL_SCRIPT"
    echo "$VERIFY_CMD" >> "$CURL_SCRIPT"
    chmod +x "$CURL_SCRIPT"
    RESP=$(bash "$CURL_SCRIPT" 2>&1 || echo "CURL_FAILED")
    if echo "$RESP" | grep -qi "CURL_FAILED"; then
      log_error "  Recipe curl verification FAILED"
      STATUS=1
    else
      log_info "  Recipe curl verification PASSED"
      log_info "  ====== CURL RESPONSE ======"
      echo "$RESP" | while IFS= read -r rline; do log_info "  | $rline"; done
      log_info "  ====== END ======"
    fi
  fi

  # Run aisbench performance evaluation (Section 8 of tutorial)
  if command -v ais_bench &>/dev/null; then
    log_info "  Running aisbench performance evaluation..."
    AIS_CFG="/usr/local/python3.12.13/lib/python3.12/site-packages/ais_bench/benchmark/configs/models/vllm_api/vllm_api_stream_chat.py"
    if [[ -f "$AIS_CFG" ]]; then
      sed -i "s|path=\".*\"|path=\"${CACHE_PATH}\"|" "$AIS_CFG"
      sed -i 's|host_port=8080|host_port=8000|' "$AIS_CFG"
      log_info "  Patched ais_bench model config (path + port)"
    fi
    BENCH_OUTPUT=$(ais_bench --models vllm_api_stream_chat --datasets synthetic_gen --mode perf --debug --num-prompts 50 2>&1 || echo "AISBENCH_FAILED")
    echo "$BENCH_OUTPUT" | tail -30
    BENCH_FILE="/tmp/verify-results/$(basename "$RECIPE" .yaml).bench"
    echo "===== AISBENCH PERFORMANCE =====" > "$BENCH_FILE"
    echo "$BENCH_OUTPUT" >> "$BENCH_FILE"
    echo "===== END =====" >> "$BENCH_FILE"
    log_info "  Benchmark saved to $BENCH_FILE"
  else
    log_warn "  ais_bench not available, skipping benchmark"
    echo "benchmark_skipped" > "/tmp/verify-results/$(basename "$RECIPE" .yaml).bench"
  fi

  # Kill the server and all children
  log_info "  Stopping vllm serve..."
  if [[ -n "$SERVE_PID" ]] && kill -0 $SERVE_PID 2>/dev/null; then
    kill -TERM -- -$SERVE_PID 2>/dev/null || kill $SERVE_PID 2>/dev/null || true
    sleep 2
    kill -KILL -- -$SERVE_PID 2>/dev/null || kill -9 $SERVE_PID 2>/dev/null || true
    timeout 30 wait $SERVE_PID 2>/dev/null || true
  fi
  # Force cleanup any remaining vllm processes
  pkill -f "vllm serve" 2>/dev/null || true
  log_info "  Server stopped."

  if [[ "$STATUS" -ne 0 ]]; then
    log_error "FAILED: $MODEL_ID variant=$variant strategy=$strategy [$idx]"
  else
    log_info "PASSED: $MODEL_ID variant=$variant strategy=$strategy [$idx]"
  fi
done < /tmp/scenario_list.txt

# ── Exit code ────────────────────────────────────────────────
#   1 = fail    — at least one scenario actually failed
#   2 = skip    — every scenario was auto-skipped
#   0 = pass    — every scenario verified
if [[ "$STATUS" -gt 0 ]]; then
  exit 1
fi
if [[ "$SKIPPED" -gt 0 ]]; then
  exit 2
fi

exit 0
