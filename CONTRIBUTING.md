# CONTRIBUTING

感谢关注 FileCodeBox！本仓是**装配仓库**（hub）：不含业务代码，负责把各模块仓拉齐成工作区。业务贡献请到对应模块仓提 Issue/PR：

| 想改什么 | 去哪个仓 |
|---|---|
| API 契约 / 错误码 / Thrift 类型 | [contracts](https://github.com/filescodebox/contracts) |
| 业务逻辑 / 存储 / 引导（Go） | [core](https://github.com/filescodebox/core) |
| 部署壳 / 配置 / Docker | [server](https://github.com/filescodebox/server) |
| Web 界面（Vue3 + TS） | [frontend](https://github.com/filescodebox/frontend) |
| 飞牛 fnOS 适配 | [filecodebox-fnos](https://github.com/filescodebox/filecodebox-fnos) |
| Helm Chart | [charts](https://github.com/filescodebox/charts) |

## 快速开始（本仓）

```bash
git clone git@github.com:filescodebox/FileCodeBox.git && cd FileCodeBox
make setup     # 拉齐模块仓（幂等；SETUP_FNOS=1 连 fnos 一起拉）
make test      # Go 三模块测试 + 前端 typecheck
make build     # go.work 联编 → bin/
make smoke     # 起 server 冒烟（健康检查/admin 登录/文本分享）
```

## 硬性规则（CI 强制）

1. **依赖单向**：`server / filecodebox-fnos / frontend ──► core ──► contracts`。core 不许 import 上游模块；contracts 不许 import 项目内任何包。
2. **生成物不手改**：contracts `gen/`（thrift）、core `gen/`、frontend `src/types/api.gen.ts`。流程：改 IDL/后端 → 跑对应 gen 脚本 → 生成物与源一起提交。
3. **破坏性变更升主版本**：删/改名字段、改错误码语义必须 bump 主版本；contracts 先发版，core 再升 require。
4. **钉版本规则**：thrift v0.13.0 由 contracts 传递（下游不要 replace）；core 显式钉 sonic v1.15.0（勿动）。

## 提交约定

- commit message 用 conventional 风格：`feat(storage): ...` / `fix(security): ...` / `docs: ...`。
- 新功能必须带测试；修 bug 先写复现测试。覆盖率按模块只升不降。
- 涉及架构/协议的改动，先在本仓 `docs/design/` 落设计文档再动手（参考 [docs/design/2026-10-03-storage-lightup-and-onboarding.md](docs/design/2026-10-03-storage-lightup-and-onboarding.md) 的粒度）。

## 本地存储/网络提示

- 本机到 GitHub 的 22 端口不通时，确认 `~/.ssh/config` 已把 `github.com` 路由到 `ssh.github.com:443`。
- 局域网 S3/WebDAV（NAS 场景）需开启 `security.ssrf.allow_private_networks: true`。

## 行为准则

保持友善、就事论事。社区信任是自托管项目的生命线——对安全、遥测、治理相关议题保持透明。
