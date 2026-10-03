# Changelog

各模块仓独立发版；本文件记录工作区级的重要变更（格式参考 Keep a Changelog）。

## [Unreleased]

### Added
- **真·S3 预签名直传直下**（core）：存储后端为 s3 时 `presign.Init` 直接签发对象存储
  预签名 PUT URL（`meta.Scheme=s3`），上传流量不过服务器；`Complete` 向 S3 核实对象
  真实存在并以实际大小落库（服务器未接触内容，秒传指纹依赖客户端预计算哈希）。
  下载侧新增 `download.s3_direct_download`（env `FCB_DOWNLOAD_S3_DIRECT`，默认关）：
  开启后文件下载 302 到短时效预签名 GET。**注意**：浏览器直传/直下需在对象存储桶上
  配置 CORS 允许站点来源；local/webdav 后端自动回退自家中转，行为不变。
- **存储后端点亮**（core）：S3 / WebDAV 真实读写全链路（opendal 驱动：minio-go / gowebdav），
  `StorageService` 按配置类型分派；本地盘路径行为零改动。
- **在线切换存储后端**（core）：管理端切换/保存走「SSRF 校验 → 认证级 Probe → 热重载 → 持久化」，
  重启后从 `system_configs.runtime_storage` 恢复（env > DB > yaml）；`StorageInfo` 新增
  `effective` 字段展示实际生效后端。
- **presign 直传接入存储分派**（core）：直传落盘跟随当前激活后端（此前硬编码本地盘）。
- **首启引导**：`/api/config` 返回真实 `initialized`；前端新增 `/setup` 初始化页（含 i18n）。
- **开源合规件**：7 仓 MIT LICENSE；CONTRIBUTING / SECURITY / CHANGELOG / ROADMAP / 双语 README。

### Changed
- `core/bootstrap`：StorageService 改为进程内单例（此前 3 处各建实例，在线切换无法生效）。
- `core/app/admin`：`SystemConfig` 新增 `runtime_storage` 段（存储域经接口读写，本域只持久化）；
  `UpdateConfig` 对该段做防御性合并。
- opendal `Operator.New`：s3/webdav 参数缺失时返回错误（不再静默回退 fs）。

### 升级说明
- 新增直接依赖：`github.com/minio/minio-go/v7`、`github.com/studio-b12/gowebdav`（core）。
- 局域网对象存储/WebDAV（NAS 场景）需 `security.ssrf.allow_private_networks: true`（既有机制）。
- 存量部署（`storage.type=local`）行为不变；详细设计见
  [docs/design/2026-10-03-storage-lightup-and-onboarding.md](docs/design/2026-10-03-storage-lightup-and-onboarding.md)。

## [0.2.0] - 2026-10-02

- 单体拆分为 contracts / core / server / frontend / filecodebox-fnos / charts 多仓。
- 安全基线：分享密码修复、失败锁定、下载令牌、SSRF 校验、魔数检测、文件名消毒、审计接线。
- 管理端站点配置 DB 持久化（`system_configs` 单行写穿）。

## [0.1.0] - 2026-07

- Go 重写版首发布（对照 Python 原版 vastsa/FileCodeBox 的功能面）。
