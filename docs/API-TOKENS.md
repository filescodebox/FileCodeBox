# API Token（个人访问令牌）使用指南

用户级 API Key（`fcb_sk_` 前缀）用于脚本 / CI / 第三方客户端直接调用 FilesCodeBox 接口，完成上传与"我的分享"管理，无需浏览器会话。

## 1. 获取 Key

**方式 A（推荐）**：登录后进入 用户中心 → **API 令牌**（`/#/user/tokens`），点"签发新 Key"。明文 Key **仅创建时显示一次**，请立即保存。

**方式 B（curl）**：先登录拿 JWT，再调签发接口：

```bash
# 登录（响应 data.token 为 JWT）
curl -s -X POST http://localhost:12345/user/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"yourname","password":"***"}'

# 签发 Key（expires_in_days 可选；不传=永久，建议设置）
curl -s -X POST http://localhost:12345/user/api-keys \
  -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
  -d '{"name":"ci-upload","expires_in_days":90}'
# 响应 data.key 即明文 Key（仅此一次）；data.api_key.id 用于吊销
```

约束：每人最多 5 把有效 Key；吊销即时生效；封禁用户的 Key 一并失效。

**一键吊销全部**（疑似泄露应急）：

```bash
curl -s -X POST http://localhost:12345/user/api-keys/revoke-all \
  -H "Authorization: Bearer $JWT"
# 响应 data.revoked 为吊销数量；仅 JWT 可调（Key 不能管 Key）
```

语义说明：**修改密码不会自动吊销 Key**（与 JWT 会话现状一致）——怀疑泄露时请用上面的"一键吊销全部"或用户中心页面按钮；管理员封禁账号也会使该账号全部 Key 即刻失效。

## 2. 认证方式

三种请求头等价（**不接受 URL query 传参**——会被日志/Referer 泄露，服务端直接忽略）：

```
Authorization: Bearer fcb_sk_xxx   # 首选（标准 HTTP 客户端习惯；按 fcb_sk_ 前缀与 JWT 自动区分）
Authorization: ApiKey fcb_sk_xxx   # 兼容
X-API-Key: fcb_sk_xxx              # 兼容
```

## 3. Key 能做什么

| 能力 | 端点 | 说明 |
|---|---|---|
| 文本分享 | `POST /share/text/` | 与网页直传同参数 |
| 文件直传 | `POST /share/file/`（multipart `file`） | 受上传闸门与大小上限约束 |
| 分块上传 | `POST /chunk/upload/init/ → /chunk/upload/chunk/:id/:i → /chunk/upload/complete/:id` | 大文件，秒传/断点续传 |
| 预签名直传 | `POST /api/v1/presign/upload → PUT … → POST /api/v1/presign/complete` | s3 直传或服务器中转 |
| 我的分享管理 | `GET/POST /api/v1/user/shares*`、`/api/v1/notifies/*` | 列举/批量删/延期/恢复 |

**Key 永远不能**：访问 `/admin/**`、签发或吊销 Key 本身（`/user/api-keys` 仅 JWT）、参与取件（`/share/download`、`/anonymous/**` 保持口令语义）。上传管控（开关/白名单/配额）对 Key 认证的请求同样生效，按你的账号配额计。

### 上传示例

```bash
KEY="fcb_sk_xxx"

# 文本
curl -s -X POST http://localhost:12345/share/text/ \
  -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"text":"hello","expire_value":1,"expire_style":"day","require_auth":false}'

# 文件
curl -s -X POST http://localhost:12345/share/file/ \
  -H "X-API-Key: $KEY" -F "file=@./report.pdf" \
  -F "expire_value=1" -F "expire_style=day" -F "require_auth=false"

# 列举自己的分享
curl -s "http://localhost:12345/api/v1/user/shares?page=1&page_size=20" \
  -H "Authorization: Bearer $KEY"
```

## 4. 防护机制（服务端强制）

- **fail-closed**：请求携带 Key 但无效（不存在/过期/已吊销/用户被禁）一律 `401 {"message":"Invalid API Key"}`，不区分原因（防枚举）；绝不静默降级为匿名。
- **防爆破**：无效 Key 连续 10 次（默认）触发 `apikey|IP` 锁定 10 分钟，期间返回 `429`；有效使用即清零。
- **限流**：路径感知分维度限流（上传 10 QPS/IP 默认）之外，每把 Key 还有**独立令牌桶限流**（默认 20 QPS / 桶 40，`FCB_API_TOKEN_PER_KEY_QPS` 可调，0 = 不限）——单把 Key 被盗也打不满服务器。
- **临期提醒**：Key 到期前 7 天，站内通知（含 Webhook 外推）提醒属主一次，不重复打扰。
- **存储安全**：服务端只存 Key 的 SHA-256 摘要；明文仅签发时返回一次。
- **审计**：Key 认证的上传/下载计入 `transfer_logs`（user_id 维度，且带 `api_key_id` 归因列——泄露排查可精确定位到哪把 Key，管理后台传输日志页可见）；Key 列表展示"最后使用"时间与**来源 IP**，发现异常立即吊销；登出后 JWT 即刻失效（含 refresh 换发链路）。
- **总开关**：`security.api_token.enabled=false`（env `FCB_API_TOKEN_ENABLED`）时携带 Key 的请求一律 401（紧急停用）。

## 5. 部署安全提醒

- **明文 HTTP 部署（如 `http://10.44.129.215/`）下，Key 等同明文传输**。内网可信环境可用；对外服务请务必经 HTTPS 反代（charts 部署默认 Ingress TLS）。
- 不要把 Key 写进仓库/日志；CI 中使用 secrets 注入。
- 定期检查"最后使用"时间，长期不用的 Key 及时吊销。

## 6. Swagger

`/api-docs` 页右上 Authorize 可填入 Key（bearerAuth 接受 `fcb_sk_` 值，或选 ApiKeyAuth 填 `X-API-Key`），此后 Try it out 自动携带。
