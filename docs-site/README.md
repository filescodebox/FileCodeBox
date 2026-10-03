# filescodebox-docs

FilesCodeBox 文档站（VitePress 1.x，中文站点）。

**内容真相源是 hub 仓库的 `../docs/` 目录。** 本站大多数内容页通过 VitePress 的 `<!--@include: -->` 指令原样引入 `../docs/*.md`：hub 文档更新后，站点内容自动同步，本目录不需要跟改；本目录只维护站点壳（首页 / 导航 / 侧边栏 / 少量手写页）。

## 本地预览

```bash
cd docs-site
npm install
npm run docs:dev      # 开发服务器, 默认 http://localhost:5173
```

## 构建与产物预览

```bash
npm run docs:build    # 构建产物输出到 .vitepress/dist/
npm run docs:preview  # 本地预览构建产物
```

## 目录结构

```
docs-site/
├── .vitepress/config.mts   # 站点配置: lang/title/nav/sidebar/搜索/死链策略
├── index.md                # 首页(VitePress hero 布局, 手写)
├── guide/                  # 使用指南
│   ├── getting-started.md      # 快速开始(手写, 事实以 hub README + docs/DEPLOY-COMPOSE.md 为准)
│   ├── deploy-docker.md        # @include ../docs/DEPLOY-COMPOSE.md
│   ├── deploy-kubernetes.md    # 手写(事实以 charts 仓库 README 为准)
│   ├── environment.md          # @include ../docs/ENVIRONMENT_VARIABLES.md
│   └── upgrade.md              # @include ../docs/v0.3-upgrade-notes.md
└── reference/              # 架构 / API / 设计文档
    ├── architecture.md         # @include ../docs/architecture.md
    ├── api-tokens.md           # @include ../docs/API-TOKENS.md
    ├── mcp.md                  # @include ../docs/MCP-README.md
    └── design/                 # @include ../docs/design/*.md (4 篇)
```

## 如何加新页面

两种方式：

1. **引用现有 hub 文档（`../docs/` 已有对应内容时，推荐）**：新建一个只有 frontmatter 的 stub 页，用 include 引入，例如 `guide/foo.md`：

   ```md
   ---
   title: 页面标题
   ---
   <!--@include: ../../docs/xxx.md-->
   ```

   include 路径相对于 stub 页自身（`guide/`、`reference/` 下是 `../../docs/`）。

2. **手写页（`../docs/` 没有对应内容时）**：直接在 `guide/` 或 `reference/` 下写 markdown，注意事实要与 hub 仓库代码/文档一致。

无论哪种方式，都要把新页面登记进 `.vitepress/config.mts` 的 `nav` / `sidebar`（不加导航也能通过直链访问，但难以被发现）。

## 注意事项

- **死链策略**：`config.mts` 的 `ignoreDeadLinks` 只按正则放行两类被引入的 hub 文档内部相对链接（`../README.md`、`ENVIRONMENT_VARIABLES.md`——它们在 GitHub 仓库内有效，但无法映射为本站路由）。不要扩大放行范围，手写页与站内链接的死链仍会让 `docs:build` 失败。
- `../docs/` 下的 markdown 是真相源，改内容去那边改；本目录的 stub 页只承载 frontmatter 与 include 指令，不要在 stub 页里手写正文（会被下次对照真相源时当成偏差）。
- `docs/design/` 与 `docs/superpowers/` 中的带日期文件属内部设计/计划存档，站点以"架构与设计"分组只读引用；新增设计文档后如需对外，按方式 1 加 stub 页即可。
