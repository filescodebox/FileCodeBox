# FileCodeBox(umbrella)

高性能文件/文本匿名分享平台的**装配仓库**:本仓不含业务代码,只负责把各模块仓库拉齐成一个可开发、可构建、可部署的完整工作区。

> 拆分前的单仓库完整版本保留在 [legacy 分支](https://github.com/filescodebox/FileCodeBox/tree/legacy)(全量历史)。

## 模块仓库

| 仓库 | 角色 | 版本 |
|------|------|------|
| [contracts](https://github.com/filescodebox/contracts) | 契约层:错误码 + Thrift 生成类型(纯类型,零业务依赖) | v0.1.0 |
| [core](https://github.com/filescodebox/core) | 业务核心库:10 个域服务 + repo/storage + `bootstrap.Bootstrap()` 库入口 | v0.1.0 |
| [server](https://github.com/filescodebox/server) | 独立部署应用:main 薄壳 + 前端静态资源 + Dockerfile | v0.1.0 |
| [frontend](https://github.com/filescodebox/frontend) | Vue3 + TS + Vite + Element Plus(类型由 openapi.json 生成) | - |
| [filecodebox-fnos](https://github.com/filescodebox/filecodebox-fnos) | 飞牛 fnOS 应用适配(可选,`SETUP_FNOS=1 make setup` 启用) | v0.1.1 |

依赖方向(单向,CI 守护):`server / fnos / frontend ──► core ──► contracts`

## 快速开始

```bash
git clone https://github.com/filescodebox/FileCodeBox.git && cd FileCodeBox

make setup     # 拉齐四个模块仓库(幂等,重复执行=更新)
make test      # 全仓测试(Go 三模块 + 前端 typecheck)
make build     # workspace 联编
make smoke     # 起 server 跑冒烟(健康检查/admin登录/文本分享)
```

纯 Docker 体验:

```bash
docker compose up -d          # ghcr 发布镜像
# 或 BUILD=1 docker compose up -d   # 本地构建(需先 make setup)
```

默认管理员 `admin / admin123`(生产务必以 `FCB_ADMIN_PASSWORD` 覆盖)。

## 工作区布局(setup 后)

```
FileCodeBox/            ← 本仓(装配层:脚本/联编/编排)
├── go.work             # contracts+core+server 本地联编
├── contracts/  core/  server/  frontend/   ← 独立 git 仓库(gitignore 掉)
└── data/               ← compose 数据卷
```

各模块仓库独立开发、独立 CI、独立发版;`server/Dockerfile` 的构建上下文恰好就是本目录,`make docker` 直接出完整镜像。

## 发版

打 `v*` tag 即自动构建多架构镜像推 ghcr(见各仓 `release.yml`):
`ghcr.io/filescodebox/server` · `ghcr.io/filescodebox/filecodebox-fnos`

## 原 README(产品功能/截图/API 说明)

见 [legacy 分支 README](https://github.com/filescodebox/FileCodeBox/blob/legacy/README.md)。
