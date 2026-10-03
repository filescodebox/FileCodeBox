# API Token 波次 2（配置面 + 契约 + 文档 + 前端管理页）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补齐波次 1 之后的体验闭环：`security.api_token.enabled` 总开关、openapi/Swagger 契约、`docs/API-TOKENS.md` 使用指南、前端 `/user/tokens` 管理页。

**Architecture:** 开关走既有 viper 三件套（SetDefault + envBindings + struct），中间件入口 fail-closed 拦截；openapi.json 为手维护快照（补 securitySchemes + 3 端点）；前端沿用 Notifications.vue 的 i18n + el-table + `request<ApiResponse<T>>` 惯例。

**Tech Stack:** Go 1.26.5 / viper / Vue3 + TS + Element Plus + Pinia / openapi-typescript

**Spec:** `docs/design/2026-10-03-api-token-design.md` §4.5/§4.6 + 决策定案③（前端页并入本波次）

## Global Constraints

- core 仓 `transport/http/handler/share_user.go` 仍属并行会话（勿碰）；提交一律 `git commit -- <精确路径>`。
- 生成物：`src/types/api.gen.ts` 只能经 `npm run gen:api` 再生成。
- 开关语义（设计定案）：`enabled=false` 时**携带 Key 的请求一律 401**（fail-closed，文案区分于 Invalid API Key）。
- i18n 全量双语（zh-CN + en-US），key 前缀 `user.tokens.*` + `user.nav_tokens`。

---

### Task 1: core 总开关（TDD）

**Files:**
- Modify: `core/conf/config.go`（SecurityConfig + APITokenConfig）
- Modify: `core/bootstrap/bootstrap.go`（SetDefault + envBindings 两处）
- Modify: `core/pkg/middleware/apikey.go`（validateAPIKey 入口 gate + respondAPIKeyError 分支）
- Test: `core/pkg/middleware/apikey_test.go` 追加

- [ ] Step 1 写失败测试 `TestOptionalAPIKey_DisabledSwitch_401`：`conf.SetGlobalConfig(&conf.AppConfiguration{Security: conf.SecurityConfig{APIToken: conf.APITokenConfig{Enabled: false}}})`（Cleanup 恢复 nil）→ 携带有效 Key 请求应 401 且 body 含 "disabled"。
- [ ] Step 2 实现：`APITokenConfig{Enabled bool}` 挂进 SecurityConfig；`v.SetDefault("security.api_token.enabled", true)`；envBindings 加 `"security.api_token.enabled": {"FCB_API_TOKEN_ENABLED"}`；`validateAPIKey` 开头（lockout 之前）`if !apiTokenEnabled() { return ctx, errAPITokenDisabled }`；`respondAPIKeyError` 用 `errors.Is` 分支输出 401 `"API token authentication is disabled"`。`apiTokenEnabled()` 无全局配置时默认 true。
- [ ] Step 3 `go test ./pkg/middleware/ && go build ./... && go vet ./...` 全绿。
- [ ] Step 4 提交 core：`feat(middleware): API Key 认证总开关 security.api_token.enabled`。

### Task 2: 配置模板与 env 文档

**Files:** Modify `server/configs/config.example.yaml`、`server/configs/config.prod.yaml`（security 节加 `api_token.enabled: true` 带注释）；Modify hub `docs/ENVIRONMENT_VARIABLES.md` 安全节加一行 `FCB_API_TOKEN_ENABLED`。

- [ ] Step 1 三处编辑（example/prod/ENV 文档）。
- [ ] Step 2 提交：server 仓 yaml 一个 commit；hub ENV 文档随 Task 5 一起。

### Task 3: openapi.json + gen:api

**Files:** Modify `frontend/openapi.json`；再生成 `frontend/src/types/api.gen.ts`。

- [ ] Step 1 `components.securitySchemes` 加 `bearerAuth`（http bearer，描述注明兼容 API Key 值）与 `ApiKeyAuth`（apiKey header X-API-Key）；info.description 补认证说明段。
- [ ] Step 2 增加三个 path：`GET /user/api-keys`（列表，含已吊销）、`POST /user/api-keys`（body: name/expires_at/expires_in_days，响应 data.key 明文仅此一次）、`DELETE /user/api-keys/{id}`；标 `security: [{bearerAuth: []}]`。
- [ ] Step 3 `npm run gen:api` → diff 仅增量；`npm run typecheck` 过。
- [ ] Step 4 提交 frontend：`feat(openapi): 用户 API Key 管理端点与 securitySchemes`。

### Task 4: 前端 /user/tokens 页

**Files:**
- Modify `frontend/src/api/user.ts`（ApiKeyInfo 类型 + list/create/revoke）
- Create `frontend/src/views/user/Tokens.vue`（仿 Notifications.vue：page-header + el-table + 创建对话框 + 明文一次性展示 + 吊销确认）
- Modify `frontend/src/router/index.ts`（/user children 加 tokens）
- Modify `frontend/src/layouts/AppLayout.vue`（桌面 + 移动抽屉两处菜单，Key 图标）
- Modify `frontend/src/i18n/locales/zh-CN.ts`、`en-US.ts`（user.nav_tokens + user.tokens.* 全量 key）

- [ ] Step 1 api/user.ts 三方法（GET/POST /user/api-keys、DELETE /user/api-keys/:id）。
- [ ] Step 2 Tokens.vue：列表列=名称/前缀/最后使用/过期时间/状态(active|revoked|expired tag)/创建时间/操作；创建对话框=名称(默认"API Key")+有效期选择(永久/30/90/365 天，默认永久，附"建议设置过期"提示)；创建成功弹一次性明文（el-alert error 提示仅显示一次 + 复制按钮 + "我已保存"关闭后刷新列表）；吊销走 ElMessageBox.confirm。
- [ ] Step 3 路由 + 两处菜单 + i18n 双语。
- [ ] Step 4 `npm run typecheck && npm run build` 全绿。
- [ ] Step 5 提交 frontend：`feat(user): API Token 管理页（/user/tokens）`。

### Task 5: 使用指南 + 收尾

- [ ] Step 1 hub `docs/API-TOKENS.md`：获取 Key 两种姿势（页面/curl+JWT）、认证头规范（Bearer fcb_sk_ 首选/ApiKey/X-API-Key，禁 query）、direct+chunk+presign curl 示例、管理自己分享示例、防护机制说明（lockout/限流/fail-closed/吊销即时生效）、`FCB_API_TOKEN_ENABLED`、**HTTP 明文部署警告**（215 类部署）。
- [ ] Step 2 hub 提交（ENV 文档 + API-TOKENS.md + 计划勾选）；更新记忆与 MEMORY.md。
