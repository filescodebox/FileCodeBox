# FileCodeBox RoadMap

> 最后更新：2026-10-03。路线按「现在（进行中）/ 下一步 / 更远」组织，完成即勾选。
> 功能请求请到各仓 Issues；重大设计变更会先在 `docs/design/` 落设计文档。

## 定位

**匿名口令文件快递柜**：像取快递一样收发文本与文件。坚持轻量、开箱即用，
不做网盘、不做重存储平台——这是对上游社区共识（[#434](https://github.com/vastsa/FileCodeBox/issues/434)）
的继承，也是我们与 Gokapi / copyparty / Nextcloud 的边界。

## 现在（进行中）

- [x] 单体 → 多仓拆分，CI/发布链路（contracts/core/server/frontend/fnos/charts）
- [x] 安全基线：分享密码、失败锁定、下载令牌、SSRF 校验、文件名消毒、审计接线
- [x] 管理端站点配置 DB 持久化（system_configs 单行写穿）
- [ ] **存储后端点亮**：S3 / WebDAV 真实读写（opendal 驱动 + StorageService 类型分派）
  - [ ] 运行时切换存储后端 + 持久化（重启不丢），启动从 DB 恢复
  - [ ] presign 直传 / 分片上传走当前激活后端
  - [ ] 管理端展示「实际生效后端」与健康状态
- [ ] **首启引导**：`/api/config` 返回真实 `initialized`；前端 Setup 初始化页
- [ ] **开源合规件**：LICENSE（7 仓）/ CONTRIBUTING / SECURITY / CHANGELOG / 双语 README
  - [ ] 提交 [awesome-selfhosted](https://awesome-selfhosted.net/) 收录
- [ ] 公开 demo 站（定时重置容器）

## 下一步（近期规划）

- [x] **真·S3 预签名直传直下**：客户端 ↔ 对象存储点对点，服务器只签名不中转
  （上传：`presign.Init` 对 s3 后端签发预签名 PUT、`Complete` 以 S3 为事实源核实；
  下载：`download.s3_direct_download=true` 时 302 预签名 GET）
- [ ] **通知渠道扩展**：SMTP 邮件 / Telegram / Bark（现有 notify 域站内信 + Webhook 架构上扩渠道）
- [ ] **反向分享（文件收集）**：发一个链接，对方往你这里传文件（对齐 Pingvin reverse share / Gokapi file requests）
- [ ] 存储迁移工具：local → s3/webdav 存量数据搬运
- [ ] 端到端加密分享（可选启用，客户端 WebCrypto，服务器零知识）
- [ ] 文档站（VitePress）+ 收编旧单体 45 篇运维文档
- [ ] 飞牛 fnOS 深度集成落地（SSO / 共享目录 / 内网穿透 / 通知中心，等 Open API 凭证解锁）

## 更远（探索中）

- [ ] MCP Server：把分享/取件/管理能力暴露给 AI Agent（legacy 已有 4 篇设计文档）
- [ ] `fcb` CLI（基于既有 API Key 体系）
- [ ] 可选 ClamAV 病毒扫描（自托管用户信任卖点，对齐 Pingvin Share X）
- [ ] OIDC / 邮箱找回密码（企业化方向）
- [ ] 主题系统 / 自定义 CSS（Gokapi 验证过的需求）
- [ ] PWA / 移动端体验
- [ ] 测试棘轮：覆盖率只升不降 + Playwright E2E

## 设计决策记录

- 多仓拆分与依赖方向见 [architecture.md](docs/architecture.md)（CI 强制单向依赖）。
- 存储点亮 / 首启引导详细设计见 [docs/design/2026-10-03-storage-lightup-and-onboarding.md](docs/design/2026-10-03-storage-lightup-and-onboarding.md)。
- 破坏性变更（删/改名字段、改错误码语义）必须升主版本；生成物一律不手改。
