---
title: 部署 Kubernetes (Helm)
---

# 部署 Kubernetes（Helm）

官方 Helm Chart 位于 [filescodebox/charts](https://github.com/filescodebox/charts) 仓库，chart 名 `filecodebox`：部署 `ghcr.io/filescodebox/server` 单容器（镜像内置前端静态资源），可选 Ingress / PVC / Prometheus ServiceMonitor。

## 安装

方式一：Helm 仓库（GitHub Pages，由 chart-releaser 自动发布）：

```bash
helm repo add filescodebox https://filescodebox.github.io/charts
helm repo update
helm install filecodebox filescodebox/filecodebox \
  --namespace filecodebox --create-namespace
```

方式二：OCI 制品（ghcr.io，与 Pages 同步发布）：

```bash
helm install filecodebox oci://ghcr.io/filescodebox/charts/filecodebox
```

## 生产建议

- `--set secret.adminPassword='<强密码>'` 覆盖默认管理密码 `admin123`。
- `--set secret.production=true` 开启 secret 强校验；`FCB_JWT_SECRET` 全环境强制且要求 ≥32 位强随机（chart 自动生成的随机值已满足，显式传入短值会拒绝启动）。
- **反代 / Ingress 部署必须设置 `trustedProxies`**（如 `--set trustedProxies[0]=10.0.0.0/8`），否则应用不采信 `X-Forwarded-For`，限流/登录失败锁定会按代理地址计数、误伤所有用户。原理见[部署 Docker Compose](./deploy-docker) 的 trusted_proxies 一节。
- SQLite + 本地存储保持 `replicaCount: 1`；切到外部 MySQL/Postgres + S3/WebDAV 后才考虑多副本，多副本建议启用 Redis 并设 `config.rate_limit.use_redis: true` 让限流计数跨实例共享。
- Ingress 挂 TLS 时设置 `config.server.base_url` 为对外完整地址（分享链接生成用）；启用 S3 直传/直下需给存储桶配置 CORS。
- 内网 MinIO/WebDAV 场景设置 `config.security.ssrf.allow_private_networks: true`（或 env `FCB_SSRF_ALLOW_PRIVATE=true`）。

## 参数速查

完整参数表（全局 / 网络 / 存储 / 配置注入 / 探针）见 charts 仓库的 [chart README](https://github.com/filescodebox/charts/blob/main/charts/filecodebox/README.md)。常用项：

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `replicaCount` | 副本数（SQLite 部署保持 1） | `1` |
| `containerPort` | 容器内应用监听端口 | `12345` |
| `persistence.enabled` | 持久化 SQLite + 本地上传文件（容器 `/app/data`） | `true` |
| `ingress.enabled` | Ingress（networking.k8s.io/v1） | `false` |
| `metrics.serviceMonitor.enabled` | Prometheus Operator ServiceMonitor | `false` |
| `config` | server 配置，渲染为 ConfigMap 覆盖 `/app/config/config.yaml`。**注意是整体替换**镜像内置配置，需对照 `config.example.yaml` 提供完整结构 | `{}` |
| `secret.jwtSecret` | JWT 密钥；留空随机生成并跨升级复用 | `""` |
| `secret.adminPassword` | 管理员密码（`FCB_ADMIN_PASSWORD`） | `admin123` |
| `secret.extra` | 其他任意 `FCB_*` 键值对（如 `FCB_PRESIGN_SIGNING_KEY`） | `{}` |
| `trustedProxies` | 可信代理网段 CIDR 列表（`FCB_TRUSTED_PROXIES`） | `[]` |

> 环境变量优先级高于配置文件：敏感项一律走 `secret.*`，`config.*` 只放非敏感配置。变量含义见[环境变量参考](./environment)。
