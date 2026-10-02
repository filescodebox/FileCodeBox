# FileCodeBox v2

> 一个专为自托管场景打造的高性能文件/文本分享平台，采用前后端分离架构。

> **📢 本仓库已拆分(2026-10)**:活跃开发已迁移至 [filescodebox 组织](https://github.com/filescodebox)的多仓库结构——
> [contracts](https://github.com/filescodebox/contracts)(错误码+Thrift 类型)/ [core](https://github.com/filescodebox/core)(业务核心库)/ [server](https://github.com/filescodebox/server)(部署应用)/ [frontend](https://github.com/filescodebox/frontend)(Vue3 前端)/ [filecodebox-fnos](https://github.com/filescodebox/filecodebox-fnos)(飞牛 fnOS 应用适配层)。
> 本仓库保留为历史存档与 [组织镜像](https://github.com/filescodebox/FileCodeBox)。

---

## 📌 项目概览

FileCodeBox 是一个使用 Go + Vue 3 实现的轻量级分享服务，采用前后端分离架构：

- **Backend**: Go + CloudWeGo Hertz + GORM
- **Frontend**: Vue 3 + TypeScript + Vite + Element Plus

### 你可以用它做什么？

- 📁 **拖拽上传**，生成短链接后分享文件或文本片段
- 🔐 **后台管理**，集中查看、搜索、统计、审核、删除分享内容
- 🪶 **多存储后端**，根据需求切换本地/对象存储方案
- ⚙️ **自定义配置**，调整限速、过期策略等

---

## 📸 界面预览

**首页（文件 / 文本分享）**

![首页](https://raw.githubusercontent.com/zy84338719/FileCodeBox/main/docs/screenshots/01-home.png)

**匿名取件**

![匿名取件](https://raw.githubusercontent.com/zy84338719/FileCodeBox/main/docs/screenshots/08-retrieve.png)

**管理后台 - 仪表盘**

![仪表盘](https://raw.githubusercontent.com/zy84338719/FileCodeBox/main/docs/screenshots/04-admin-dashboard.png)

**管理后台 - 文件管理**

![文件管理](https://raw.githubusercontent.com/zy84338719/FileCodeBox/main/docs/screenshots/05-admin-files.png)

**管理后台 - 用户管理 / 存储管理**

![用户管理](https://raw.githubusercontent.com/zy84338719/FileCodeBox/main/docs/screenshots/06-admin-users.png)

![存储管理](https://raw.githubusercontent.com/zy84338719/FileCodeBox/main/docs/screenshots/07-admin-storage.png)

**登录页（用户 / 管理员）**

![用户登录](https://raw.githubusercontent.com/zy84338719/FileCodeBox/main/docs/screenshots/02-user-login.png)

![管理员登录](https://raw.githubusercontent.com/zy84338719/FileCodeBox/main/docs/screenshots/03-admin-login.png)

---

## 🌟 关键特性

| 分类 | 能力速览 |
| --- | --- |
| 性能 | Go 原生并发、分片上传、断点续传、秒传校验 |
| 分享体验 | 文本/文件双通道、链接有效期控制、密码和访问次数限制、**匿名取件（vastsa UX）** |
| 管理后台 | 仪表板、文件列表、用户管理、存储面板、系统配置、**系统通知公告** |
| 安全 | JWT 认证（全环境 fail-fast + 并发安全）、API Key 支持、**限流中间件（登录/上传/下载路径感知）**、**CORS 默认仅 localhost 跨域**、**安全响应头**（HSTS/X-Frame-Options 等）、**取件密码 bcrypt**、**上传大小+类型黑名单校验**、**metrics 默认关闭+内网绑定** |
| 存储 | 本地磁盘、S3 兼容对象存储、WebDAV、NFS、**OpenDAL 风格抽象** |
| 上传 | 直传 + **预签名上传**（init/complete/abort） |
| 可观测性 | **Prometheus 指标（HTTP RED）**、**结构化访问日志（trace_id 全链路）**、**深度就绪探针（/readyz）** |
| 工程 | **统一错误码体系**、**统一响应 envelope**（code/message/data/trace_id）、**核心写操作事务保证**、**全量结构化日志**、**120+ 单测覆盖核心业务** |
| 部署 | **单二进制**（内置前端 SPA）、Docker、**生产 Compose（含 Redis+Nginx）**、**K8s（探针/Ingress/HPA/ServiceMonitor）**、**环境变量配置（12-factor）** |
| 前端 | Vue 3 + TypeScript、自适应布局、现代化 UI |

---

## 🧩 项目结构

```
FileCodeBox/
├── backend/           # Go 后端 (Hertz v0.9.6 + Thrift IDL)
│   ├── cmd/server/    # 入口 + bootstrap
│   ├── internal/      # 内部包
│   │   ├── app/       # 业务逻辑（user/admin/share/anonymous/presign/notify/...）
│   │   ├── repo/      # 数据访问（db/redis）
│   │   ├── conf/      # 配置
│   │   ├── pkg/
│   │   │   ├── errcode/   # 业务码段位（1xxxx/2xxxx/...）
│   │   │   ├── resp/      # 统一响应 envelope（带 trace_id）
│   │   │   ├── middleware # auth + ratelimit
│   │   │   └── ...
│   │   └── storage/
│   │       ├── storage.go     # 旧 4-driver 抽象（local/s3/webdav/nfs）
│   │       └── opendal/      # OpenDAL 风格抽象
│   ├── gen/http/      # hz 生成（thrift）
│   │   ├── handler/   # HTTP handlers（stub + 业务覆盖）
│   │   ├── model/     # Thrift 生成的模型
│   │   └── router/    # 路由注册
│   ├── idl/           # Thrift IDL（从 proto 全量迁移）
│   ├── scripts/       # hz 生成脚本 + 工具安装
│   └── configs/       # 配置文件
│
├── frontend/          # Vue 3 前端
│   ├── src/
│   │   ├── views/     # 页面组件
│   │   ├── api/       # API 调用
│   │   ├── stores/    # 状态管理
│   │   └── router/    # 路由
│   └── dist/          # 构建产物
│
├── Makefile           # 构建脚本
├── docker-compose.yml # Docker Compose 配置
└── README.md
```

---

## 🚀 快速起步

### 1. 环境要求

- **Go** 1.21+
- **Node.js** 18+
- **SQLite / MySQL / PostgreSQL**（默认 SQLite）
- Docker 20+（可选）

### 2. 本地开发

```bash
# 安装依赖
make deps

# 开发模式（前后端同时启动）
make dev

# 或分别启动
make dev-backend   # 后端 :12345
make dev-frontend  # 前端 :5173
```

### 3. 生产构建

```bash
# 完整构建
make build

# 或分步构建
make build-frontend  # 构建前端
make build-backend   # 构建后端
make copy-frontend   # 复制前端到 backend/static/
```

### 4. 生产部署（4 种方式，任选其一）

#### 方式 A：单二进制（最简单，内置前端 SPA）

```bash
make build                # 构建前端 + 后端（前端嵌入 static/）
cd backend && ./bin/server  # 单二进制即可打开前端 + 全部 API
```

#### 方式 B：Docker 单容器

```bash
docker run -d --name filecodebox \
  -p 12345:12345 \
  -v ./data:/app/data \
  -e FCB_PRODUCTION=1 \
  -e FCB_JWT_SECRET=$(openssl rand -hex 32) \
  ghcr.io/zy84338719/filecodebox:latest
```

#### 方式 C：生产 Compose（后端 + Redis + Nginx 全栈）

```bash
cp .env.example .env       # 填写 JWT_SECRET 等密钥
docker compose -f docker-compose.prod.yml up -d
```

#### 方式 D：Kubernetes（生产级，含探针/伸缩/监控）

```bash
# 1. 编辑 deploy/k8s/base/secret.yaml 填入真实 JWT_SECRET
# 2. 编辑 deploy/k8s/base/ingress.yaml 填入域名
kubectl apply -k deploy/k8s/base        # 或生产 overlay：
kubectl apply -k deploy/k8s/overlays/prod
```

> 服务默认监听 `http://0.0.0.0:12345`，首次启动默认管理员 `admin / admin123`（**生产请立即修改**）。

### 5. 配置与环境变量

配置优先级：**环境变量 > 配置文件(yaml) > 默认值**。敏感配置（密钥/密码）建议用环境变量注入，详见 [`docs/ENVIRONMENT_VARIABLES.md`](docs/ENVIRONMENT_VARIABLES.md)。

```bash
# 常用环境变量（FCB_ 前缀完整名 或 短名均可）
FCB_SERVER_PORT=12345        # 服务端口
FCB_JWT_SECRET=xxx           # JWT 密钥（⚠️ 全环境必填！未设或为默认值启动即报错退出）
FCB_DATABASE_DRIVER=sqlite   # sqlite/mysql/postgres
FCB_REDIS_HOST=redis         # Redis 地址（匿名取件功能依赖 Redis）
FCB_METRICS_ENABLED=false    # Prometheus 指标开关（默认关闭，开启时绑定内网）
FCB_METRICS_ADDR=127.0.0.1:9090  # metrics 独立监听地址（开启时生效）
FCB_CORS_ALLOW_ORIGINS=https://your-domain.com  # CORS 白名单（未配时默认仅 localhost 跨域）
```

> ⚠️ **安全提示**：`FCB_JWT_SECRET` 在所有环境（含开发）都必须设置为强随机值（≥32 字符），否则启动 fail-fast。生成方式：`openssl rand -hex 32`。

完整配置模板见 [`backend/configs/config.example.yaml`](backend/configs/config.example.yaml)。

### 6. 可观测性

| 端点 | 用途 |
| --- | --- |
| `GET 127.0.0.1:9090/metrics` | Prometheus 指标（HTTP RED，**默认关闭，开启时绑定内网独立端口**，主端口不暴露） |
| `GET /readyz` | 深度就绪检查（含 DB ping，供 K8s readinessProbe） |
| `GET /live` | 存活检查（轻量，供 livenessProbe） |
| `GET /health` | 健康检查 |
| `GET /openapi.json` | OpenAPI 3.0 规范（Swagger UI） |

所有日志为 zap 结构化 JSON，带 `trace_id`（`X-Trace-Id` header 透传），便于全链路排障。

---

## 📚 API 概览

### 公开 API

| 接口 | 说明 |
| --- | --- |
| `POST /share/text/` | 分享文本 |
| `POST /share/file/` | 分享文件 |
| `GET /share/select/?code=...` | 获取分享内容 |
| `GET /share/download` | 下载文件 |
| `POST /user/register` | 用户注册 |
| `POST /user/login` | 用户登录 |
| `GET /health` | 健康检查 |

### 认证 API (需要 JWT Token)

| 接口 | 说明 |
| --- | --- |
| `GET /user/info` | 用户信息 |
| `POST /api/v1/user/refresh` | **刷新 token**（前端 401 拦截器自动调用） |
| `GET /user/files` | 用户文件列表 |
| `GET /user/api-keys` | API Key 列表 |
| `POST /user/api-keys` | 创建 API Key |

### 管理 API (需要 Admin Token)

| 接口 | 说明 |
| --- | --- |
| `POST /admin/login` | 管理员登录 |
| `GET /admin/stats` | 系统统计 |
| `GET /admin/files` | 文件列表 |
| `GET /admin/users` | 用户列表 |
| `GET /admin/storage` | 存储信息 |

### 分片上传

| 接口 | 说明 |
| --- | --- |
| `POST /chunk/upload/init/` | 初始化上传 |
| `POST /chunk/upload/chunk/:id/:idx` | 上传分片 |
| `POST /chunk/upload/complete/:id` | 完成上传 |
| `GET /chunk/upload/status/:id` | 上传状态 |
| `DELETE /chunk/upload/cancel/:id` | 取消上传 |

### 预签名上传 & 匿名取件

| 接口 | 说明 |
| --- | --- |
| `POST /api/v1/presign/upload` | 申请预签名上传（返回 upload_id + token） |
| `PUT /api/v1/presign/upload-direct/:uploadID` | **预签名直传**（带 X-Upload-Token，写文件到存储） |
| `POST /api/v1/presign/complete` | 完成上传（写分享表） |
| `POST /anonymous/generate` | 匿名生成 6 位取件码（需 Redis） |
| `POST /anonymous/retrieve` | 匿名取件（校验密码 + 扣减次数，DB 为准） |
| `GET /anonymous/search/:code` | 匿名查询分享信息 |

---

## 🔐 认证方式

1. **JWT Token**: 用户/管理员登录后获取，放在 `Authorization: Bearer <token>` 头中。token 过期时前端自动调 `/api/v1/user/refresh` 刷新。
2. **API Key**: 格式 `fcb_sk_xxx`，放在 `X-API-Key` 头或 `api_key` 查询参数中

---

## 🏗️ 架构总览

```
┌─────────────────────────────────────────────────────────┐
│                      浏览器 (Vue 3 SPA)                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │
│  │ 文件分享 │  │ 匿名取件 │  │ 管理后台 │  │ 用户中心│ │
│  └─────┬────┘  └─────┬────┘  └─────┬────┘  └────┬────┘ │
└────────┼────────────┼────────────┼────────────┼────────┘
         │            │            │            │
         ▼            ▼            ▼            ▼
┌─────────────────────────────────────────────────────────┐
│              Hertz HTTP Server (:12345)                  │
│  ┌────────────────────────────────────────────────────┐ │
│  │ 中间件链: Recovery → RequestID → AccessLog →       │ │
│  │   Metrics → SecurityHeaders → CORS → 限流(路径感知)│ │
│  └────────────────────────────────────────────────────┘ │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐ │
│  │  app/share  │  │app/anonymous│  │   app/admin     │ │
│  │ (分享/取件) │  │ (6位取件码) │  │  (后台/统计)    │ │
│  └──────┬──────┘  └──────┬──────┘  └────────┬────────┘ │
│         │                │                  │          │
│  ┌──────▼────────────────▼──────────────────▼────────┐ │
│  │   DAO 层 (dao.FileCodeRepository / Notify / ...)  │ │
│  │   统一走全局 db.GetDB()，事务保证写一致性          │ │
│  └──────┬──────────────────────────────┬─────────────┘ │
└─────────┼──────────────────────────────┼───────────────┘
          ▼                              ▼
   ┌────────────┐               ┌────────────────┐
   │  数据库     │               │     Redis      │
   │ SQLite/     │               │ 匿名取件码映射 │
   │ MySQL/PG    │               │ presign meta   │
   └────────────┘               └────────────────┘
          ▲
          │
   ┌──────┴──────┐   ┌──────────────┐
   │  存储抽象   │   │ metrics 独立 │
   │ local/s3/   │   │ :9090(内网)  │
   │ webdav/nfs  │   │ 默认关闭     │
   └─────────────┘   └──────────────┘
```

> 📊 详细测试验证见 [本地测试报告](docs/LOCAL-TEST-REPORT.md)

---

## 🛠️ 配置说明

配置文件位于 `backend/configs/config.yaml`:

```yaml
server:
  host: "0.0.0.0"
  port: 12345

database:
  driver: "sqlite"
  db_name: "./data/filecodebox.db"

storage:
  type: "local"
  path: "./data/uploads"

user:
  allow_user_registration: true
```

---

## 🧑‍💻 开发指南

### 添加新 API

1. 在 `backend/idl/http/` 添加 `.thrift` 文件
2. 运行 `make thrift-gen IDL=idl/http/your_api.thrift` 或 `make thrift-gen-all`（CI 用）
3. 实现 `backend/gen/http/handler/` 中的 handler
4. 在 `backend/internal/app/` 中添加业务逻辑

### 修改前端

1. 修改 `frontend/src/` 下的代码
2. 运行 `make build-frontend` 构建
3. 运行 `make copy-frontend` 复制到后端

---

## 🚧 已知限制 / 后续计划

| 项 | 状态 | 说明 |
| --- | --- | --- |
| OpenDAL 真实 binding | 待 Linux 部署 | macOS/Windows 编译走 stub；Linux 生产环境启用 Apache OpenDAL Go binding，对接 S3/OSS/WebDAV/HDFS 等 |
| proto IDL | ✅ 已全量切 thrift | proto → thrift 迁移完成，CI 走 `make thrift-gen-all` |
| 前端 i18n | ✅ 已完成 | vue-i18n 接入（zh-CN / en-US） |
| 前端暗色模式 | ✅ 已完成 | 暗色模式 + 顶栏切换器 |
| 环境变量配置 | ✅ 已完成 | viper env 绑定（FCB_ 前缀 + 短名），12-factor 合规 |
| 生产可观测性 | ✅ 已完成 | Prometheus 指标 + 结构化访问日志(trace_id) + 深度就绪探针 |
| 安全加固 | ✅ 已完成 | 密码 bcrypt + 限流挂载 + JWT 全环境 fail-fast + CORS 收紧 + 上传校验 + metrics 内网隔离 + 前端 XSS 消毒 |
| K8s 生产部署 | ✅ 已完成 | 探针/Ingress/HPA/ServiceMonitor/Secret/ConfigMap + prod overlay |
| 业务单测覆盖率 | ✅ 已完成 | 12 包 120+ case，覆盖核心业务（含事务/原子扣减/密码校验/匿名取件 DB 打通） |
| 数据库版本化迁移 | 待做 | 当前用 GORM AutoMigrate；企业级可引入 golang-migrate 做版本化 baseline |
| 限流持久化 | 待做 | 当前 ratelimit 为内存态；多副本需 Redis 持久化保证一致 |
| OpenTelemetry 追踪 | 待做 | 已留 observability.tracing 配置位，OTel 中间件 + OTLP exporter 待接入 |
| 限流压测 | 待压测平台 | ratelimit 中间件已实现并单测覆盖；QPS 阈值校准需 k6/wrk 验证 |

---

## 📄 许可证

MIT License © FileCodeBox Contributors
