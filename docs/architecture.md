# FileCodeBox 架构文档

> 装配仓的架构总览:生态全景、仓库依赖、core 内部分层、运行时请求流、数据流、部署形态与发布流水线。
> 所有图均为 Mermaid,GitHub 原生渲染。版本与仓库角色速查见 [README](../README.md)。

---

## 1. 生态全景

```mermaid
graph TB
    subgraph ORG["filescodebox 组织"]
        UMB["📁 FileCodeBox<br/>(装配仓·本仓库)<br/>make setup 拉齐工作区"]
        CT["📦 contracts<br/>契约层 v0.1.0<br/>errcode + Thrift 类型"]
        CORE["🧩 core<br/>业务核心库 v0.2.0<br/>10 域服务 + bootstrap"]
        SRV["🚀 server<br/>部署应用 v0.1.1<br/>main 薄壳 + Dockerfile"]
        FE["🖥️ frontend<br/>Vue3 + TS"]
        FNOS["🐂 filecodebox-fnos<br/>飞牛 fnOS 应用 v0.1.2<br/>SSO/共享目录/通知/穿透"]
    end

    USER["👤 自托管用户"] -->|"docker run / compose"| SRV
    NAS["🏠 飞牛 NAS 用户"] -->|".fpk 单容器"| FNOS
    DEV["👨‍💻 开发者"] -->|"git clone + make setup"| UMB

    UMB -.->|"setup.sh 拉取"| CT & CORE & SRV & FE
```

**职责边界**:装配仓不含业务代码,只提供工作区装配(`setup.sh`/`go.work`/`Makefile`/`docker-compose.yml`);六个模块仓库独立开发、独立 CI、独立发版。

---

## 2. 仓库依赖关系

### 2.1 依赖图(构建期,单向无环)

```mermaid
graph LR
    FE["frontend<br/>(Vue3)"] -->|"openapi.json 契约快照<br/>→ api.gen.ts 类型"| CTX["contracts"]
    SRV["server"] -->|"require v0.2.0"| CORE["core"]
    FNOS["filecodebox-fnos"] -->|"require v0.2.0<br/>库式调用 bootstrap"| CORE
    CORE -->|"require v0.1.0"| CTX

    classDef plain fill:#eef,stroke:#88a
    class CTX,CORE,SRV,FE,FNOS plain
```

### 2.2 依赖规则(CI 强制守护)

| 规则 | 守护方式 |
|------|---------|
| contracts 零项目内依赖(纯类型,仅 thrift runtime + 标准库) | contracts CI:`go list -deps` 检查 |
| core 不许 import server / frontend / fnos | core CI 同上 |
| server / fnos 只经 go.mod 正式版本引用 core,**零 replace** | 各仓 go.mod 无 replace(本地联编由本仓 go.work 承担) |
| frontend 类型由 openapi.json 生成,不手抄 | frontend CI:`npm run gen:api` 后 `git diff --exit-code` |

### 2.3 版本矩阵

| 仓库 | 当前版本 | 说明 |
|------|---------|------|
| contracts | v0.1.0 | thrift v0.13 生成代码,版本约束以 require 传递(下游零 replace) |
| core | v0.2.0 | v0.2.0 含分享密码保护安全修复 |
| server | v0.1.1 | 镜像 `ghcr.io/filescodebox/server` |
| filecodebox-fnos | v0.1.2 | 镜像 `ghcr.io/filescodebox/filecodebox-fnos` |

---

## 3. core 内部分层架构

```mermaid
graph TB
    subgraph BOOT["bootstrap/(库入口)"]
        BS["Bootstrap(configPath)<br/>BootstrapWithOptions(opts...)"]
        OPT["Options: WithStaticDir..."]
    end

    subgraph TRANSPORT["传输层"]
        GENH["gen/handler + gen/router<br/>(thrift 生成装配,15 域路由)"]
        HAND["transport/http<br/>(手写 handler + 9 个中间件)"]
    end

    subgraph APP["业务层 app/(10 个域,近零耦合)"]
        SHARE["share 分享"]
        CHUNK["chunk 分片"]
        ANON["anonymous 匿名取件"]
        PRESIGN["presign 预签名直传"]
        ADMIN["admin 管理"]
        USER["user 用户/JWT/APIKey"]
        NOTIFY["notify 通知"]
        QRCODE["qrcode 二维码"]
        SETUP["setup 初始化"]
        STORAGESVC["storage 存储管理"]
    end

    subgraph INFRA["基础设施层"]
        REPO["repo/db(gorm dao+model·8表)<br/>repo/redis(可选,缺省降级)"]
        STOR["storage(OpenDAL: local / s3)"]
        PKG["pkg/(auth·logger·middleware<br/>·resp·errcode→contracts·utils)"]
        PREVIEW["preview(文件预览)"]
    end

    subgraph DATA["数据"]
        DB[("SQLite / MySQL / PostgreSQL")]
        REDIS[("Redis(可选)")]
        OSS[("本地磁盘 / S3 兼容对象存储")]
    end

    BS --> GENH & HAND
    GENH --> SHARE & CHUNK & ANON & PRESIGN & ADMIN & USER & NOTIFY & QRCODE & SETUP & STORAGESVC
    HAND --> SHARE
    PRESIGN -.->|"唯一跨域依赖<br/>经接口注入"| SHARE
    APP --> REPO & STOR & PKG & PREVIEW
    REPO --> DB & REDIS
    STOR --> OSS
```

**分层纪律**(继承原 internal 设计):业务层不依赖传输协议、不直接操作数据库(经 repo);域与域之间不互相 import(presign→share 唯一例外,经接口注入)。

### 3.1 全局中间件链(顺序敏感)

```
Recovery → RequestID → AccessLog → Metrics → SecurityHeaders → CORS → handler
(panic→500) (trace_id)  (结构化日志) (RED指标)  (安全响应头)     (跨域)
```

---

## 4. 运行时请求流

```mermaid
sequenceDiagram
    participant B as 浏览器/Vue3
    participant H as Hertz Server(bootstrap 装配)
    participant MW as 中间件链
    participant GH as gen/handler
    participant S as app/* 域服务
    participant R as repo 层
    participant D as DB / 存储

    B->>H: HTTP /share/text/(POST, JWT)
    H->>MW: Recovery→RequestID→AccessLog→Metrics→Security→CORS
    MW->>GH: 路由匹配(gen/router)
    GH->>GH: BindAndValidate(thrift 模型)
    GH->>S: ShareTextWithAuth(...,requireAuth,passwordHash,...)
    S->>S: 密码 bcrypt 哈希/过期计算/code 生成(冲突重试)
    S->>R: Create
    R->>D: INSERT file_codes
    S-->>GH: ShareResp(code, url)
    GH-->>B: 200 {code, url}(经 resp 统一包装/errcode)
```

**关键路径**:`/live` `/ready` 健康检查、`/metrics` Prometheus(9090 独立端口)、静态资源(StaticDir 选项,SPA fallback)均在 bootstrap 层注册,不经过业务。

---

## 5. 关键数据流

### 5.1 文件上传(双路径)

```mermaid
flowchart LR
    A[用户选文件] --> B{大小?}
    B -->|"< 100MB"| C["POST /share/file/(multipart)<br/>→ 存储落盘 → 建 file_codes 记录"]
    B -->|"≥ 100MB"| D["POST /presign/init<br/>(密码此时哈希入 InitMeta)"]
    D --> E["PUT 预签名 URL 直传对象存储<br/>(分片,浏览器直连,进度条)"]
    E --> F["POST /presign/complete<br/>→ 验 token → 合并分片状态 → 建分享"]
    C --> G[("分享码 + URL + 二维码")]
    F --> G
```

### 5.2 取件与密码保护(v0.2.0 修复后)

```mermaid
flowchart TD
    A["GET /share/select/?code=X"] --> B{require_auth?}
    B -->|否| Z[返回内容]
    B -->|是| C{password 参数?}
    C -->|空| D["401 需要密码<br/>has_password:true"]
    C -->|非空| E{bcrypt 校验<br/>PasswordHash}
    E -->|不匹配/哈希缺失| F["401 密码错误<br/>(空哈希一律拒绝)"]
    E -->|匹配| Z
    Z --> Y["记录取件人 → 通知 owner(fire-and-forget)<br/>下载链路扣减次数(原子防超卖)"]
```

### 5.3 飞牛 fnOS 形态(单容器库式调用)

```mermaid
graph LR
    subgraph CONTAINER["单个容器(飞牛 .fpk)"]
        MAIN["fnos-adapter(main)"] --> ENS["ensureJWTSecret<br/>自动生成密钥持久化数据卷"]
        MAIN --> BOOT["bootstrap.Bootstrap()<br/>(库调用,拉起全部业务)"]
        MAIN --> ADP["adapter.Mount(h)<br/>/api/fnos/* 路由组"]
        ADP --> SSO["SSO 免登录"] & DIR["共享目录"] & NT["通知中心"] & TN["内网穿透"]
    end
    FNOSAPI["飞牛 Open API"] -.-> SSO & DIR & NT & TN
    subgraph VOL["${TRIM_PKGVAR}/data(NAS 共享文件夹)"]
        DB2[("SQLite + 上传文件 + .jwt_secret")]
    end
    CONTAINER --> VOL
```

凭证缺失时 adapter 进入**降级模式**:`/api/fnos/*` 返回 503,业务全部正常。

---

## 6. 部署形态对比

| | server(自托管) | filecodebox-fnos(飞牛) |
|---|---|---|
| 进程 | 1 个二进制(main → core) | 1 个二进制(adapter → core) |
| 前端 | 镜像内 static/(npm ci 现场构建) | 同镜像复用 core 静态服务(StaticDir) |
| 配置 | config.yaml + FCB_* env | FNOS_* env + 飞牛向导变量 |
| JWT 密钥 | FCB_JWT_SECRET 必填(强校验) | 自动生成并持久化(装机即用) |
| 数据 | docker volume | NAS 共享目录(用户可见可备份) |
| 镜像 | ghcr.io/filescodebox/server | ghcr.io/filescodebox/filecodebox-fnos |

---

## 7. CI / 发布流水线

```mermaid
flowchart LR
    subgraph PR["每次 push / PR(五仓)"]
        GO["contracts/core/fnos:<br/>build + vet + test + 依赖守护"]
        FECI["frontend:<br/>typecheck + build + 类型同步校验"]
        SRVCI["server:<br/>build + vet(+ main 时 docker 构建)"]
    end
    subgraph REL["打 v* tag(server / fnos)"]
        B["buildx 多架构<br/>amd64 + arm64"] --> P["推 ghcr.io/filescodebox/*<br/>version + minor + latest"]
    end
    COREDEV["core 发新版本"] -->|"各下游 go.mod 升级<br/>(require 正式版本)"| REL
```

**发版流程**:core 改动 → tag(core vX)→ server/fnos `go mod edit -require core@vX` → commit → 打自身 tag → CI 自动出镜像。全程无需 replace。

---

## 8. 技术栈

| 层 | 技术 |
|----|------|
| 后端 | Go 1.26 · CloudWeGo Hertz · GORM(SQLite/MySQL/Postgres) · go-redis(可选) |
| 契约 | Thrift IDL(v0.13 生成,require 传递版本约束) · OpenAPI 3 |
| 存储 | OpenDAL(local / S3 兼容) |
| 前端 | Vue 3 · TypeScript · Vite · Element Plus · Pinia · openapi-typescript |
| 可观测 | zap 结构化日志 · Prometheus RED 指标 · X-Trace-Id 链路 |
| 安全 | bcrypt 分享密码 · JWT + API Key · CORS 白名单 · 限流(Redis/内存) · 安全响应头 |
| 构建 | Docker 三阶段 · GitHub Actions(多架构) · ghcr |
