# 上传资源治理实施计划（P0/P1/P2）

> **For agentic workers:** 本计划由 ZCode 会话内联执行（superpowers:executing-plans 模式），
> 步骤用 checkbox 跟踪。Spec: `docs/design/2026-10-03-upload-governance-design.md`（本计划从
> spec 论证，两者需一起读）。

**Goal:** 为 FileCodeBox 建立"上传准入闸门 → 分享状态机 → 管理端治理工具 → 审核钩子 → 留痕对账"的完整管控体系。

**Architecture:** 校验逻辑收口到 `pkg/utils` + 新 `pkg/gate`（上传闸门）+ 新 `app/moderation`（审核钩子），服务端 enforce 假开关；`file_codes` 增加 status 列构成状态机；管理端新端点延续 bootstrap 手写增强路由先例（挂 AdminMiddleware 组）；配额/计数复用 rate_limit 的 Redis 基建并带内存退化。

**Tech Stack:** Go 1.26.x / Hertz v0.9.6 / GORM(AutoMigrate) / go-redis v9 / Prometheus client_golang / Vue3+Element Plus

**Global Constraints**
- 依赖方向 contracts ← core ← server/frontend，禁止 replace 钉版本；新错误码先改 contracts 并发版（tag）后 core 升 go.mod。
- 生成物勿手改：contracts `gen/`、core `gen/`（本计划只改 core gen/ 中**已有人工维护痕迹的 handler 文件**，与现状一致）、frontend `src/types/api.gen.ts`。
- 老库兼容：仅 AutoMigrate 加列，新列有默认值或可空；`status` 默认 `normal`。
- 新增配置全部带 env 绑定（`FCB_*`，加进 `bootstrap/bootstrap.go` `envBindings`）+ 三份配置模板同步（`server/configs/config{,.example,.prod}.yaml`）。
- 测试命令：core 内 `go test ./...`；hub 根 `make test`（三 Go 模块 + frontend typecheck）。
- 提交纪律：每任务一个 commit（core/contracts/frontend 各自仓内）；受 AGENTS.md 约束 push 前需用户确认。

---

## P0 止血（contracts + core）

### Task P0-1: contracts 新错误码

**Files:** Modify `contracts/errcode/errcode.go`

新增常量 + messages（一次加齐全部四波次所需，避免多次发版）：

```go
// 1xxxx 追加
CodeUploadDisabled    = 10012 // 上传已关闭（upload.open_upload=false 或 require_login 未满足）
CodeIPBlocked         = 10013 // 预留：IP 已被封禁
CodeAnonymousQuota    = 10014 // 匿名上传日配额已用尽
// 2xxxx 追加
CodeShareBlocked      = 20012 // 分享已被管理员禁用
CodeSharePendingReview= 20013 // 分享待审核，暂不可取
// 3xxxx 追加
CodeContentRejected   = 30013 // 内容未通过审核（敏感词等）
```

验证：`cd contracts && go build ./... && go test ./...`。发布顺序注意：core 消费这些码前，contracts 需先打 tag（见"发布步骤"节）。

### Task P0-2: filecheck 白名单语义修复 + 黑名单可配置 + 魔数开关（TDD）

**Files:**
- Modify `core/pkg/utils/filecheck.go`、`core/pkg/utils/magic.go`
- Modify `core/conf/config.go`（UploadConfig 增 `BlockedExtensions []string mapstructure:"blocked_extensions"`）
- Test: `core/pkg/utils/filecheck_test.go`（扩展既有表驱动测试）

**语义定版（修复目标）：**
- `IsAllowedExtension(filename) bool`：白名单空 → `!IsBlockedExtension(...)`；白名单非空 → 命中且不在黑名单才 true，**未命中一律 false**（含无扩展名）。
- `CheckUploadContent(filename, head) error`：① `!IsAllowedExtension` → `ErrFileTypeNotAllowed`；② `GetEnableMagicCheck()` 且 head 非空且 ext ∉ magicCheckSkipExts → 魔数检查；黑名单检查并入 ①。**删除白名单命中短路 return**。
- 新 `GetBlockedExtensions() []string`：config 非空用 config，否则 `DefaultBlockedExtensions()`；`magic.go`/`chunk service`/`presign`/anonymous handler 里的 `DefaultBlockedExtensions()` 调用点全部换掉。
- 新 `GetEnableMagicCheck() bool`：cfg==nil 时 true（保守），否则 `cfg.Upload.EnableMagicCheck`（viper SetDefault 已兜底 true）。

测试先行（表驱动，红→绿）：
```go
cases := []struct{ name, file string; allowed, blocked []string; head []byte; want error }{
  {"白名单命中且干净", "a.jpg", []string{".jpg"}, nil, jpgHead, nil},
  {"白名单未命中拒绝", "a.exe", []string{".jpg"}, nil, nil, ErrFileTypeNotAllowed},
  {"无扩展名+白名单 拒绝", "README", []string{".jpg"}, nil, nil, ErrFileTypeNotAllowed},
  {"白名单空走黑名单", "a.exe", nil, nil, nil, ErrFileTypeNotAllowed},
  {"黑名单可配置覆盖默认", "a.tgz", nil, []string{".tgz"}, nil, ErrFileTypeNotAllowed},
  {"白名单命中仍查黑名单", "a.exe", []string{".exe"}, nil, nil, ErrFileTypeNotAllowed},
  {"魔数命中拒绝(开关开)", "a.jpg", nil, nil, []byte("MZ\x00\x00"), &MagicMismatchError{}},
  {"魔数开关关则放行", "a.jpg", nil, nil, []byte("MZ\x00\x00"), nil}, // conf 关
  {"白名单空+黑名单空+魔数干净", "a.jpg", nil, nil, jpgHead, nil},
}
```
验证：`go test ./pkg/utils/ -run TestCheckUploadContent -v`（先失败后通过）。

### Task P0-3: 过期钳制 max_save_seconds_cap（TDD）

**Files:** Modify `core/pkg/utils/expire.go`；Test `core/pkg/utils/expire_test.go`

`CalculateExpireTime` 内：算出 duration 后若 `GetMaxSaveSecondsCap() > 0` 且 `duration > cap` → 钳到 cap。新 helper `GetMaxSaveSecondsCap() int64`（读 `upload.max_save_seconds_cap`）。测试：cap=3600 时 `expireValue=2,style=hour` → `ExpiredAt-now ∈ [3599,3601]s`；count 样式不受影响；cap=0 不钳。

### Task P0-4: 上传闸门 pkg/gate + enforce 假开关

**Files:**
- Create `core/pkg/gate/gate.go`（+ `gate_test.go`）
- Modify 调用点：`gen/handler/share/share_service.go`（ShareText/ShareFile/GetShare/DownloadFile）、`gen/handler/chunk/chunk_service.go`（ChunkUploadInit）、`gen/handler/presign/*`（Init）、`gen/handler/share_anonymous/share_anonymous_service.go`（create/retrieve/download）

**接口定版（P1 在此扩展日配额）：**
```go
package gate
// ErrUploadDisabled / ErrLoginRequired —— 实现 ErrCode() int（10012 / 10002），handler 侧 resp.NewErrorByCode 透传
func CheckUploadAllowed(userID *uint) error          // open_upload=false 且 userID==nil → ErrUploadDisabled
func CheckUploadLogin(userID *uint) error            // upload.require_login 且 userID==nil → ErrLoginRequired
func CheckDownloadLogin(userID *uint) error          // download.require_login 且 userID==nil → ErrLoginRequired
```
接线位置（handler 内取到 userID 之后立即调用）：ShareText、ShareFile、ChunkUploadInit、presign Init、anonymous create → 先 `CheckUploadAllowed` 后 `CheckUploadLogin`；GetShare、DownloadFile、anonymous retrieve/download → `CheckDownloadLogin`。
同时修 `share_service.go:35` 硬编码：`ShareFile` 大小检查改 `utils.GetMaxUploadSize()`（为 0 视为不限）。

### Task P0-5: chunk Complete 实际大小复查

**Files:** Modify `gen/handler/chunk/chunk_service.go`（ChunkUploadComplete 合并成功后、建分享前）

合并完成后 `storageSvc` stat 实际文件大小：`actual > GetMaxFileSize()>0` → 删物理文件 + 返 `CodeTooLarge`；`info.FileSize > 0 && actual != info.FileSize` → 删文件 + 返 `CodeChunkInvalid`（"分片合并后大小与申报不符"）。秒传分支不受影响。

### Task P0-6: users.max_upload_size 接线

**Files:** Modify `core/app/user/service.go`（新 `GetUploadSizeCap(ctx, userID) int64`：读 user.MaxUploadSize，0=默认）、`core/app/share/service.go`（`UserServiceInterface` 增该方法；`CreateShare` 在 `checkQuota` 前对登录用户做 `utils.CheckUploadSize(req.Size, cap)`）；handler `ShareFile`/`ChunkUploadComplete` 已传 userID 无需改。
测试：`core/app/share/service_test.go`（若已有测试基建，复用；否则在 user service 侧测 GetUploadSizeCap 分支）。

### Task P0-7: 死配置处置 + P0 验证

- `server/configs/config*.yaml`：`download.max_concurrent_downloads`、`transfer.max_count`、`upload.max_save_seconds`（旧名）注释标 `# deprecated(未实现)`；`max_save_seconds_cap`、`blocked_extensions`、`anonymous_daily_*`（P1 键位可先占位注释）加示例。
- `docs/ENVIRONMENT_VARIABLES.md` 增 `FCB_UPLOAD_BLOCKED_EXTENSIONS`。
- `cd FilesCodeBox && make test && make vet`（contracts 变更后 core go.mod 需指向可解析版本：开发期 go.work 直接用本地模块即可；发布步骤见文末）。

## P1 管控核心（contracts + core + frontend）

### Task P1-1: status 状态机

**Files:**
- Modify `core/repo/db/model/filecode.go`：`Status string gorm:"size:20;default:'normal';index:idx_file_codes_status_expired,priority:1"` + `ExpiredAt` 加同索引 priority:2；常量 `StatusNormal/StatusBlocked/StatusPendingReview`；`FileCodeQuery` 重构为真过滤结构（Code/UserID/UploadType/OwnerIP/Status/MinSize/MaxSize/StartAfter/EndBefore/Expired/Keyword/Page/PageSize）。
- Modify `core/repo/db/dao/filecode.go`：`ListWithFilter(ctx, q FileCodeQuery) ([]*model.FileCode, int64, error)`（动态 Where，参考 `GetUserSharesWithFilter` 风格）；`UpdateStatusByIDs(ctx, ids []uint, status string) (int, error)`（白名单校验 status 取值）。
- Modify `core/app/share/service.go`：`SetShareStatus(ctx, ids, status)`；`GetFileByCode`/`GetFileWithUsage` 命中 blocked/pending → typed error `ShareBlockedError{Status string}`（ErrCode: 20012/20013）。
- Handler 接线：`GetShare`/`DownloadFile`/anonymous `Retrieve`/`Download`（`gen/handler/*`）对 typed error 返对应业务码。
- 测试：sqlite 内存建表 → blocked 取件拒绝、normal 正常、状态过滤查询正确。

### Task P1-2: 管理端禁用/恢复 + 列表强过滤

**Files:**
- Modify `core/transport/http/handler/admin_manage.go`（延续手写增强先例）：
  - `PUT /admin/files/:id/status` {status: normal|blocked} → service + `logAdminOperation("file_block"/"file_unblock")`
  - `POST /admin/files/batch-status` {ids, status} → 同上
  - `GET /admin/files`（IDL handler `gen/handler/admin` AdminListFiles）增 query：`upload_type/user_id/owner_ip/status/min_size/max_size/created_after/created_before/expired`，透传 `admin.Service.GetFiles` → DAO `ListWithFilter`；列表响应补 `owner_ip/status/upload_type/user_id` 字段。
- Modify `core/app/admin/service.go`：`GetFiles` 签名扩展（新 filter 结构，保持旧 keyword 兼容）。
- bootstrap `adminAPI` 组注册新路由。
- 测试：DAO 层过滤组合（owner_ip+status）；service 层禁用→取件拒绝。

### Task P1-3: 匿名 per-IP 日配额（并入 gate）

**Files:**
- Create `core/pkg/gate/quota.go`：`DailyQuota{ rdb *redis.Client, mem memStore }`；`Allow(ctx, ip string, addBytes int64) (bool, string)`——key `fcb:quota:<ip>:<yyyymmdd>`，Redis `INCR`+`EXPIRE 25h`（无 Redis 用内存 map+日期轮转+锁）；count 与 bytes 双计数，任一超限拒绝。
- conf：`upload.anonymous_daily_count int` / `upload.anonymous_daily_bytes int64`（0=不限，默认 0）+ env `FCB_UPLOAD_ANON_DAILY_COUNT/_BYTES`。
- gate 增 `CheckAnonymousQuota(ctx, ip, size)`：仅 userID==nil 且配额>0 时计数检查；接线四个上传入口（ShareFile/ChunkUploadInit/presign Init/anonymous create，直传文本不计数）；bootstrap 装配 Redis client 注入（rate_limit 已有获取方式，复用）。拒绝返 10014。
- 测试：内存模式 count 超限/bytes 超限/次日重置（注入时钟或直接构造日期 key）。

### Task P1-4: upload_chunks 归属字段

**Files:** Modify `core/repo/db/model/chunk.go`（`OwnerIP string size:45` / `UserID *uint index`）、`gen/handler/chunk/chunk_service.go`（Init 时 `c.Get("user_id")`+ClientIP 写入控制记录；Complete 复查时校验归属一致——同 IP 或同 user 才允许 Complete，不一致返 403）。
迁移零成本（AutoMigrate 加可空列）。测试：model 层字段迁移冒烟（sqlite AutoMigrate 后查询列存在）。

### Task P1-5: 前端管理端（Files/Config/Users）

**Files:**
- Modify `frontend/src/api/admin.ts`：`setFileStatus(ids, status)`、`listFiles` 增 filter 参数、`FileItem` 类型补 `owner_ip/status/upload_type/user_id`。
- Modify `frontend/src/views/admin/Files.vue`：筛选栏（类型/用户/IP/状态/大小区间/时间区间/仅过期）、状态 tag 列、行操作"禁用/恢复"、批量工具栏增"批量禁用/恢复"。
- Modify `frontend/src/views/admin/Config.vue`：新"安全与限流" tab（读写 `/admin/ratelimit/config`：四档 QPS/burst/block_seconds/use_redis + 状态查看 `/admin/ratelimit/status`）。
- Modify `frontend/src/views/admin/Users.vue:~308`：配额进度条改读该用户 `max_storage_quota`（>0）否则回退默认 1GB 文案。
- 验证：`npm run typecheck` + `npm run build`。

## P2 审核与对账（core + frontend）

### Task P2-1: moderation 包 + 文本敏感词 + 队列

**Files:**
- Create `core/app/moderation/moderation.go`（+ 测试）：
```go
type Verdict int // Allow / Reject / Pending
type UploadMeta struct{ Code, FileName, ContentType, OwnerIP string; Size int64; UserID *uint }
type Moderator interface {
    InspectText(ctx context.Context, text string) Verdict
    InspectFile(ctx context.Context, meta UploadMeta) Verdict // 内置实现恒 Allow
}
type WordListModerator struct{ words []string; action string } // conf 注入
```
- conf：`moderation.enabled bool(默认 false)`、`moderation.blocked_words []string`、`moderation.block_action string(reject|pending)` + env（`FCB_MODERATION_ENABLED/_BLOCKED_WORDS(逗号分隔)/_BLOCK_ACTION`）。
- 接线：bootstrap 构造并 `share.Service.SetModerator(...)`（模式同 SetQuotaChecker）；`ShareTextWithAuth` 在写库前 InspectText：reject → `&ContentRejectedError{}`（30013）；pending → 建库后 `SetShareStatus(...,pending_review)`。文件侧钩子位置留空实现（handler complete 后调用，恒 Allow，不落库不耗时）。
- webhook：`pkg/transfer.Record` 模式旁新增 `pkg/webhook.Emit(event, payload)`（读 `notify.webhook_url`，异步 POST JSON，失败仅日志）；moderation 命中时发 `share.flagged`。
- 管理队列：`GET /admin/moderation`（=ListWithFilter status=pending_review 包装）+ 复用 `PUT /admin/files/:id/status` 处置；bootstrap 注册。
- 测试：WordList 命中/未命中/action 两种策略；pending 后取件返 20013。

### Task P2-2: 孤儿对账 + 日志保留

**Files:**
- Create `core/app/admin/janitor.go`：`ReconcileOrphans(ctx)`——local：`storage.List`（按 `uploads/` 前缀，逐日目录）vs DB `FilePath` 全集差集 → 删除 + 日志；s3/webdav/多云 → 仅统计日志不删；`CleanupLogs(ctx, retentionDays)`——transfer_log / admin_operation_log `created_at < now-retention` 批量删。
- conf：`admin.log_retention_days int(默认 90，0=永久)` + env。
- bootstrap：现有清理 ticker 处再起 24h ticker 调用二者。
- 测试：tmpdir 本地存储 + sqlite：造孤儿文件 → Reconcile 删除；造过期日志 → 清理。

### Task P2-3: 业务 metrics

**Files:** Create `core/pkg/metrics/business.go`；Modify gate/moderation/share 接线点。
```go
fcb_upload_bytes_total(counter, by channel)
fcb_share_created_total(counter, by upload_type)
fcb_upload_rejected_total(counter, by reason: type|size|quota|ratelimit|disabled|blocked|moderation|anon_quota)
fcb_moderation_hits_total(counter, by action)
```
接线：gate 各拒绝分支 + filecheck 错误处 + share CreateShare 成功处 + moderation 命中处。cfg==nil 或未启用时零开销（Prometheus counter 天然廉价，无需开关）。
验证：单测断言 counter 增量；smoke 时 `curl 127.0.0.1:9090/metrics`（如启用）。

### Task P2-4: 前端审核队列页

Create `frontend/src/views/admin/Moderation.vue`（pending_review 列表 + 通过/禁用按钮）、`router/index.ts` 增路由、`admin.ts` 增 `listModeration()`。验证 typecheck+build。

## 发布步骤（代码外，需用户操作）

1. contracts：commit → tag（建议 v0.2.1，语义为新增错误码非破坏性）→ push。
2. core：`go get github.com/filescodebox/contracts@v0.2.1 && go mod tidy` → commit。
3. frontend / hub 配置模板各自 commit。
4. `make test && make smoke` 通过后按各仓惯例 push + 打 core/frontend tag。

## Self-Review 结论

- spec §3.1–3.7 ↔ 任务映射：闸门=P0-2/4/5 + P1-3/4；状态机=P1-1；治理工具=P1-2/5；审核=P2-1/4；对账 metrics=P2-2/3；错误码=P0-1。无缺口。
- 类型一致性：`gate.CheckUploadAllowed(userID *uint) error` 全文一致；`ListWithFilter` 消费 `model.FileCodeQuery`；errcode 名与 spec §3.7 一致（`CodeAnonymousQuota` 对应 spec 的 AnonymousQuotaExceeded，取短名）。
- 无 TBD 占位。
