# API Token 波次 1（core 接线 + 防护收紧）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把孤儿 API Key 中间件接线到上传三通道与 /api/v1 管理组，并完成设计文档定义的 5 项安全收紧（Status 校验、禁 query 传 Key、Touch 节流、fail-closed、lockout 防爆破）与限流补位。

**Architecture:** 收紧后的 API Key 认证核心统一实现在 `pkg/middleware/apikey.go`（gen 路由只能 import pkg；避免 pkg↔transport 双方言）。三个新中间件入口：`OptionalIdentity() []app.HandlerFunc`（JWT 可选 → Key 可选，替换 gen 路由的 `OptionalAuthMiddleware()`）、`OptionalAPIKey()`、`UserOrAPIKey()`（替换 bootstrap `/api/v1` 组的 transport `UserAuth()`）。上下文双写方言与既有 JWT 中间件完全一致（`c.Set("user_id", uint)` + `withIdentity` ctx 注入），handler 零改动。

**Tech Stack:** Go 1.26.5 / Hertz v0.9.6 / GORM + glebarez/sqlite / testify / go-redis v9

**Spec:** `docs/design/2026-10-03-api-token-design.md`（定案版，commit 6dddbbe）

## Global Constraints

- 所有工作在 `FilesCodeBox/core/` 仓（main 分支）；设计文档修订在 hub 仓。
- core 仓有并行会话：`transport/http/handler/share_user.go` 有未提交改动，**本计划不碰该文件**；提交一律用 `git commit -- <精确路径>`。
- 提交信息风格沿用仓库惯例：`feat(scope): 中文描述`（参考 `e3f16f2`）。
- 测试用 sqlite `:memory:` 必须 `SetMaxOpenConns(1)`（多连接各见独立库，异步必现 flake）。
- 生成物勿手改：`gen/` 下只允许改人工维护的 `gen/router/*/middleware.go`。
- 路由路径零新增零修改——`routes_guard_test.go` 应保持绿色，跑通即可，不改快照。
- 401 响应统一文案 `"Invalid API Key"`，不区分过期/吊销/封禁（防枚举）。
- 拒绝 query 传 Key：不留配置开关，直接删除该提取分支。

---

### Task 1: `pkg/middleware/apikey.go` 认证核心（TDD）

**Files:**
- Create: `pkg/middleware/apikey.go`
- Test: `pkg/middleware/apikey_test.go`

**Interfaces:**
- Consumes: `GetDefaultLockout()/CheckLocked/RecordFailure/Reset/LockedError/FormatLockKey`（同包 lockout.go）、`withIdentity/ClientIP`（同包）、`dao.NewUserAPIKeyRepository().GetActiveByHash/TouchLastUsed`、`dao.NewUserRepository().GetByID`、`errcode.CodeTooManyAttempts`(=10011)
- Produces（后续 Task 挂载用）:
  - `OptionalIdentity() []app.HandlerFunc` — JWT 可选 + Key 可选
  - `OptionalAPIKey() app.HandlerFunc` — fail-closed 可选 Key
  - `UserOrAPIKey() app.HandlerFunc` — Key 或 JWT 必选其一

- [x] **Step 1: 写失败测试 `pkg/middleware/apikey_test.go`**

```go
package middleware

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/cloudwego/hertz/pkg/common/ut"
	"github.com/filescodebox/core/pkg/auth"
	"github.com/filescodebox/core/repo/db"
	"github.com/filescodebox/core/repo/db/dao"
	"github.com/filescodebox/core/repo/db/model"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

// =====================================================================
// API Key 中间件单测。
// sqlite :memory: 多连接各见独立库，钉死单连接（教训见 upload-governance）。
// =====================================================================

func newAPIKeyTestEnv(t *testing.T) {
	t.Helper()
	g, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, g.AutoMigrate(&model.User{}, &model.UserAPIKey{}))
	sqlDB, err := g.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	db.SetDatabaseInstance(g)
	t.Cleanup(func() { db.SetDatabaseInstance(nil) })
	// 重置全局锁定器为纯内存实例 + 清空触碰节流表，测试间隔离（同包直取）
	InitDefaultLockout(nil)
	t.Cleanup(func() { InitDefaultLockout(nil) })
	touchThrottle = sync.Map{}
}

func newFixtureUser(t *testing.T, status string) *model.User {
	t.Helper()
	u := &model.User{
		Username:     fmt.Sprintf("u_%d", time.Now().UnixNano()),
		Email:        fmt.Sprintf("u_%d@test.local", time.Now().UnixNano()),
		PasswordHash: "x",
		Status:       status,
		Role:         "user",
	}
	require.NoError(t, dao.NewUserRepository().Create(context.Background(), u))
	return u
}

func newFixtureKey(t *testing.T, userID uint, mutate func(*model.UserAPIKey)) (string, *model.UserAPIKey) {
	t.Helper()
	plain := apiKeyPlainPrefix + fmt.Sprintf("%032x", time.Now().UnixNano())
	rec := &model.UserAPIKey{UserID: userID, Name: "test", Prefix: plain[:12], KeyHash: sha256Hex(plain)}
	if mutate != nil {
		mutate(rec)
	}
	require.NoError(t, dao.NewUserAPIKeyRepository().Create(context.Background(), rec))
	return plain, rec
}

// performProbe 起 hertz 测试引擎挂中间件链，返回 (状态码, 响应体, 注入的身份, handler 收到的 ctx)。
func performProbe(t *testing.T, mws []app.HandlerFunc, url string, headers ...ut.Header) (int, string, map[string]interface{}, context.Context) {
	t.Helper()
	h := server.New(server.WithHostPorts("127.0.0.1:0"))
	var captured context.Context
	var identity map[string]interface{}
	handler := func(ctx context.Context, c *app.RequestContext) {
		captured = ctx
		identity = map[string]interface{}{}
		for _, k := range []string{"user_id", "username", "role", "api_key_id", "auth_type"} {
			if v, ok := c.Get(k); ok {
				identity[k] = v
			}
		}
		c.JSON(http.StatusOK, map[string]string{"ok": "1"})
	}
	args := append([]app.HandlerFunc{}, mws...)
	args = append(args, handler)
	h.GET("/probe", args...)
	w := ut.PerformRequest(h.Engine, "GET", url, nil, headers...)
	return w.Code, w.Body.String(), identity, captured
}

func hdr(k, v string) ut.Header { return ut.Header{Key: k, Value: v} }

// --- 提取规则 ---

func TestOptionalAPIKey_NoKey_Anonymous(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "active")
	newFixtureKey(t, u.ID, nil)
	code, body, identity, _ := performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe")
	assert.Equal(t, 200, code, body)
	assert.Empty(t, identity, "未携带 Key 必须匿名放行，不注入身份")
}

func TestOptionalAPIKey_QueryParamIgnored(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "active")
	plain, _ := newFixtureKey(t, u.ID, nil)
	// query 传 Key 必须被无视（防日志/Referer 泄露），按匿名处理
	code, body, identity, _ := performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe?api_key="+plain)
	assert.Equal(t, 200, code, body)
	assert.Empty(t, identity)
}

func TestOptionalAPIKey_ValidKey_InyectsIdentity(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "active")
	plain, rec := newFixtureKey(t, u.ID, nil)

	code, body, identity, ctx := performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe",
		hdr("X-API-Key", plain))
	assert.Equal(t, 200, code, body)
	assert.Equal(t, u.ID, identity["user_id"])
	assert.Equal(t, u.Username, identity["username"])
	assert.Equal(t, "user", identity["role"])
	assert.Equal(t, rec.ID, identity["api_key_id"])
	assert.Equal(t, "api_key", identity["auth_type"])
	// ctx 方言（service 层审计提取）
	gotID, ok := UserIDFromContext(ctx)
	assert.True(t, ok, "API Key 认证必须注入 ctx 身份供 service 层审计")
	assert.Equal(t, u.ID, gotID)
}

func TestOptionalAPIKey_BearerFcbSkPrefix(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "active")
	plain, _ := newFixtureKey(t, u.ID, nil)
	code, body, identity, _ := performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe",
		hdr("Authorization", "Bearer "+plain))
	assert.Equal(t, 200, code, body)
	assert.Equal(t, u.ID, identity["user_id"])
}

func TestOptionalAPIKey_ApiKeyScheme(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "active")
	plain, _ := newFixtureKey(t, u.ID, nil)
	code, body, identity, _ := performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe",
		hdr("Authorization", "ApiKey "+plain))
	assert.Equal(t, 200, code, body)
	assert.Equal(t, u.ID, identity["user_id"])
}

// --- fail-closed：携带即校验 ---

func TestOptionalAPIKey_InvalidKey_401(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "active")
	newFixtureKey(t, u.ID, nil)
	code, body, identity, _ := performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe",
		hdr("X-API-Key", apiKeyPlainPrefix+"wrongwrong"))
	assert.Equal(t, 401, code)
	assert.Empty(t, identity, "无效 Key 不得放行到 handler")
	assert.Contains(t, body, "Invalid API Key")
}

func TestOptionalAPIKey_ExpiredKey_401(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "active")
	plain, _ := newFixtureKey(t, u.ID, func(k *model.UserAPIKey) {
		past := time.Now().Add(-time.Hour)
		k.ExpiresAt = &past
	})
	code, _, _, _ := performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe", hdr("X-API-Key", plain))
	assert.Equal(t, 401, code)
}

func TestOptionalAPIKey_RevokedKey_401(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "active")
	plain, _ := newFixtureKey(t, u.ID, func(k *model.UserAPIKey) { k.Revoked = true })
	code, _, _, _ := performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe", hdr("X-API-Key", plain))
	assert.Equal(t, 401, code)
}

func TestOptionalAPIKey_BannedUser_401(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "banned")
	plain, _ := newFixtureKey(t, u.ID, nil)
	code, _, _, _ := performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe", hdr("X-API-Key", plain))
	assert.Equal(t, 401, code, "封禁用户的 Key 必须失效")
}

// --- lockout 防爆破 ---

func TestOptionalAPIKey_LockoutAfterMaxFailures(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "active")
	plain, _ := newFixtureKey(t, u.ID, nil)
	bad := apiKeyPlainPrefix + "notarealkey000"
	// 默认 MaxAttempts=10：前 10 次 401，第 11 次起 429（连有效 Key 也拦）
	for i := 0; i < 10; i++ {
		code, _, _, _ := performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe", hdr("X-API-Key", bad))
		assert.Equal(t, 401, code, "第 %d 次失败应仍为 401", i+1)
	}
	code, body, _, _ := performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe", hdr("X-API-Key", bad))
	assert.Equal(t, 429, code, body)
	assert.Contains(t, body, "锁定")
	// 锁定期间有效 Key 也被拦（CheckLocked 前置）
	code, _, _, _ = performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe", hdr("X-API-Key", plain))
	assert.Equal(t, 429, code)
}

// --- TouchLastUsed 节流 ---

func TestShouldTouchLastUsed_Throttle(t *testing.T) {
	now := time.Now()
	assert.True(t, shouldTouchLastUsed(1, now), "首次必须写")
	assert.False(t, shouldTouchLastUsed(1, now.Add(30*time.Second)), "60s 内不重复写")
	assert.True(t, shouldTouchLastUsed(1, now.Add(61*time.Second)), "超 60s 再写")
	assert.True(t, shouldTouchLastUsed(2, now), "不同 Key 互不影响")
}

func TestOptionalAPIKey_TouchLastUsedThrottled(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "active")
	plain, _ := newFixtureKey(t, u.ID, nil)
	repo := dao.NewUserAPIKeyRepository()
	ctx := context.Background()

	_, _, _, _ = performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe", hdr("X-API-Key", plain))
	after1, err := repo.GetByID(ctx, 1)
	require.NoError(t, err)
	require.NotNil(t, after1.LastUsedAt, "首次使用必须写 last_used_at")

	_, _, _, _ = performProbe(t, []app.HandlerFunc{OptionalAPIKey()}, "/probe", hdr("X-API-Key", plain))
	after2, err := repo.GetByID(ctx, 1)
	require.NoError(t, err)
	assert.Equal(t, after1.LastUsedAt.Unix(), after2.LastUsedAt.Unix(), "60s 内第二次使用不得再写库")
}

// --- UserOrAPIKey ---

func TestUserOrAPIKey_ValidJWT(t *testing.T) {
	newAPIKeyTestEnv(t)
	auth.SetJWTSecret("test-secret-for-apikey")
	t.Cleanup(func() { auth.SetJWTSecret("") })
	u := newFixtureUser(t, "active")
	token, err := auth.GenerateToken(u.ID, u.Username, u.Role)
	require.NoError(t, err)
	code, body, identity, _ := performProbe(t, []app.HandlerFunc{UserOrAPIKey()}, "/probe",
		hdr("Authorization", "Bearer "+token))
	assert.Equal(t, 200, code, body)
	assert.Equal(t, u.ID, identity["user_id"])
}

func TestUserOrAPIKey_ValidKey(t *testing.T) {
	newAPIKeyTestEnv(t)
	u := newFixtureUser(t, "active")
	plain, _ := newFixtureKey(t, u.ID, nil)
	code, body, identity, _ := performProbe(t, []app.HandlerFunc{UserOrAPIKey()}, "/probe", hdr("X-API-Key", plain))
	assert.Equal(t, 200, code, body)
	assert.Equal(t, u.ID, identity["user_id"])
	assert.Equal(t, "api_key", identity["auth_type"])
}

func TestUserOrAPIKey_NoCredentials_401(t *testing.T) {
	newAPIKeyTestEnv(t)
	code, _, identity, _ := performProbe(t, []app.HandlerFunc{UserOrAPIKey()}, "/probe")
	assert.Equal(t, 401, code)
	assert.Empty(t, identity)
}

func TestUserOrAPIKey_InvalidJWT_401(t *testing.T) {
	newAPIKeyTestEnv(t)
	auth.SetJWTSecret("test-secret-for-apikey")
	t.Cleanup(func() { auth.SetJWTSecret("") })
	code, _, _, _ := performProbe(t, []app.HandlerFunc{UserOrAPIKey()}, "/probe",
		hdr("Authorization", "Bearer not.a.jwt"))
	assert.Equal(t, 401, code)
}

// --- OptionalIdentity（JWT 路为既有语义：无效 JWT 降级匿名） ---

func TestOptionalIdentity_MixedCredentials(t *testing.T) {
	newAPIKeyTestEnv(t)
	auth.SetJWTSecret("test-secret-for-apikey")
	t.Cleanup(func() { auth.SetJWTSecret("") })
	u := newFixtureUser(t, "active")
	plain, _ := newFixtureKey(t, u.ID, nil)
	badJWT, err := auth.GenerateToken(u.ID, u.Username, u.Role)
	require.NoError(t, err)

	// 有效 Key → 身份注入
	code, _, identity, _ := performProbe(t, OptionalIdentity(), "/probe", hdr("X-API-Key", plain))
	assert.Equal(t, 200, code)
	assert.Equal(t, u.ID, identity["user_id"])

	// 无效 JWT → 匿名放行（既有 OptionalAuth 语义，不 401）
	_ = badJWT
	code, _, identity, _ = performProbe(t, OptionalIdentity(), "/probe", hdr("Authorization", "Bearer junk.token.here"))
	assert.Equal(t, 200, code)
	assert.Empty(t, identity)

	// 无凭证 → 匿名
	code, _, identity, _ = performProbe(t, OptionalIdentity(), "/probe")
	assert.Equal(t, 200, code)
	assert.Empty(t, identity)
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `cd core && go test ./pkg/middleware/ -run 'APIKey|UserOrAPIKey|OptionalIdentity|TouchLastUsed|ShouldTouch' -v 2>&1 | tail -20`
Expected: 编译失败 `undefined: OptionalAPIKey`（及 UserOrAPIKey / OptionalIdentity / apiKeyPlainPrefix / sha256Hex / touchThrottle）

- [x] **Step 3: 实现 `pkg/middleware/apikey.go`**

```go
package middleware

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/filescodebox/contracts/errcode"
	"github.com/filescodebox/core/repo/db/dao"
)

// apiKeyPlainPrefix API Key 明文前缀（与 app/user 签发端一致）。
// 同时承担 Bearer 凭证与 JWT 的确定性区分：fcb_sk_ 开头必为 Key（JWT 恒为 eyJ 开头）。
const apiKeyPlainPrefix = "fcb_sk_"

// errInvalidAPIKey 统一拒绝原因（对外一律 401 "Invalid API Key"，不区分过期/吊销/封禁，防枚举）。
var errInvalidAPIKey = errors.New("invalid api key")

// extractAPIKey 从请求头提取 API Key。拒绝 query 传参（防访问日志/Referer/代理日志泄露）。
// 支持三种形式：
//  1. Authorization: Bearer fcb_sk_xxx（首选）
//  2. Authorization: ApiKey xxx
//  3. X-API-Key: xxx
//
// 返回 (key, true) 表示请求显式携带 Key（无论是否有效，调用方须 fail-closed）；
// 返回 ("", false) 表示未携带 Key（按匿名/JWT 语义处理）。
func extractAPIKey(c *app.RequestContext) (string, bool) {
	authHeader := strings.TrimSpace(string(c.GetHeader("Authorization")))
	if authHeader != "" {
		parts := strings.SplitN(authHeader, " ", 2)
		if len(parts) == 2 {
			token := strings.TrimSpace(parts[1])
			if token != "" && strings.EqualFold(parts[0], "ApiKey") {
				return token, true
			}
			if parts[0] == "Bearer" && strings.HasPrefix(token, apiKeyPlainPrefix) {
				return token, true
			}
		}
	}
	if key := strings.TrimSpace(string(c.GetHeader("X-API-Key"))); key != "" {
		return key, true
	}
	return "", false
}

// sha256Hex Key 摘要（与 app/user.HashAPIKey 同算法：hex(SHA-256)）
func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// ===== TouchLastUsed 写节流 =====

// touchInterval 每 Key 两次 last_used_at 落库的最小间隔。
// 多实例各自节流即可（目的仅是降写放大，非精确统计）。
const touchInterval = time.Minute

var touchThrottle sync.Map // keyID(uint) → last touch time.Time

func shouldTouchLastUsed(keyID uint, now time.Time) bool {
	if v, ok := touchThrottle.Load(keyID); ok && now.Sub(v.(time.Time)) < touchInterval {
		return false
	}
	touchThrottle.Store(keyID, now)
	return true
}

// ===== 校验与身份注入 =====

// validateAPIKey 校验明文 Key 并注入身份（与 JWT 中间件双写方言一致：
// c.Set 供 handler，ctx 注入供 service 层 UserIDFromContext 审计提取）。
// 防护链：lockout(apikey|IP 防爆破) → 摘要查库(吊销/过期) → 用户状态 → 触碰节流。
// 失败一律返回 errInvalidAPIKey 或 *LockedError，不泄露具体原因。
// 认证查询不走缓存：吊销/封禁必须即时生效（每请求 2 个索引查询，亚毫秒级）。
func validateAPIKey(ctx context.Context, c *app.RequestContext, plainKey string) (context.Context, error) {
	lock := GetDefaultLockout()
	lockKey := FormatLockKey("apikey", ClientIP(c))
	if remain, locked := lock.CheckLocked(ctx, lockKey); locked {
		return ctx, &LockedError{RemainingSeconds: remain}
	}

	keyRepo := dao.NewUserAPIKeyRepository()
	key, err := keyRepo.GetActiveByHash(ctx, sha256Hex(plainKey))
	if err != nil {
		_, _ = lock.RecordFailure(ctx, lockKey)
		return ctx, errInvalidAPIKey
	}

	user, err := dao.NewUserRepository().GetByID(ctx, key.UserID)
	if err != nil || user.Status != "active" {
		// 封禁/停用用户的 Key 视为无效 Key（同样计入防爆破）
		_, _ = lock.RecordFailure(ctx, lockKey)
		return ctx, errInvalidAPIKey
	}
	lock.Reset(ctx, lockKey)

	if shouldTouchLastUsed(key.ID, time.Now()) {
		_ = keyRepo.TouchLastUsed(ctx, key.ID)
	}

	c.Set("user_id", user.ID)
	c.Set("username", user.Username)
	c.Set("role", user.Role)
	c.Set("api_key_id", key.ID)   // 与 transport 侧 ContextKeyAPIKeyID 同字符串
	c.Set("auth_type", "api_key") // 与 transport 侧 ContextKeyAuthType 同字符串
	c.Header("X-User-ID", fmt.Sprintf("%d", user.ID))
	c.Header("X-Username", user.Username)
	c.Header("X-Role", user.Role)

	return withIdentity(ctx, user.ID, user.Username, user.Role, ClientIP(c)), nil
}

// respondAPIKeyError 统一错误响应：被锁定 → 429；无效 → 401（统一文案防枚举）。
func respondAPIKeyError(c *app.RequestContext, err error) {
	var le *LockedError
	if errors.As(err, &le) {
		c.Abort()
		c.JSON(http.StatusTooManyRequests, map[string]interface{}{
			"code":    errcode.CodeTooManyAttempts,
			"message": fmt.Sprintf("尝试过于频繁，已临时锁定，请 %d 秒后重试", le.RemainingSeconds),
		})
		return
	}
	c.Abort()
	c.JSON(http.StatusUnauthorized, map[string]interface{}{
		"code":    http.StatusUnauthorized,
		"message": "Invalid API Key",
	})
}

// ===== 对外中间件 =====

// OptionalAPIKey 可选 API Key 认证（fail-closed：携带即校验，无效一律 401/429）
func OptionalAPIKey() app.HandlerFunc {
	return func(ctx context.Context, c *app.RequestContext) {
		key, present := extractAPIKey(c)
		if !present {
			c.Next(ctx)
			return
		}
		newCtx, err := validateAPIKey(ctx, c, key)
		if err != nil {
			respondAPIKeyError(c, err)
			return
		}
		c.Next(newCtx)
	}
}

// OptionalIdentity 可选身份认证组：JWT（既有可选语义）→ API Key（fail-closed）。
// 未携带凭证 → 匿名；携带 Key 但无效 → 401；JWT 无效 → 匿名（会话过期 UX，与 Key 有意不对称）。
// 供 gen 路由挂载点整体替换 OptionalAuthMiddleware()（挂载函数直接 return 本切片）。
func OptionalIdentity() []app.HandlerFunc {
	return []app.HandlerFunc{OptionalAuthMiddleware(), OptionalAPIKey()}
}

// UserOrAPIKey 登录凭证二选一：API Key 或 JWT（含黑名单检查，复用 AuthMiddleware 完整语义）。
// 供 /api/v1 自定义 REST 组替换 transport UserAuth，向第三方开放 Key 访问。
// 边界（设计文档 §4.1）：绝不挂 /admin；/user/api-keys 保持 JWT-only（Key 不能管 Key）。
func UserOrAPIKey() app.HandlerFunc {
	return func(ctx context.Context, c *app.RequestContext) {
		if key, present := extractAPIKey(c); present {
			newCtx, err := validateAPIKey(ctx, c, key)
			if err != nil {
				respondAPIKeyError(c, err)
				return
			}
			c.Next(newCtx)
			return
		}
		AuthMiddleware()(ctx, c)
	}
}
```

注意：测试文件 import 块需补 `"sync"`（`touchThrottle = sync.Map{}` 用到）。

- [x] **Step 4: 跑测试确认通过**

Run: `cd core && go test ./pkg/middleware/ -run 'APIKey|UserOrAPIKey|OptionalIdentity|ShouldTouch' -v 2>&1 | tail -30`
Expected: 全部 PASS。若 `server.New` 在测试环境有信号处理问题，参照 `gen/handler/share/download_regression_test.go` 同款用法（已验证可行）。

- [x] **Step 5: 全包回归 + vet**

Run: `cd core && go vet ./pkg/middleware/ && go test ./pkg/middleware/ 2>&1 | tail -5`
Expected: 无 vet 告警；既有 ratelimit/lockout/clientip 测试不破。

- [x] **Step 6: 提交**

```bash
cd core && git add pkg/middleware/apikey.go pkg/middleware/apikey_test.go && git commit -m "feat(middleware): API Key 认证核心——fail-closed/防爆破/Touch节流/Bearer fcb_sk_ 兼容" -- pkg/middleware/apikey.go pkg/middleware/apikey_test.go
```

---

### Task 2: 挂载接线 + 删除孤儿中间件

**Files:**
- Delete: `transport/http/middleware/api_key_auth.go`（孤儿实现，被 pkg 版取代；其中 `APIKeyAuthWithAdmin` 违反最小权限，一并消失）
- Modify: `gen/router/share/middleware.go`（`_sharefileMw`/`_selectMw`/`_sharetextMw`）
- Modify: `gen/router/chunk/middleware.go`（`_chunkMw`）
- Modify: `gen/router/presign/middleware.go`（`_presignMw`）
- Modify: `bootstrap/bootstrap.go:868`（`/api/v1` 组中间件）

**Interfaces:**
- Consumes: Task 1 的 `middleware.OptionalIdentity() []app.HandlerFunc`、`middleware.UserOrAPIKey() app.HandlerFunc`（bootstrap 已 import pkg/middleware 为 `middleware`）

- [x] **Step 1: 确认孤儿无引用**

Run: `cd core && grep -rn "APIKeyAuth\|InitAPIKeyRepository\|GetAPIKeyRepository" --include="*.go" | grep -v "api_key_auth.go" | grep -v _test`
Expected: 仅 `transport/http/middleware/auth.go` 的常量/Helper（`ContextKeyAPIKeyID` 等，**保留**，pkg 版写入同字符串键）。无其他引用即可删。

- [x] **Step 2: 删除孤儿文件**

```bash
cd core && git rm transport/http/middleware/api_key_auth.go
```

- [x] **Step 3: 替换 gen 路由挂载点**

`gen/router/share/middleware.go` 三个函数改为：

```go
func _sharefileMw() []app.HandlerFunc {
	// 可选身份：JWT 或 API Key（Key fail-closed）；注入 user_id 供闸门/配额/归属
	return middleware.OptionalIdentity()
}

func _selectMw() []app.HandlerFunc {
	return middleware.OptionalIdentity()
}

func _sharetextMw() []app.HandlerFunc {
	return middleware.OptionalIdentity()
}
```

`gen/router/chunk/middleware.go`：

```go
// _chunkMw 可选身份：JWT 或 API Key；注入 user_id 供上传闸门区分匿名/登录（治理 2026-10-03）
func _chunkMw() []app.HandlerFunc {
	return middleware.OptionalIdentity()
}
```

`gen/router/presign/middleware.go`：

```go
// _presignMw 可选身份：JWT 或 API Key；注入 user_id 供上传闸门区分匿名/登录（治理 2026-10-03）
func _presignMw() []app.HandlerFunc {
	return middleware.OptionalIdentity()
}
```

（`_usersharesMw`/`_deleteshareMw` 等 `AuthMiddleware` 挂载保持不动。）

- [x] **Step 4: 替换 /api/v1 组中间件（bootstrap.go:868）**

```go
	// ===== 自定义 REST API（用户 JWT 或 API Key 认证）=====
	// UserOrAPIKey：浏览器走 JWT（含黑名单），第三方脚本走 X-API-Key / Bearer fcb_sk_。
	// 覆盖我的分享管理与站内通知；Key 永不进入 /admin 与 /user/api-keys（Key 不能管 Key）。
	apiV1 := r.Group("/api/v1", middleware.UserOrAPIKey())
```

（`customMw.UserAuth()` 换成 `middleware.UserOrAPIKey()`；`customMw` 别名仍被 admin 等处使用，import 不动。）

- [x] **Step 5: 编译 + 路由契约 + 全量测试**

Run: `cd core && go build ./... && go vet ./... && go test ./... 2>&1 | tail -15`
Expected: 编译通过；`routes_guard_test` PASS（无路径变更）；全量绿（`transport/http/handler/share_user.go` 属并行会话未提交改动，若其相关测试红需先甄别是否本任务引入）。

- [x] **Step 6: 提交**

```bash
cd core && git add -A gen/router/share/middleware.go gen/router/chunk/middleware.go gen/router/presign/middleware.go bootstrap/bootstrap.go && git commit -m "feat(auth): API Key 接入上传三通道与 /api/v1 组；删除孤儿 api_key_auth" -- gen/router/share/middleware.go gen/router/chunk/middleware.go gen/router/presign/middleware.go bootstrap/bootstrap.go transport/http/middleware/api_key_auth.go
```

---

### Task 3: 限流补位（bootstrap 限流 switch）

**Files:**
- Modify: `bootstrap/bootstrap.go:624-630`（路径感知限流 switch）

**Interfaces:**
- Consumes: 既有 `rl.LoginMiddleware()/rl.UploadMiddleware()`；UploadQPS 默认 10 / Burst 20（`ratelimit_test.go` 已断言）

- [x] **Step 1: 修改 switch**

```go
		switch {
		case strings.HasPrefix(path, "/admin/login"),
			strings.HasPrefix(path, "/api/v1/user/login"),
			strings.HasPrefix(path, "/user/login"):
			rl.LoginMiddleware()(ctx, c)
		case strings.HasPrefix(path, "/anonymous/generate"),
			strings.HasPrefix(path, "/anonymous/retrieve"),
			strings.HasPrefix(path, "/api/v1/presign"),
			strings.HasPrefix(path, "/api/v1/chunk"),
			strings.HasPrefix(path, "/share/text"),
			strings.HasPrefix(path, "/share/file"):
			rl.UploadMiddleware()(ctx, c)
		case strings.Contains(path, "/download"):
			rl.DownloadMiddleware()(ctx, c)
		default:
			c.Next(ctx)
		}
```

改动语义：① gen 登录端点 `/user/login` 补进 Login 维度（此前只匹配 `/api/v1/user/login` 前缀，lockout 有覆盖但限流层缺失）；② 直传 `/share/text`、`/share/file` 补进 Upload 维度（此前完全无限流；Web UI 直传同样受限，10 QPS/IP 与 chunk/presign 通道一致）。

- [x] **Step 2: 编译 + 全量测试**

Run: `cd core && go build ./... && go test ./... 2>&1 | tail -8`
Expected: 全绿。

- [x] **Step 3: 提交**

```bash
cd core && git add bootstrap/bootstrap.go && git commit -m "fix(ratelimit): gen 登录端点与直传 /share/text|file 补入路径限流" -- bootstrap/bootstrap.go
```

---

### Task 4: 设计文档勘误（hub 仓）+ 收尾核验

**Files:**
- Modify: `docs/design/2026-10-03-api-token-design.md`（hub 仓；§4.1 实现位置勘误 + §6 波次 1 勾选）

- [x] **Step 1: 勘误实现位置**

在 §4.1 开头补一句：

> **实现勘误（波次 1 落地）**：认证核心统一实现在 `core/pkg/middleware/apikey.go`（gen 路由只能 import pkg 层，且避免 pkg↔transport 双方言）；`UserOrAPIKey()` 同样落在 pkg/middleware；transport 侧孤儿文件 `api_key_auth.go` 删除（含 `APIKeyAuthWithAdmin`）。挂载点名称对应关系：文档中 `OptionalIdentityMiddleware()` → 实现名 `OptionalIdentity()`（返回 `[]app.HandlerFunc` 便于 gen 挂载点整体替换）。

- [x] **Step 2: core 三连验证（最终门禁）**

Run: `cd core && go build ./... && go vet ./... && go test ./... 2>&1 | tail -8 && git log --oneline -4`
Expected: 全绿 + 3 个新 commit（Task 1/2/3）。

- [x] **Step 3: 提交文档（hub 仓，只提交该文件）**

```bash
cd FilesCodeBox && git add docs/design/2026-10-03-api-token-design.md && git commit -m "docs: API Token 波次1落地勘误（认证核心落位 pkg/middleware/apikey.go）" -- docs/design/2026-10-03-api-token-design.md
```

---

## Self-Review 记录

- 规格覆盖：§4.1 接线（Task 2）、§4.2 a-e 五项收紧（Task 1：a=Status 校验、b=query 删除、c=节流、d=fail-closed、e=lockout）、§4.3 限流补位（Task 3）、路由契约与测试（Task 1/2）。§4.5 配置面属波次 2，本计划不含。
- 类型一致性：`OptionalIdentity() []app.HandlerFunc`（gen 挂载函数返回切片）；`UserOrAPIKey() app.HandlerFunc`（Group 参数单 handler）；测试与实现同名符号已对齐（`apiKeyPlainPrefix`/`sha256Hex`/`touchThrottle` 包内可见）。
- 占位符：无 TBD；所有代码块为完整可用实现。
