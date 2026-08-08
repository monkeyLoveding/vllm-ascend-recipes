/**
 * i18n translations for vllm-ascend-recipes.
 * English is the primary language; Chinese translations are provided for UI labels.
 */

const translations = {
  en: {
    // Header / Navigation
    siteTitle: "vLLM Ascend Recipes",
    browse: "Browse",
    docs: "Docs",
    github: "GitHub",

    // Homepage
    heroDescription:
      "Pick a model, adjust for your Ascend NPUs, copy the vllm serve line that runs.",
    latestRecipes: "Latest recipes",
    browseByProvider: "Browse by provider",
    viewAll: "View all",
    recipes: "recipes",
    recipe: "recipe",

    // Recipe detail
    viewOnModelScope: "View on ModelScope",
    viewOnHuggingFace: "View on HuggingFace",
    editRecipe: "Edit recipe",
    reportIssue: "Report issue",
    updated: "Updated",
    guide: "Guide",
    related: "Related",

    // Command Builder
    hardware: "Hardware",
    variant: "Variant",
    strategy: "Strategy",
    nodes: "Nodes",
    kvOffload: "KV Offload",
    features: "Features",
    advanced: "Advanced",
    copy: "Copy",
    copied: "Copied",
    curl: "cURL",
    bench: "Bench",
    docker: "Docker",
    install: "Install",
    serve: "Serve",
    head: "Head",
    worker: "Worker",
    prefill: "Prefill",
    decode: "Decode",
    router: "Router",

    // Search
    searchPlaceholder: "Search models...",
    noResults: "No models found",

    // Status badge
    ciStatus: "CI Status",
    pass: "Pass",
    fail: "Fail",
    skip: "Skip",
    viewDetails: "View execution details",

    // Footer
    requestRecipe: "Request a recipe",
    documentation: "Documentation",
    supportedModels: "Supported Models & Hardware",
    installVllm: "Install vLLM Ascend",
    jsonApi: "JSON API",
  },

  zh: {
    // Header / Navigation
    siteTitle: "vLLM Ascend Recipes",
    browse: "浏览",
    docs: "文档",
    github: "GitHub",

    // Homepage
    heroDescription:
      "选择模型，调整 Ascend NPU 配置，复制 vllm serve 命令即可运行。",
    latestRecipes: "最新 Recipes",
    browseByProvider: "按厂商浏览",
    viewAll: "查看全部",
    recipes: "个 Recipes",
    recipe: "个 Recipe",

    // Recipe detail
    viewOnModelScope: "在 ModelScope 查看",
    viewOnHuggingFace: "在 HuggingFace 查看",
    editRecipe: "编辑 Recipe",
    reportIssue: "报告问题",
    updated: "更新于",
    guide: "指南",
    related: "相关",

    // Command Builder
    hardware: "硬件",
    variant: "变体",
    strategy: "策略",
    nodes: "节点",
    kvOffload: "KV 卸载",
    features: "功能",
    advanced: "高级",
    copy: "复制",
    copied: "已复制",
    curl: "cURL",
    bench: "压测",
    docker: "Docker",
    install: "安装",
    serve: "启动",
    head: "主节点",
    worker: "工作节点",
    prefill: "Prefill",
    decode: "Decode",
    router: "路由",

    // Search
    searchPlaceholder: "搜索模型...",
    noResults: "未找到模型",

    // Status badge
    ciStatus: "CI 状态",
    pass: "通过",
    fail: "失败",
    skip: "跳过",
    viewDetails: "查看执行详情",

    // Footer
    requestRecipe: "请求添加 Recipe",
    documentation: "文档",
    supportedModels: "支持的模型和硬件",
    installVllm: "安装 vLLM Ascend",
    jsonApi: "JSON API",
  },
};

/**
 * Get translation for a given key and language.
 * @param {string} lang - 'en' | 'zh'
 * @param {string} key - translation key
 * @returns {string}
 */
export function t(lang, key) {
  return translations[lang]?.[key] || translations.en[key] || key;
}

/**
 * Get the full translations object for a given language.
 * @param {string} lang
 * @returns {object}
 */
export function getTranslations(lang) {
  return translations[lang] || translations.en;
}
