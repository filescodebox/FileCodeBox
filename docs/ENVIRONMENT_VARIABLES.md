# 环境变量参考（ENVIRONMENT_VARIABLES）

所有环境变量优先级高于 config.yaml（12-factor 注入方式）。命名两套并存：文档化短名（如 `PORT`）与 `FCB_` 前缀全名（如 `FCB_SERVER_PORT`）。

## 敏感项（生产必设）

| 变量 | 说明 |
|---|---|
| `FCB_JWT_SECRET` | JWT 签名密钥（全环境强制：空或已知默认值将拒绝启动，≥32 位强随机） |
| `FCB_ADMIN_PASSWORD` | 首个管理员 admin 的密码（默认 admin123，生产必须覆盖） |
| `FCB_DATABASE_PASSWORD` | MySQL/Postgres 密码 |
| `FCB_REDIS_PASSWORD` | Redis 密码 |
| `FCB_PRESIGN_SIGNING_KEY` | 预签名直传专用签名密钥（缺省复用 jwt_secret） |

## 服务器

| 变量 | 默认 | 说明 |
|---|---|---|
| `FCB_SERVER_HOST` / `HOST` | 0.0.0.0 | 监听地址 |
| `FCB_SERVER_PORT` / `PORT` | 12345 | 监听端口 |
| `FCB_SERVER_MODE` | debug | debug / release（release 视为生产） |
| `FCB_SERVER_BASE_URL` / `BASE_URL` | 空 | 对外访问地址（分享链接生成用） |

## 数据库 / Redis

| 变量 | 默认 | 说明 |
|---|---|---|
| `FCB_DATABASE_DRIVER` / `DB_TYPE` | sqlite | sqlite / mysql / postgres |
| `FCB_DATABASE_DB_NAME` / `DB_NAME` | ./data/filecodebox.db | SQLite 文件路径或库名 |
| `FCB_DATABASE_HOST` / `DB_HOST` | — | MySQL/PG 主机 |
| `FCB_REDIS_HOST` / `REDIS_HOST` | 空 | **为空 = 禁用**；匿名取件/预签名/分布式限流/JWT 黑名单共享依赖 Redis，连不上自动降级并在启动日志告警 |
| `FCB_REDIS_PORT` / `REDIS_PORT` | 6379 | |

## 上传安全

| 变量 | 默认 | 说明 |
|---|---|---|
| `FCB_OPEN_UPLOAD` / `OPEN_UPLOAD` | true | 匿名上传总开关（服务端强制执行；false 时拒绝全部匿名上传，登录用户不受影响） |
| `FCB_UPLOAD_SIZE` / `UPLOAD_SIZE` | 10485760 | 单请求体上限（字节） |
| `FCB_TEXT_MAX_BYTES` | 227328 (222KB) | 文本分享内容上限 |
| `FCB_UPLOAD_ALLOWED_EXTENSIONS` | 空（黑名单模式） | 扩展名白名单，逗号分隔；非空则必须命中（未命中拒绝，含无扩展名） |
| `FCB_UPLOAD_BLOCKED_EXTENSIONS` | 内置默认 | 扩展名黑名单，逗号分隔；非空覆盖内置默认，白名单命中也拦截 |
| `FCB_ENABLE_MAGIC_CHECK` | true | 魔数校验（拦截改扩展名伪装的可执行文件） |
| `FCB_UPLOAD_ANON_DAILY_COUNT` / `FCB_UPLOAD_ANON_DAILY_BYTES` | 0（不限） | 匿名上传 per-IP 日配额（次数 / 字节） |

## 下载

| 变量 | 默认 | 说明 |
|---|---|---|
| `FCB_DOWNLOAD_S3_DIRECT` | false | s3 直下：存储后端为 s3 时，文件下载 302 到短时效预签名 GET URL（下载流量不经过服务器）。对象存储桶需配置 CORS 允许站点来源 |

## 安全

| 变量 | 默认 | 说明 |
|---|---|---|
| `FCB_TRUSTED_PROXIES` | 空 | 可信代理 CIDR，逗号分隔（如 `10.0.0.0/8,173.245.48.0/20`）。**反代部署必填**：仅当直连对端在网段内才采信 X-Forwarded-For，否则伪造 XFF 无法绕过限流/锁定 |
| `FCB_DOWNLOAD_TOKEN_ENABLED` | true | 取件下载令牌（HMAC 时间窗）强制校验 |
| `FCB_LOCKOUT_ENABLED` | true | 登录/取件失败计数锁定 |
| `FCB_LOCKOUT_MAX_ATTEMPTS` | 10 | 窗口内失败阈值 |
| `FCB_SSRF_ALLOW_PRIVATE` | false | 允许 s3/webdav 端点指向私网。**局域网 MinIO/WebDAV（飞牛 NAS）部署需设 true** |
| `FCB_CORS_ALLOW_ORIGINS` | 空 | CORS 白名单，逗号分隔 |
| `FCB_ENABLE_HSTS` | false | HSTS（仅 HTTPS 部署开启） |

## 限流

| 变量 | 默认 | 说明 |
|---|---|---|
| `FCB_RATE_LIMIT_ENABLED` | true | 总开关 |
| `FCB_RATE_LIMIT_GLOBAL_QPS` | 100 | 每 IP 全局 QPS |
| `FCB_RATE_LIMIT_UPLOAD_QPS` | 10 | 上传维度 |
| `FCB_RATE_LIMIT_DOWNLOAD_QPS` | 50 | 下载维度 |
| `FCB_RATE_LIMIT_LOGIN_QPS` | 5 | 登录维度 |
| `FCB_RATE_LIMIT_BLOCK_SECONDS` | 60 | 触发后封禁时长 |
| `FCB_RATE_LIMIT_USE_REDIS` | false | Redis 固定窗口计数（多实例共享；Redis 不可用自动回退内存） |

## 通知

| 变量 | 默认 | 说明 |
|---|---|---|
| `FCB_WEBHOOK_URL` | 空 | 外部 Webhook 推送地址（`notify.created` 事件 JSON POST，5s 超时，失败仅记日志） |

## AI 集成（MCP）

| 变量 | 默认 | 说明 |
|---|---|---|
| `FCB_MCP_ENABLED` | true | MCP server（POST /api/v1/mcp，Streamable HTTP/JSON-RPC 2.0，管理员 JWT 认证；8 个工具：share_text/get_share/list_shares/delete_share/get_system_status/get_storage_info/list_users/cleanup_expired） |

## 可观测性

| 变量 | 默认 | 说明 |
|---|---|---|
| `FCB_METRICS_ENABLED` | false | Prometheus 指标（独立监听 127.0.0.1:9090，`FCB_METRICS_ADDR` 可改） |
| `FCB_METRICS_PATH` | /metrics | 指标路径 |
| `FCB_TRACING_ENABLED` | false | OTel tracing |

## 其他

`FCB_DATA_PATH`（数据目录）、`FCB_STORAGE_TYPE` / `FCB_STORAGE_PATH`（存储后端）、`FCB_USER_ALLOW_REGISTRATION`（开放注册）、`CONFIG_PATH`（配置文件路径）。
