import { defineConfig } from 'vitepress'

// FilesCodeBox 文档站。
// 内容真相源: hub 仓库 docs/ 目录(本目录的 ../docs)。内容页通过 VitePress 的
// <!--@include: --> 指令原样引入 hub 文档, hub 侧更新后站点内容自动同步;
// 本目录只维护站点壳(首页/导航/侧边栏)与少量手写页, 详见 docs-site/README.md。

export default defineConfig({
  lang: 'zh-CN',
  title: 'FilesCodeBox 文档',
  description:
    'FilesCodeBox(文件快递柜) — 匿名口令分享文本/文件的开源自托管平台: 多用户、API Token、多存储后端(S3/WebDAV/云厂商)、Kubernetes/Helm、MCP AI 集成。',

  // 本目录的 README.md 是贡献者文档, 不是站点内容, 排除出路由
  srcExclude: ['README.md'],

  // 被引入的 hub docs/*.md 内部含有指向仓库根/同目录的相对链接
  // (architecture.md 的 ../README.md、DEPLOY-COMPOSE.md 的 ENVIRONMENT_VARIABLES.md),
  // 它们在 GitHub 仓库内有效, 但无法映射为本站路由。仅放行这两类死链(注意
  // VitePress 对链接做规范化: 去掉 .md 后缀、补 ./ 前缀, 正则同时覆盖两种形式),
  // 不使用 ignoreDeadLinks: true —— 手写页与站内链接仍受死链检查约束。
  ignoreDeadLinks: [
    /^(\.\/|\.\.\/)*README(\.md)?($|#)/,
    /^(\.\/|\.\.\/)*ENVIRONMENT_VARIABLES(\.md)?($|#)/
  ],

  themeConfig: {
    siteTitle: 'FilesCodeBox',

    nav: [
      {
        text: '指南',
        items: [
          { text: '首页', link: '/' },
          { text: '快速开始', link: '/guide/getting-started' },
          { text: '部署 Docker', link: '/guide/deploy-docker' },
          { text: '部署 Kubernetes', link: '/guide/deploy-kubernetes' },
          { text: '环境变量', link: '/guide/environment' }
        ]
      },
      { text: '架构', link: '/reference/architecture' },
      {
        text: 'API',
        items: [
          { text: 'API Token', link: '/reference/api-tokens' },
          { text: 'MCP 集成', link: '/reference/mcp' }
        ]
      }
    ],

    sidebar: [
      {
        text: '指南',
        items: [
          { text: '快速开始', link: '/guide/getting-started' },
          { text: '部署 Docker Compose', link: '/guide/deploy-docker' },
          { text: '部署 Kubernetes (Helm)', link: '/guide/deploy-kubernetes' },
          { text: '环境变量参考', link: '/guide/environment' },
          { text: 'v0.3 升级说明', link: '/guide/upgrade' }
        ]
      },
      {
        text: '架构与设计',
        items: [
          { text: '架构总览', link: '/reference/architecture' },
          { text: '设计: API Token', link: '/reference/design/api-token' },
          { text: '设计: 存储点亮与引导', link: '/reference/design/storage-lightup' },
          { text: '设计: 上传治理', link: '/reference/design/upload-governance' },
          { text: '设计: 上传治理计划', link: '/reference/design/upload-governance-plan' }
        ]
      },
      {
        text: 'API 与集成',
        items: [
          { text: 'API Token 指南', link: '/reference/api-tokens' },
          { text: 'MCP 集成', link: '/reference/mcp' }
        ]
      }
    ],

    socialLinks: [{ icon: 'github', link: 'https://github.com/filescodebox' }],

    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: '搜索文档', buttonAriaLabel: '搜索文档' },
          modal: {
            noResultsText: '未找到相关结果',
            resetButtonTitle: '清除查询条件',
            displayDetails: '显示详细列表',
            hideDetails: '隐藏详细列表',
            footer: {
              selectText: '选择',
              navigateText: '切换',
              closeText: '关闭'
            }
          }
        }
      }
    },

    outline: { level: [2, 3], label: '本页目录' },
    docFooter: { prev: '上一篇', next: '下一篇' },
    // docs-site 内页面尚未提交 git 时无历史, 显式关闭"最后更新时间"避免噪音
    lastUpdated: false,
    darkModeSwitchLabel: '主题',
    lightModeSwitchTitle: '切换到浅色模式',
    darkModeSwitchTitle: '切换到深色模式',
    sidebarMenuLabel: '菜单',
    returnToTopLabel: '回到顶部',
    footer: {
      message: 'FilesCodeBox — 文件快递柜, 开源匿名口令分享平台',
      copyright: '© 2026 filescodebox org'
    }
  }
})
