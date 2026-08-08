# vllm-ascend-recipes 上游格式迁移总结

## 迁移目标

将 `vllm-ascend-recipes` 项目从自定义 Astro + 场景级联（NPU→Precision→Deployment→Case）方案迁移到与上游 [vllm-project/recipes](https://github.com/vllm-project/recipes) 一致的 **Next.js + Command Builder** 交互式命令生成方案。

## 架构对比

| 维度 | 迁移前 (Astro) | 迁移后 (Next.js) |
|------|-----------|-----------|
| 框架 | Astro 7 + React islands | Next.js 15 App Router |
| 内容模型 | 步骤式部署指南（700行/YAML） | 模型元数据 + 交互式命令合成 |
| UI 范式 | CascadeSelector（场景级联选择） | CommandBuilder（硬件→变体→策略→功能→KV卸载） |
| 硬件定义 | 每个 recipe YAML 内联 | 集中在 taxonomy.yaml |
| 策略定义 | 内嵌在场景步骤中 | 独立的 strategies/*.yaml |
| i18n | EN+ZH（SSR data-i18n + useLang） | EN+ZH（localStorage + guide_zh） |
| 部署 | GitHub Pages + Netlify PR 预览 | GitHub Pages + Netlify PR 预览（保留） |
| CI 验证 | Ascend NPU 自托管 runner | 保留 Ascend NPU CI 验证流水线 |

## 核心变更清单

### 1. 前端框架替换

**移除的文件：**
- `src/` → `src_astro/`（保留作为参考）
- `astro.config.mjs`, `.prettierrc.json`, `.prettierignore`
- `tsconfig.json`（Astro extends astro/tsconfigs/strict）
- OG image edge route（不兼容 `output: 'export'`）
- `robots.js`, `sitemap.js`（动态路由，不兼容静态导出）
- `@vercel/analytics`（GitHub Pages 不需要）

**新增的文件（来自上游 D:\project\VLLM\recipes）：**
- `src/`（Next.js 15 App Router 源码）
  - `src/app/layout.js` — 根布局（已适配 Ascend 品牌链接和 LanguageToggle）
  - `src/app/page.js` — 首页 `RecipeCardGrid`
  - `src/app/[org]/layout.js` — 模型侧边栏布局
  - `src/app/[org]/page.js` — 组织页面
  - `src/app/[org]/[repo]/page.js` — **Recipe 详情页**（已适配 guide_zh）
  - `src/app/browse/page.js` — 浏览页面
  - `src/components/recipes/CommandBuilder.jsx` — **交互式命令构建器**（核心组件，3600+ 行）
  - `src/components/recipes/RecipeCardGrid.jsx` — 首页卡片网格
  - `src/components/recipes/ModelSidebar.jsx` — 模型导航侧栏
  - `src/components/recipes/SearchBox.jsx` — ⌘K 搜索框
  - `src/components/recipes/BrowseList.jsx` — 浏览列表
  - `src/components/recipes/DeployDialog.jsx` — 部署对话框
  - `src/components/ui/` — UI 基础组件（badge, card, tooltip, theme-toggle）
  - `src/lib/command-synthesis.js` — **命令合成引擎**（纯函数，1750+ 行）
  - `src/lib/recipes.js` — YAML 加载和缓存
  - `src/lib/strategies.js` — 策略加载
  - `src/lib/taxonomy.js` — 分类加载
  - `src/lib/platforms.js` — 平台加载
  - `src/lib/providers.js` — Provider 元数据
  - 其他工具库文件
- `taxonomy.yaml`（已扩展 Ascend 硬件）
- `platforms.yaml`
- `strategies/`（9 个策略 YAML）
- `kv_store/`（2 个 KV 存储部署 YAML）
- `scripts/build-recipes-api.mjs`（JSON API 生成器 + 验证器）
- `scripts/fetch-provider-logos.mjs`
- `scripts/fetch-hf-dates.mjs`
- `next.config.mjs`（已配置 `output: 'export'`, `basePath: '/vllm-ascend-recipes'`）
- `postcss.config.mjs`
- `jsconfig.json`

### 2. 数据格式转换

**关键决策：** Recipe 从详细的步骤式指南（700+ 行）转换为紧凑的模型元数据格式（~200 行）。

**YAML 字段映射：**

| 旧字段 | 新字段 | 转换说明 |
|--------|--------|----------|
| `meta.*` | `meta.*` | 大部分直接映射，新增 `date_updated`、`title_zh`、`description_zh` |
| `meta.hardware.atlas_800_a3: verified` | `meta.hardware.atlas_800_a3: verified` | 硬件 key 名改为 taxonomy 中的 ID |
| `meta.related_recipes` | `meta.related_recipes` | 格式从 `[slug]` 改为 `["org/repo"]` |
| `model.model_id` | `model.model_id` | 直接映射 |
| `model.min_vllm_version` | `model.min_vllm_version` | 直接映射 |
| `model.architecture` | `model.architecture` | 直接映射 |
| `model.parameter_count` | `model.parameter_count` | 直接映射 |
| `model.active_parameters` | `model.active_parameters` | 直接映射 |
| `model.context_length` | `model.context_length` | 直接映射 |
| `model.modality: text` | `meta.tasks: [text]` | 模态转为任务标签 |
| — | `model.base_args` | **新增**：每个模型的基础参数 |
| — | `model.base_env` | **新增**：每个模型的基础环境变量 |
| `overview` | `guide` | Markdown 文档合并到 guide |
| `prerequisites` | `guide` | Markdown 文档合并到 guide |
| `env_setup.pip.content` | `guide` | 安装说明合并到 guide |
| `env_setup.container` | `guide` | Docker 说明合并到 guide |
| `weight_download` | `guide` | 下载说明合并到 guide |
| `scenarios[]` | **`variants{}` + `compatible_strategies[]` + `hardware_overrides`** | **最大变更** |
| `scenarios[].npu` | `hardware_overrides.<gen>` | NPU 类型→硬件覆盖 |
| `scenarios[].precision` | `variants.<key>.precision` | 精度→变体 |
| `scenarios[].deployment` | `compatible_strategies` | 部署方式→策略列表 |
| `scenarios[].steps[]` | `guide` | 步骤内容→guide Markdown |
| `extra_config[]` | `features{}` + `opt_in_features[]` | 配置项→功能开关 |
| `performance` | `guide` | 性能数据→guide "Benchmarking" |
| `verification` | `guide` | 验证步骤→guide "Service Verification" |
| `tuning` | `guide` | 调优指南→guide "Troubleshooting" |
| `faq` | `guide` | FAQ→guide "Troubleshooting" |
| `references` | `guide` | 参考链接→guide "References" |
| `evaluation` | `guide` | 评估数据→guide "Accuracy Results" |
| — | `variants.default` | **新增**：默认精度变体 |
| — | `variants.<precision>` | **新增**：其他精度变体 |
| — | `compatible_strategies` | **新增**：从 scenarios 分析得出 |
| — | `hardware_overrides.<gen>` | **新增**：Ascend 特定环境变量和参数 |
| — | `guide_zh` | **新增**：中文版 guide |

### 3. Ascend NPU 硬件适配

**taxonomy.yaml 新增：**
- `atlas_800_a2`（brand: Ascend, gpu_count: 8, vram_gb: 1024, restricted: true）
- `atlas_800_a3`（brand: Ascend, gpu_count: 8, vram_gb: 1024, restricted: true）
- `atlas_300t_a2`（brand: Ascend, gpu_count: 1, vram_gb: 64, scalable: false, restricted: true）

**command-synthesis.js 关键修改：**
- `computeDockerMeta()`：
  - DEFAULT_IMAGE 新增 `ascend: "quay.io/ascend/vllm-ascend:latest"`
  - 新增 `isAscend` 检测
  - brandKey 新增 `"ascend"` 分支
- Docker GPU flags（Ascend 不使用 `--gpus all`）：
  - 改为挂载 NPU 设备：`--device=/dev/davinci_manager --device=/dev/devmm_svm --device=/dev/hisi_hdc`
  - Ascend 驱动挂载：`-v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro`
  - `--security-opt seccomp=unconfined`
- `dockerGpuArgv()`：新增 Ascend 设备的 argv 形式

### 4. i18n 双语支持

**新增文件：**
- `src/lib/i18n.js` — 翻译字典（EN + ZH），约 50 个 UI 标签
- `src/components/ui/language-toggle.jsx` — 语言切换按钮（EN/中文）
  - 使用 localStorage + `langchange` CustomEvent 机制
  - `useLang()` hook 供客户端组件使用

**页面适配：**
- `src/app/layout.js` — Header 导航栏添加 `LanguageToggle`
- `src/app/[org]/[repo]/page.js` — Recipe 详情页同时渲染 `guide` 和 `guide_zh`
  - 通过 CSS class（`.guide-en` / `.guide-zh`）控制显示
  - 内联脚本监听 `langchange` 事件切换可见性

### 5. GitHub Pages 部署适配

**next.config.mjs：**
- `output: 'export'`（静态导出）
- `basePath: '/vllm-ascend-recipes'`（匹配 GitHub Pages URL）
- `images.unoptimized: true`（静态导出需要）

**site-url.js：**
- 硬编码为 `https://vllm-ascend.github.io/vllm-ascend-recipes`
- 移除 Vercel 动态 URL 检测

**deploy.yml：**
- 构建输出从 `./dist` 改为 `./out`（Next.js 静态导出目录）
- 移除 `validate YAML` 步骤（现在由 `build-recipes-api.mjs` 作为构建步骤执行）

**preview-build.yml：**
- 构建命令从 `pnpm exec astro build` 改为 `pnpm build`
- 添加 `NEXT_TELEMETRY_DISABLED: '1'`

### 6. 保留的 CI/CD 流水线

以下文件保留不变或仅做最小适配：
- `.github/workflows/deploy.yml`（适配输出路径）
- `.github/workflows/preview-build.yml`（适配构建命令）
- `.github/workflows/preview-deploy.yml`（不变）
- `.github/workflows/publish-status.yml`（不变）
- `.github/workflows/_recipe_verify.yml`（待适配新 YAML 格式）
- `.github/workflows/pr-recipe-verify.yml`（待适配）
- `.github/workflows/nightly-recipe-verify.yml`（待适配）
- `.github/workflows/lint.yml`（待适配 Next.js）
- `scripts/verify-recipe.sh`（待适配新 YAML 格式）
- `.github/_scripts/publish_skeleton.py`（待适配）

## 关键技术难点

### 难点 1：场景级联 → 命令合成的范式转换

**问题：** 旧方案中每个 scenario 包含预编写的完整 `vllm serve` 命令，新方案需要将模型元数据输入给 command-synthesis 引擎动态合成。

**解决：**
- 从 scenarios 提取 precision → `variants{}`
- 从 deployment 映射 → `compatible_strategies[]`（单节点-多卡→single_node_tp 等）
- 从步骤中的 env vars → `hardware_overrides.<gen>.extra_env`
- 从步骤中的 args → `model.base_args` + `hardware_overrides.<gen>.extra_args`
- 配置模板（`%%CONFIG:key%%`）→ `features{}`（如 spec_decoding, quantization）

### 难点 2：Ascend NPU 在 command-synthesis 中的处理

**问题：** 上游 command-synthesis 围绕 NVIDIA/AMD/Intel GPU 设计，使用 `--gpus all`、`CUDA_VISIBLE_DEVICES` 等。

**解决：**
- 在 `computeDockerMeta()` 中新增 `brand: Ascend` 分支
- Ascend 使用 NPU 设备挂载替代 `--gpus all`
- Ascend 使用 `quay.io/ascend/vllm-ascend` 镜像
- `ASCEND_RT_VISIBLE_DEVICES` 通过 recipe 的 `hardware_overrides.extra_env` 传递
- 不需要修改 Mooncake KV store 逻辑（Ascend 暂不支持）

### 难点 3：i18n 在不修改上游架构的前提下添加

**问题：** 上游是纯英文的，所有组件和页面都硬编码英文标签。

**解决：**
- 采用最小侵入方案：新增文件而非修改已有文件
- `LanguageToggle` 为独立组件，在 layout.js 中插入
- Recipe 详情页通过 inline script + CSS class 切换 guide 语言
- 翻译字典独立在 `i18n.js` 中，未修改 CommandBuilder 内部的 UI 标签（留给后续迭代）
- 中英双语 guide 通过 `guide` 和 `guide_zh` 两个字段承载，URL 结构不变

### 难点 4：Next.js 静态导出 (`output: 'export'`) 的限制

**问题：** 上游依赖 Vercel 部署，使用了 Edge Runtime（OG image generation）和动态路由处理器（robots.js, sitemap.js），这些都不兼容 `output: 'export'`。

**解决：**
- 删除 `src/app/og/route.js`（OG image 可在后续用构建脚本预生成静态图片替代）
- 删除 `src/app/robots.js` 和 `src/app/sitemap.js`（可用 `public/robots.txt` 和 `public/sitemap.xml` 替代）
- 移除 `@vercel/analytics` 依赖

### 难点 5：旧项目残留文件冲突

**问题：** 旧 Astro 项目的配置文件（tsconfig.json、eslint.config.mjs）会干扰 Next.js 构建。

**解决：**
- 删除 `tsconfig.json`（上游使用 `jsconfig.json`，纯 JS 项目）
- 更新 `eslint.config.mjs` 为 Next.js 兼容格式（使用 `@eslint/eslintrc` FlatCompat）
- 旧 `models/en/` 和 `models/zh/` 移到 `models_old_en/` 和 `models_old_zh/`

### 难点 6：Windows Server 构建环境内存限制

**问题：** 当前 Windows Server 2019 环境内存不足以完成 Next.js 15 构建（出现 JS OOM 和 segfault）。

**解决：**
- 本地开发使用 `next dev`（内存占用小）
- CI 构建在 GitHub Actions ubuntu-latest 上执行（7GB+ RAM，足够）
- 本地文件级验证（YAML 格式、import 路径）替代完整构建验证

## Recipe 转换示例

以 Qwen3-30B-A3B 为例（`models/qwen/Qwen3-30B-A3B.yaml`）：

**转换前（旧格式）：**
- 700+ 行 YAML
- 2 个 scenarios（A3 和 A2）
- 每个 scenario 包含完整的 vllm serve 命令和环境变量
- 独立字段：weight_download, env_setup, evaluation, performance, tuning, faq

**转换后（新格式）：**
- ~200 行 YAML
- `variants`: `default` (w8a8), `bf16`
- `compatible_strategies`: `[single_node_tp]`
- `hardware_overrides`: `ascend_a3` 和 `ascend_a2`（各自的 extra_env + extra_args）
- `features`: `spec_decoding` (Eagle3), `quantization_ascend`
- `base_args`: 所有场景通用的基础参数
- `guide` / `guide_zh`: 详细的 Markdown 文档

## 待完成工作

1. **转换剩余 8+ 个 recipes**（按优先级：DeepSeek-V4-Flash, Qwen3-235B-A22B, GLM-5.2 等）
2. **CommandBuilder UI 中文翻译**（当前只翻译了页面级别，CommandBuilder 内部标签仍是英文）
3. **适配 verify-recipe.sh**（从新 YAML 格式提取 model_id、variants、base_args）
4. **适配 CI lint.yml**（Next.js 的 lint 而非 Astro）
5. **适配 _recipe_verify.yml**（指向新的 models/ 目录结构）
6. **添加 Ascend provider logos**（Huawei/Ascend logo 放在 public/providers/）
7. **OG image 替代方案**（构建时预生成静态 OG 图片）
8. **robots.txt 和 sitemap.xml**（创建静态文件放在 public/）
9. **清理 src_astro/**（确认所有引用已迁移后删除）
10. **在 CI 环境中验证完整构建**（GitHub Actions 上有足够内存）

## 文件统计

| 类别 | 新增 | 修改 | 删除/移动 |
|------|------|------|-----------|
| 前端源码 (src/) | ~50 文件 | 5 文件 | ~30 文件→src_astro/ |
| 数据文件 | 1 recipe | - | 9 旧 format→models_old/ |
| 配置文件 | 3 (next, postcss, jsconfig) | 3 (package.json, taxonomy, eslint) | 3 (astro, prettier, tsconfig) |
| CI/workflows | - | 2 (deploy, preview-build) | - |
| 策略/分类 | 12 (strategies + kv_store + 2 yaml) | - | - |
| 脚本 | 4 (build-recipes-api + 3 fetch) | - | - |
| i18n | 2 (i18n.js + language-toggle) | - | - |

---

*迁移日期：2026-08-07*
*代码审查：wangqi*
