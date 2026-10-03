# 详细设计：用户上传资源管理与管控（治理体系 Phase 1）

- 日期：2026-10-03
- 状态：已评审（方案 A：管控优先，审核留钩子）
- 涉及仓：contracts（错误码）、core（主体）、frontend（管理端页）、hub（本文档 + 配置模板）

## 1. 背景与问题

新版本（core v0.2.0+）相比 legacy 单体已有部分管控底子（四档 IP 限流+热更、登录/取件锁定、
过期双维度清理、传输/审计日志、用户存储配额、下载令牌），但作为可自托管的匿名分享服务，
"管得住、管得清、可追溯"仍不成立：

1. **bug 级缺陷**：`pkg/utils/filecheck.go` `IsAllowedExtension` 白名单未命中反而放行，且短路
   跳过黑名单+魔数检查——配置白名单等于关闭全部类型防护。
2. **假开关**：`upload.open_upload`、`share.require_login`、`download.require_login` 只透传前端，
   服务端不 enforce；`upload.enable_magic_check` 无开关判断无条件执行。
3. **死配置**：`upload.max_save_seconds_cap`、`users.max_upload_size`、
   `download.max_concurrent_downloads`、`transfer.max_count` 定义未消费。
4. **状态机缺失**：`file_codes` 无 status 列，管理员只能删不能禁用，无法"下架留证"。
5. **分片/presign 盲区**：`upload_chunks` 无归属（IP/用户）；Complete 不复查实际总大小；
   配额只查登录用户直传，匿名分片完全绕过。
6. **检索弱**：admin 文件列表仅 keyword 模糊 code/text/path，无 IP/用户/类型/大小/时间/状态过滤，
   `FileCodeQuery` 是空架子；无按 IP 定位恶意上传者的能力。
7. **无封禁/匿名配额**：无 per-IP 匿名上传限额，errcode 缺"封禁/拒绝"语义码。
8. **无内容审核**：无敏感词、无审核钩子（legacy 也没有，属全新建设）。
9. **留痕半成品**：孤儿物理文件无对账任务（注释声称"由清理任务兜底"但任务不存在）；
   审计/传输日志无保留策略；业务 metrics（上传字节、拒绝原因）为零。

已核实：admin/maintenance/ratelimit 三组 IDL 路由 `_adminMw()` 均挂 `AdminMiddleware()`，无越权面。

## 2. 目标 / 非目标

**目标（本轮，三波次）**
1. 上传准入闸门四通道统一收口：类型白/黑名单语义修复、魔数开关、服务端 enforce 开关、
   过期钳制、chunk 完整性复查、匿名 per-IP 日配额。
2. 分享状态机：`file_codes.status`（normal/blocked，预留 pending_review），管理员禁用/恢复
   （单个+批量），blocked 全取件路径拒绝。
3. 管理端治理工具：文件列表强过滤（upload_type/user/owner_ip/status/大小/时间/过期）、
   按 IP 视图、批量操作；前端 Files 筛选栏 + Config 安全限流 tab。
4. 内容审核钩子：`Moderator` 接口 + 内置文本敏感词（默认直接拒绝，可选 pending_review 队列）+
   `share.flagged` webhook 事件；文件侧只留接口。
5. 留痕对账：孤儿文件对账任务（local 删、s3/webdav 只报告）、日志保留策略、业务 metrics。

**非目标（本期不做）**
- 文件内容自动扫描（ClamAV/NSFW 集成）——钩子留位，v2 再接。
- 举报入口（取件页举报按钮）——P2 可选项，暂缓。
- IP 黑名单持久化——限流 block_seconds 已有瞬时封禁，持久黑名单等真实需求出现再做。
- 死配置 `download.max_concurrent_downloads` / `transfer.max_count` 的实现——标 deprecated。
- openapi.json 快照补齐——延续现状（前端手写 admin API client），另行还债。

## 3. 设计

### 3.1 分层

```
请求闸门（rate_limit/lockout，已有）
  └─ 上传闸门（本期）：开关 → 登录要求 → 配额 → 类型/大小/过期 → 内容检查
       └─ 内容检查（本期）：魔数（已有）+ 敏感词（新增，Moderator 钩子）
            └─ 事后管控（本期）：status 状态机、禁用/恢复、清理对账、审计 metrics
```

### 3.2 上传闸门（core）

- `pkg/utils/filecheck.go` 修复语义：`allowed_extensions` 非空必须命中；`blocked_extensions`
  永远执行（新增可配置 `upload.blocked_extensions`，默认=现硬编码列表）；`enable_magic_check`
  真开关。四通道（share 直传/chunk/presign/anonymous）校验收口到一处编排函数。
- 服务端 enforce：`open_upload=false` 拒绝全部匿名上传（错误码 `10012 UploadDisabled`）；
  `share.require_login`/`download.require_login` 接入对应判断。
- 过期钳制：`max_save_seconds_cap` 接入 `CalculateExpireTime`，超限钳到上限，响应回实际值。
- chunk：Complete 合并后复查实际总大小 vs init 申报 + `max_file_size`，超限删物理文件并拒绝；
  `upload_chunks` 增加 `OwnerIP`/`UserID` 列（AutoMigrate，兼容老库）。
- 匿名 per-IP 日配额：`upload.anonymous_daily_count` / `anonymous_daily_bytes`（0=不限），
  Redis 滑动日窗计数（复用 rate_limit Redis 基建，无 Redis 退化内存态），仅对匿名生效；
  错误码 `10014 AnonymousQuotaExceeded`。
- `users.max_upload_size`（管理员为单用户设上限）接入用户上传校验链。

### 3.3 分享状态机（core）

- `FileCode.Status` 字符串列，默认 `normal`，索引 `(status, expired_at)`；`pending_review` 本期
  仅保留取值，P2 敏感词 block_action=pending 时启用。
- 管理端点（延续 bootstrap 手写增强路由先例，挂 `AdminMiddleware` 组）：
  `PUT /admin/files/:id/status`、`POST /admin/files/batch-status`。
- 拒绝点：`GetShare`（取件）、`DownloadFile`、anonymous `Retrieve`/`Download` 统一返回
  `20012 ShareBlocked`；管理员列表/详情不受限。
- 与软删正交：blocked 可恢复留证，delete 走现有软删；禁用/恢复动作走 `logAdminOperation`。

### 3.4 管理端治理工具（core + frontend）

- DAO：`FileCodeQuery` 落地——`upload_type`、`user_id`、`owner_ip`、`status`、
  `min_size/max_size`、`created_after/before`、`expired` 组合过滤 + 现有 keyword。
- 列表响应补充 `owner_ip/upload_type/status/user_username` 字段（脱敏策略：owner_ip 仅管理端可见）。
- 批量禁用/恢复复用 batch-delete 的请求/响应模式。
- 前端：`admin/Files.vue` 增筛选栏 + 状态列 + 禁用/恢复；`admin/Config.vue` 增"安全与限流" tab
  （接已有 `/admin/ratelimit/config|status`）；修复 `Users.vue` 硬编码 1GB 配额条（读实际配额）。

### 3.5 内容审核钩子（core，新 moderation 关注点）

```go
// core/app/moderation
type Verdict int   // allow / reject / pending
type Moderator interface {
    InspectText(ctx, text string) Verdict
    InspectFile(ctx, meta UploadMeta) Verdict  // 本期内置实现为空(allow)，留接口
}
```

- 注入点：文本分享入口 + 三个上传完成点。内置 v1 仅文本敏感词：词表
  `moderation.blocked_words`，`moderation.block_action=reject(默认)/pending`。
- reject → `30013 ContentRejected`；pending → 建分享 `status=pending_review`，取件路径返回
  待审提示，进管理端队列页（`/admin/moderation`，前端 P2 交付）。
- webhook：复用 `notify.webhook` 基建，新增 `share.flagged` 事件（含 code/原因/IP）。

### 3.6 留痕对账与 metrics（core）

- 孤儿对账：挂现有清理 ticker（独立 24h 周期）。local：物理前缀 list vs DB `FilePath` 差集删除；
  s3/webdav/多云：只记录日志不删除（误删代价不对称）。已完成分片目录纳入同批。
- 日志保留：`admin.log_retention_days`（默认 90，0=永久），同 ticker 清理 transfer_log /
  admin_operation_log。
- metrics（Prometheus，内网端口已有）：`fcb_upload_bytes_total`、`fcb_share_created_total`、
  `fcb_upload_rejected_total{reason}`（type/size/quota/ratelimit/disabled/blocked/moderation）、
  `fcb_moderation_hits_total`。

### 3.7 错误码与发布（contracts）

新增：`10012 UploadDisabled`、`10014 AnonymousQuotaExceeded`、`20012 ShareBlocked`、
`30013 ContentRejected`。发布顺序：contracts tag → core → server/frontend，遵守依赖方向。

## 4. 分期

| 波次 | 内容 | 仓 |
|---|---|---|
| P0 止血 | 白名单 bug、enforce 开关、chunk 复查、magic 开关、cap/max_upload_size 接线、死配置标废弃 | contracts + core |
| P1 管控核心 | 状态机+禁用/恢复、列表强过滤+批量+IP 视图、匿名日配额、chunk 归属、前端 Files/Config | contracts + core + frontend |
| P2 审核与对账 | 敏感词+钩子+webhook、pending 队列页、孤儿对账、日志保留、metrics | core + frontend |

## 5. 风险与兼容

- 老库升级：仅 AutoMigrate 加列（status 默认 normal、upload_chunks 归属列可空），零迁移脚本。
- 白名单语义修复属行为变更：此前配了白名单的用户（实际上全放行）升级后开始真拦截——发版说明
  中显式提示。
- 匿名日配额默认关闭（0=不限），开启才生效，避免升级即拒。
- 敏感词默认词表为空（功能默认不启用），避免误伤。
