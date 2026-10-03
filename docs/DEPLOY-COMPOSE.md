# Docker Compose 部署指南

单容器自托管的推荐路径。三种部署形态,按需选择:

| 形态 | 命令 | 适用 |
|---|---|---|
| 直连体验 | `docker compose up -d` | 本机/内网快速试用,`http://<host>:12345` |
| nginx 反代 | `docker compose --profile nginx up -d` | 正式对外:统一 80/443 入口、TLS、缓存与超时治理 |
| Kubernetes | `charts/` 仓库 `filecodebox` chart | 多副本、Ingress、监控接入(见 charts 仓库 README) |

## 快速开始

```bash
cp .env.example .env      # 全部项有安全默认,可留空;生产至少设 FCB_ADMIN_PASSWORD
docker compose up -d
curl http://localhost:12345/live    # 健康检查
```

默认管理员 `admin / admin123`(未注入 `FCB_ADMIN_PASSWORD` 时,启动日志有警告),登录后请立即改密。

ghcr 拉取报 `unauthorized` 时:`docker login ghcr.io` 后重试(私有可见性期间),或在 `.env` 用 `FCB_IMAGE_TAG` 切换可用 tag。

本地构建(需先 `make setup` 拉齐模块仓):

```bash
BUILD=1 make compose-up       # = docker compose up -d --build
```

## JWT 密钥机制

core 自 v0.3 起对密钥做 fail-fast 校验(空值或已知默认值拒绝启动),**必须提供一个强随机密钥**,两种方式:

1. **自动生成(默认)**:`FCB_JWT_SECRET` 留空时,容器首启生成 48 位随机值并持久化到 `./data/.jwt_secret`(权限 600),重启/升级沿用,所有已登录会话不失效。
2. **显式注入(生产建议)**:在 `.env` 设 `FCB_JWT_SECRET=$(openssl rand -hex 32)`。注入后容器直接使用该值,不读写密钥文件。

轮换:改 `.env` 后 `docker compose up -d` 重建容器即可;旧 JWT 全部失效(用户需重新登录,已发出的取件令牌不受影响)。注意自动生成模式下 `./data/.jwt_secret` 属于敏感文件,备份/传输数据目录时同样要保密。

## nginx 反代部署(profile nginx)

```bash
cp .env.example .env
# .env 中两项必设:
#   FCB_TRUSTED_PROXIES=<compose 容器网段 CIDR>
#   FCB_SERVER_BASE_URL=https://<对外完整地址>
docker compose --profile nginx up -d     # 占用宿主 80(FCB_HTTP_PORT 可改)
```

**为什么 trusted_proxies 必填**:后端对 `X-Forwarded-For` 做 CIDR 可信校验,只有直连对端落在可信网段内才采信 XFF。不配置则限流/登录失败锁定全部按 nginx 的 IP 计数——所有用户共享一个限流桶,一人触发全员受限,且失败锁定会误伤。compose 默认网络落在 `172.16.0.0/12` 池内,`.env.example` 给了这个宽值;要收窄就用 `docker network inspect <项目目录名>_default | grep Subnet` 查精确网段。

启用反代后建议再设 `FCB_API_BIND=127.0.0.1` 把后端直连入口收进回环:部分宿主防火墙/NAT 会把外部直连流量 SNAT 成 docker 网关地址(恰好在可信网段内),此时直连客户端可伪造 XFF 绕过按 IP 的限流与锁定;收进回环后所有流量必须走反代,来源 IP 全部可信解析。

HTTPS / 子路径部署:模板 `deploy/nginx/nginx.conf` 内置了 443 server 块与 `/fcb/` 子路径前缀改写的完整注释示例,取消注释、挂载证书即可,此处不重复。该文件头部还有 `client_max_body_size` 与后端 `upload.upload_size / max_file_size / chunk_size` 的三处配平说明,调上传上限前先读。

数据面路径相关的路由(下载/分片/预签名)已在模板中关闭缓冲并放宽超时,大文件不再占用 nginx 缓冲区,慢速客户端不会被 60s 默认超时切断。

## 数据、备份与升级

- 全部状态在 `./data`:SQLite 库、上传文件、`.jwt_secret`。容器本身无状态,可随时销毁重建。
- 备份:停机窗口内直接拷贝 `./data`;不停机则用 `sqlite3 data/filecodebox.db ".backup '...'"` 做一致性快照(上传文件目录另行拷贝)。管理后台在线改过的站点配置也在这份库里(`system_configs` 表),备库即备份全部配置。
- 升级:`.env` 钉住 `FCB_IMAGE_TAG`(建议具体版本而非 latest)→ 改 tag → `docker compose up -d`(自动重建容器,数据卷不动)。回滚即把 tag 改回旧版本。
- 容器日志已配 json-file 轮转(单容器 10MB×3),无担心无限增长。

## 常见问题

| 现象 | 原因与处理 |
|---|---|
| 容器反复重启,日志 `a secure user.jwt_secret is required` | 数据目录不可写导致密钥文件写不进(Linux 裸 Docker 常见):`mkdir -p data && sudo chown 1000:1000 data` 后重启 |
| 限流"误伤"(一人超限全员受限)/ 登录错误锁定所有人 | 反代部署未配 `FCB_TRUSTED_PROXIES`,见上节 |
| ghcr 镜像拉取 `unauthorized` | `docker login ghcr.io`,或换可用 `FCB_IMAGE_TAG` |
| 80/12345 端口被占 | `.env` 改 `FCB_HTTP_PORT` / `FCB_API_PORT` |
| 想临时关掉反代 | `docker compose --profile nginx up -d` 只重排 filecodebox;彻底停 nginx:`docker compose stop nginx` |

完整环境变量(存储后端/Redis/限流/审核/MCP 等)见 [ENVIRONMENT_VARIABLES.md](ENVIRONMENT_VARIABLES.md)。
