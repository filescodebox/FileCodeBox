# API Token（用户级）直接接口上传/操作 + 接口防护设计

日期：2026-10-03
状态：**设计定案，待批准开工**（4 个决策点已收敛为定案，见第 7 节）
涉及仓库：core（主）、frontend、hub docs、contracts（仅 openapi 快照，无 IDL 变更）

## 1. 背景与目标

用户诉求：能拿到自己单独的 API Token，第三方脚本/客户端直接调接口完成上传与分享管理，且要求有完整的接口防护设计。

目标：
1. 用户在页面/接口签发个人 API Key，第三方凭 Key 直接调用上传三通道（direct/chunk/presign）与自己的分享管理接口；
2. Key 的全生命周期安全（签发、存储、使用、吊销、过期）与接口防护（限流、防爆破、防枚举、审计）成体系；
3. 匿名口令分享的产品语义不变（取件侧不引入 Key）。

## 2. 现状盘点（2026-10-03 勘察结论）

### 已存在、可直接复用（发 Key 侧全通）

| 设施 | 位置 | 状态 |
|---|---|---|
| `user_api_keys` 表 | `core/repo/db/model/user_api_key.go` | ✅ 含迁移 SQL |
| 签发/列表/吊销 service | `core/app/user/service.go:438-535` | ✅ `fcb_sk_` 前缀 + 16 字节 crypto/rand（128bit）、SHA-256 存储、明文仅签发时返回一次、可选过期（`ExpiresAt`/`ExpiresInDays`）、上限 5 把 |
| 管理端点 | `GET/POST/DELETE /user/api-keys`（JWT 保护） | ✅ 已挂 `AuthMiddleware` |
| API Key 认证中间件 | `core/transport/http/middleware/api_key_auth.go` | ⚠️ **实现完整但全仓零挂载（孤儿代码）** |
| 上下文键兼容 | 注入 `user_id/username/role/api_key_id/auth_type` | ✅ 与 JWT 中间件键一致，handler 零改动 |
| CORS | `X-API-Key` 已在 `Access-Control-Allow-Headers` 白名单（`bootstrap.go:116`） | ✅ |
| 上传链路身份感知 | direct/chunk/presign 均 `OptionalAuth`，`gate` 登录豁免、`users.max_upload_size` 配额、`transfer_log` 记 user_id | ✅ Key 注入 user_id 后全链路自动生效 |

### 缺口（本设计要解决的）

1. **认证接线缺失**：`APIKeyAuth()` 没挂到任何路由——"能发 Key、不能用 Key"。
2. **中间件自身 4 处安全缺陷**：
   - 不校验 `user.Status`——banned 用户的 Key 依然可用；
   - 支持 `?api_key=` query 传 Key——会泄进访问日志/代理日志/Referer；
   - `TouchLastUsed` 每请求一次 DB 写——写放大；
   - `OptionalAPIKeyAuth` 对"携带 Key 但无效"静默降级为匿名——fail-open，客户端拼错 Key 会在不知情下变成匿名上传（绕过自己预期的配额与归属）。
3. **限流覆盖缺口**：
   - 直传 `/share/text/`、`/share/file/` **完全不在**路径限流 switch 内（`bootstrap.go:624-636` 只覆盖 admin/login、api/v1/user/login、anonymous、presign、chunk、download）；
   - gen 路由 `/user/login` 匹配不到 `/api/v1/user/login` 前缀——登录限流中间件对 gen 登录端点未生效（lockout 有覆盖，但限流层应补齐）。
4. 无效 Key 无防爆破计数。
5. 文档/契约侧无 API Key 说明（openapi.json 无 securitySchemes，无使用指南）。

## 3. 方案总览

**不新造子系统**：复用既有 `user_api_keys` 设施，把孤儿中间件"接线 + 收紧"，补齐限流，补文档与前端管理页。无 IDL/thrift 破坏性变更，无新表（v1）。

```
第三方脚本                    浏览器（现有用户）
    │ X-API-Key / Authorization: ApiKey     │ Authorization: Bearer <JWT>
    ▼                                        ▼
┌─ OptionalIdentity（JWT 优先，其次 API Key，都无→匿名）─┐
│  /share/text/  /share/file/  /share/select/          │
│  /chunk/upload/*  /api/v1/presign/*                  │
├─ UserOrAPIKeyAuth（JWT 或 API Key，必须二选一）────────┤
│  /api/v1/user/shares*  /api/v1/notifies/mine         │
├─ 保持 JWT-only（关键边界）────────────────────────────┤
│  /user/api-keys（不能拿 Key 管 Key，防自我复制）        │
│  /user/info /user/profile /user/files                 │
├─ 保持匿名/口令语义（Key 永不进入）─────────────────────┤
│  /share/download  /anonymous/*  /admin/**  /user/login│
└──────────────────────────────────────────────────────┘
```

认证头定稿（对齐业界惯例：GitHub/GitLab/Stripe 的 PAT 均为"前缀化密钥 + Bearer 头"）：

```
Authorization: Bearer fcb_sk_xxx   ← 首选，标准 HTTP 客户端/curl 习惯
Authorization: ApiKey fcb_sk_xxx   ← 兼容保留
X-API-Key: fcb_sk_xxx              ← 兼容保留（已在 CORS 白名单）
```

`Bearer` 与 JWT 的区分**由前缀确定性判定**：`fcb_sk_` 开头 → 按 API Key 处理，否则按 JWT（JWT 恒为 `eyJ` 开头的 base64，无歧义、无需试探解析）。
**删除 `?api_key=` query 支持**（不留配置开关，少一个开关多一分安全）。

## 4. 详细设计

### 4.1 认证接线（波次 1，core）

> **实现勘误（2026-10-03 波次 1 落地）**：认证核心统一实现在 `core/pkg/middleware/apikey.go`（gen 路由只能 import pkg 层，且避免 pkg↔transport 双方言实现）；`UserOrAPIKey()` 同样落在 pkg/middleware；transport 侧孤儿文件 `api_key_auth.go` 已删除（含 `APIKeyAuthWithAdmin`）。挂载点名称对应：本文 `OptionalIdentityMiddleware()` → 实现名 `OptionalIdentity()`（返回 `[]app.HandlerFunc`，gen 挂载点直接 return）。落地 commits：core `eaf7a38`（认证核心）、`013b02c`（接线）、`9549b78`（限流补位）。

新增两个组合中间件（都是"串联复用"而非重写）：

1. `pkg/middleware.OptionalIdentityMiddleware()`（新）：
   实现为 `OptionalAuthMiddleware()`（既有，JWT）+ `APIKeyAuth` 收紧版 Optional 变体，顺序串联。先 JWT 后 Key，天然无覆盖冲突；都未携带 → 匿名放行。
   凭证分发在提取层完成：`Bearer fcb_sk_*` / `ApiKey` / `X-API-Key` → Key；其余 Bearer → JWT。JWT 失效在 Optional 语义下按既有行为降级匿名（会话过期的 UX 惯例），与 Key 的 fail-closed（见 4.2-d）有意不对称：携带 Key 是显式认证意图，失效 JWT 是会话到期。
   挂载点（替换现有 `OptionalAuthMiddleware()`，`gen/router/*/middleware.go` 为人工维护、重生成不覆盖）：
   - `gen/router/share/middleware.go`：`_sharetextMw`、`_sharefileMw`、`_selectMw`
   - `gen/router/chunk/middleware.go`、`gen/router/presign/middleware.go`：所有 Optional 挂载点（impl 时逐一核对）
2. `transport/http/middleware.UserOrAPIKeyAuth()`（新，~30 行）：
   尝试 JWT（含黑名单检查）→ 成功放行；否则尝试 API Key（收紧版）→ 成功放行；都没有 → 401。
   挂载点：`bootstrap.customizedRegister` 中 `/api/v1` 组现有的 `customMw.UserAuth()` 直接换成它（覆盖 `/api/v1/user/shares*` 与 `/api/v1/notifies/mine`，第三方可 API 管理自己的分享）。

明确**不挂** Key 的边界（写进代码注释 + 文档）：
- `/admin/**`：绝不。现有 `APIKeyAuthWithAdmin()` 无人引用且违反最小权限，**直接删除**（core 内部未导出引用，安全）。
- `/user/api-keys`：Key 不能管理 Key（防止一把泄露的 Key 无限自我复制）；该组保持 JWT-only。
- `/share/download`、`/anonymous/**`：取件是收件方口令语义，产品核心，不引入 Key。
- `/user/login|register`、refresh/logout/check-auth：认证入口本身。

### 4.2 API Key 中间件安全收紧（波次 1，必须修）

对 `transport/http/middleware/api_key_auth.go`：

| # | 缺陷 | 修法 |
|---|---|---|
| a | 不查用户状态 | 验 Key 后校验 `user.Status == "active"`，否则 401；banned/inactive 用户 Key 立即全失效 |
| b | query 传 Key | `extractAPIKey` 删除 `?api_key=` 分支，只留三种 Header（`Bearer fcb_sk_*` / `ApiKey` / `X-API-Key`） |
| c | `TouchLastUsed` 每请求写库 | 进程内 `sync.Map[keyID]lastTouch` 节流：每 Key 60s 最多写一次（多实例各自节流即可，目的只是降写放大） |
| d | Optional 变体 fail-open | 语义改为：**未携带 Key → 匿名放行；携带但无效/过期/吊销/用户禁用 → 一律 401 拒绝**。统一文案 `Invalid API Key`，不区分具体原因（防枚举） |
| e | 无防爆破 | 携带 Key 且校验失败 → 复用现有 lockout（`lockout.RecordFailure("apikey|" + ResolveClientIP)`，CheckLocked 前置），走默认 10 次/5 分钟锁定参数；成功验证 → Reset |

顺带：验证失败的 Key 计数、成功使用节流均无新增外部依赖（内存兜底，Redis 可选加速，与现有 lockout 同构）。

**明确不做的取舍**：不引入"key→user 查询缓存"（60s TTL 可省掉每请求 2 个索引查询，但吊销/封禁会延迟生效最多 60s——对安全语义损伤大于性能收益；两个唯一索引/主键查询在自部署量级下是亚毫秒级）。只做 c 的 TouchLastUsed 写节流，认证查询每请求走库，保证吊销与封禁**即时生效**。

### 4.3 限流补位（波次 1）

`bootstrap.go` 路径感知限流 switch 补两条：

```go
case strings.HasPrefix(path, "/admin/login"),
     strings.HasPrefix(path, "/api/v1/user/login"),
     strings.HasPrefix(path, "/user/login"):        // ← 补 gen 登录端点缺口
    rl.LoginMiddleware()(ctx, c)
case strings.HasPrefix(path, "/anonymous/generate"),
     strings.HasPrefix(path, "/anonymous/retrieve"),
     strings.HasPrefix(path, "/api/v1/presign"),
     strings.HasPrefix(path, "/api/v1/chunk"),
     strings.HasPrefix(path, "/share/text"),        // ← 直传此前完全无限流
     strings.HasPrefix(path, "/share/file"):        // ←
    rl.UploadMiddleware()(ctx, c)
```

`/user/api-keys` 签发端点不加路径限流（JWT 后面 + 5 把上限已够，YAGNI）。
per-Key 独立限流（`apikey:<id>` 维度）放波次 3，见决策点 ④。

### 4.4 审计（波次 1 从简，v1 不建新表）

- Key 认证的 upload/download 自动落入既有 `transfer_log`（user_id 维度）与 AccessLog（带 trace_id）——**无需新表**；
- Key 的签发/吊销/验证失败走结构化日志（accesslog + lockout 记录），`LastUsedAt`/`ExpiresAt`/`Revoked` 已可支撑用户自查异常；
- `user_operation_log` 用户级操作审计表留到波次 3（配合后台审计页再做，决策点外，YAGNI）。

### 4.5 配置面（波次 2）

新增一节（保持最小）：

```yaml
security:
  api_token:
    enabled: true        # 总开关：出事可一键停用 Key 认证（false 时携带 Key 的请求按 401 处理）
```

- env：`FCB_API_TOKEN_ENABLED`，按惯例登记 4 处：`core/conf/config.go`（struct + mapstructure）、`bootstrap.go setDefaults`、`envBindings` 映射、`server/configs/config.example.yaml` + hub `docs/ENVIRONMENT_VARIABLES.md`；
- Helm：非敏感配置走现有 `config: {}` ConfigMap 口子，**零模板改动**；
- `max_keys=5`、过期策略不配置化（YAGNI，代码常量已够）。

### 4.6 使用面 / DX（波次 2-3）

- **文档**：hub 新增 `docs/API-TOKENS.md`——获取 Key（页面或 curl+JWT 两种姿势）、认证头规范、direct/chunk/presign 三条 curl 上传示例、管理自己分享示例、防护机制说明、**HTTP 明文部署警告**（215 这类 `http://ip` 部署传 Key = 明文，需提示切 HTTPS 或仅内网使用）；
- **Swagger**：`frontend/openapi.json` 手工补 `/user/api-keys` 三端点（若缺）+ `securitySchemes`（`http bearer` 主方案——Swagger UI Authorize 按钮可直接粘贴 Key，另有 `apiKey` 型 `X-API-Key` 备选）→ `npm run gen:api` → `/api-docs` 页自动可见；
- **前端**（波次 2，定案 ③）：新增 `/user/tokens` 路由 + `views/user/Tokens.vue`（仿 Notifications.vue）：创建弹窗（名称 + 可选过期天数，**明文仅此一次展示 + 复制按钮**）、列表（前缀/最后使用/过期/吊销状态）、吊销二次确认；`AppLayout.vue` 桌面菜单与移动抽屉**两处**都要加。

## 5. 威胁 → 对策总表（防护设计核心）

| 威胁 | 对策 | 波次 |
|---|---|---|
| Key 泄进日志/Referer（query 传参） | 仅允许 Header 传输，删除 `?api_key=` | 1 |
| Key 数据库泄露 | SHA-256 单向存储（既有）；明文仅签发时一次（既有） | 已有 |
| Key 泄露后长期可用 | 用户可随时吊销（既有）+ 可选过期（既有）+ `LastUsedAt` 异常自查 | 已有 |
| banned 用户继续用 Key | 中间件校验 `user.Status==active` | 1 |
| 暴力枚举 Key | 128bit 随机（熵上不可枚举）+ 统一 401 文案 + `apikey\|IP` lockout 锁定 | 1 |
| 无效 Key 静默降级匿名 | Optional 变体 fail-open → fail-closed（带 Key 无效即 401） | 1 |
| 泄露 Key 被高速滥用 | 直传/上传路径级限流（本次补齐）；per-Key 限流 | 1 / 3 |
| 直传接口无路径限流 | `/share/text`、`/share/file` 补 UploadMiddleware | 1 |
| gen 登录端点绕过登录限流 | `/user/login` 补进 Login 分支 | 1 |
| Key 越权操作他人资源 | Key 只注入 user_id，全部管理端点既有 user_id 过滤逻辑；无任何"按 Key 提权"路径 | 既有 |
| Key 提权进管理端 | `/admin` 永不挂 Key；删除 `APIKeyAuthWithAdmin()` | 1 |
| 一把 Key 被盗后自我复制 | `/user/api-keys` 保持 JWT-only，Key 不能管 Key | 1 |
| 每请求 DB 写放大 | `TouchLastUsed` 60s 节流 | 1 |
| HTTP 明文传输 Key | 文档强警告 + 部署指引；网关层强制 HTTPS 属部署侧事项 | 2 |
| 功能异常需要急停 | `security.api_token.enabled` 总开关 | 2 |

## 6. 波次划分

- **波次 1（core，防护主体）**：4.1 接线 + 4.2 收紧 + 4.3 限流补位 + `routes_guard_test.go` 契约快照更新 + 单测。发布随 core 下一版本（server 同步跟进）。
- **波次 2（配置、文档与前端）**：4.5 配置面 + `docs/API-TOKENS.md` + openapi.json/securitySchemes + 前端 `/user/tokens` 页（定案 ③）。
- **波次 3（增强，全部可独立排期）**：per-Key 限流、read/write scope、`user_operation_log` 审计表、admin 侧查看/吊销用户 Key。

## 7. 决策定案（2026-10-03，已收敛，替代原 4 个待拍板项）

| # | 问题 | 定案 | 理由 |
|---|---|---|---|
| ① | Key 能力范围 | 上传三通道 + 自己的分享管理（`/api/v1/user/shares*`）+ 通知列表 | "接口直接操作"的完整闭环；一组中间件整体替换成本为零，单独裁剪通知反而要拆组；全部在 user_id 归属过滤内，无越权面 |
| ② | 过期默认值 | **默认永久**，签发时可选 `ExpiresAt`/`ExpiresInDays`（服务端已支持），前端创建表单给出"建议设置过期"提示 | 对齐 GitHub classic PAT 惯例；脚本/cron 场景最怕静默滚动过期导致流水线断；吊销与封禁已提供即时止损手段 |
| ③ | 前端 Key 管理页 | **做，并入波次 2**（与 openapi/文档同批交付） | 否则拿 Key 只能靠 curl 调管理接口，鸡生蛋；反正是 frontend 仓的一次改动，不值得拆两批 |
| ④ | per-Key 独立限流 | **波次 3**，v1 只有路径级限流 + lockout | 自部署量级下路径级足够；per-Key 维度需要新增限流维度配置，等真实滥用出现再做（YAGNI） |

## 8. 测试策略

- 中间件单测：有效 Key / 不存在 / 过期 / 已吊销 / banned 用户 / query 传 Key 拒绝 / 无 Key 匿名 / 带 Key 无效 401 / lockout 连败锁定 / TouchLastUsed 节流（注意 SQLite `:memory:` 测试须钉单连接，见 2026-10-03 治理上线教训）；
- 组合中间件：JWT 与 Key 同时携带时 JWT 优先、互不覆盖；`UserOrAPIKeyAuth` 三分支；
- 限流：直传路径命中 Upload 维度、`/user/login` 命中 Login 维度；
- 路由契约：`routes_guard_test.go` 快照双向更新；
- 冒烟：`make smoke` 追加"签发 Key → Key 直传文本 → Key 列举自己分享 → 吊销后 401"一条链路。

## 9. 缺口评审与补充设计（2026-10-03 第二轮，波次 1+2 落地后自查）

以攻击者/运维/第三方开发者三个视角对已落地实现做完整评审。结论：核心防护链（fail-closed、防爆破、限流、总开关、边界）成立，发现 2 个高优先缺口、2 个中低优先缺口、1 个相邻安全缺陷，以及 4 项维持搁置项。

### 9.1 缺口总表

| # | 缺口 | 严重度 | 处置 |
|---|---|---|---|
| 1 | **审计归因缺失**：`transfer_logs` 只记 `user_id`，Key 泄露排查时只能归因到"账号"，无法定位"哪把 Key" | 高 | 本轮补（§9.2 A） |
| 2 | **应急止损缺失**：无"一键吊销全部"，账号疑似接管时逐把吊销太慢 | 高 | 本轮补（§9.3 B） |
| 3 | **契约不完整**：openapi 仅 api-keys 端点标注了认证，上传三通道与分享管理端点未标，Swagger 用户不知道能带 Key | 中 | 本轮补（§9.4 C） |
| 4 | **HTTP 部署复制缺陷**：非安全上下文（如 215 的 `http://IP`）`navigator.clipboard` 不可用，当前降级为 toast 弹 Key，粗糙 | 低 | 本轮补（§9.5 D） |
| 5 | **相邻缺陷：refresh 不校验黑名单**：`POST /api/v1/user/refresh` 直接换发，登出后（token 已入黑名单）仍可刷新出新 token，登出撤销可被绕过。非本特性引入，但同属凭证生命周期 | 高 | 本轮顺手修（§9.6 F） |
| 6 | 可观测性：accesslog/metrics 不区分认证类型（jwt/api_key），Key 流量占比无法观测 | 低 | 搁置：需要时在 accesslog 加一个字段即可 |
| 7 | Key 临期无提醒（notify 域已有，可做到期扫描通知） | 低 | 搁置：有明确用户反馈再做 |
| 8 | per-Key 独立限流 | 低 | 维持波次 3（触发条件：出现单 Key 滥用/多 IP 绕过路径限流） |
| 9 | Key 签发/吊销无独立审计表 | 低 | 搁置：accesslog 已覆盖端点命中（JWT 身份 + IP + trace_id） |
| 10 | `/api/v1` 组未来扩展的暴露面漂移 | — | 治理规则：组内新增路由必须评估 Key 暴露面（写入 bootstrap 注释，routes_guard 守卫路径集） |

### 9.2 补充设计 A：Key 粒度审计归因

- `pkg/middleware`：`withIdentity` 增加第 5 参 `apiKeyID uint`（JWT 路径传 0）；新增 `APIKeyIDFromContext(ctx) (uint, bool)`。`validateAPIKey` 传入 `key.ID`。
- `model.TransferLog` 增加 `APIKeyID *uint`（`gorm:"index"`）：AutoMigrate 自动加列（SQLite/新部署）；补版本化迁移 `000002_transfer_log_api_key_id` 保持 `database.migrate` 模式一致。
- `transfer.Record` 签名增加 `apiKeyID *uint`（调用方仅 3 处：`gen/handler/share/share_service.go` 文本上传 ：178、文件上传 ：379、下载 ：785，均在 handler 内可直接取 ctx；非 Key 认证传 nil）。
- 查询面：管理员传输日志已有列表/过滤，字段带出即可；用户侧"按 Key 查用量"留待需求。

### 9.3 补充设计 B：一键吊销全部

- 新端点 `POST /user/api-keys/revoke-all`（**JWT-only**，gen 路由注册 + routes_guard 契约表更新）→ service `RevokeAllByUser`（`UPDATE user_api_keys SET revoked=true, revoked_at=now WHERE user_id=? AND revoked=false`，返回吊销数量；单条 UPDATE 原子）。
- Tokens 页工具栏加"吊销全部"按钮：confirm 文案动态含当前有效数量，完成后刷新列表。
- 语义澄清（写进 API-TOKENS.md）：修改密码**不**自动吊销 Key（与 JWT 现状一致——改密码同样不踢已有会话）；应急路径 = 本按钮，或管理员封禁账号（Status 检查使该账号全部 Key 即刻失效）。

### 9.4 补充设计 C：Swagger 契约补全

- 给以下端点标 `security: [{bearerAuth: []}, {ApiKeyAuth: []}]`（OpenAPI 数组=OR 语义）：`/share/text/`、`/share/file/`、`/share/select/`、`/chunk/upload/*`（4 条）、`/api/v1/presign/*`（3+1 条）、`/api/v1/user/shares*`（5 条）、`/api/v1/notifies/*`（3 条）。
- `npm run gen:api` 再生成；Swagger UI 这些端点出现双锁图标，第三方一眼可见。

### 9.5 补充设计 D：复制降级（HTTP 部署）

- Tokens.vue `copyKey`：`navigator.clipboard` 不存在或拒绝时，退化为"隐藏 textarea + `document.execCommand('copy')`"；仍失败则提示手动选择（明文 code 已 `user-select: all`，点击全选）。

### 9.6 相邻修复 F：refresh 黑名单校验

- `auth.RefreshToken(token)` → `auth.RefreshToken(ctx, token)`：ParseToken 成功后校验 `IsTokenRevoked(ctx, token)`，命中返回错误（唯一调用点 `bootstrap.go:688` 同步改）。
- 测试：auth 包单测——Generate → Revoke（黑名单内存模式）→ Refresh 必须失败；未吊销 Refresh 成功。
- 语义：与 AuthMiddleware/UserAuth 的黑名单检查对齐，堵住"登出后 token 复活"。

### 9.7 实施批次

- **波次 2.5（本轮）**：A + B + C + D + F，全部向后兼容（新增列可空、新端点、契约标注、纯前端降级、refresh 签名内部变更）。
- 波次 3 维持：per-Key 限流、过期提醒、认证类型指标、Key 操作审计表。
