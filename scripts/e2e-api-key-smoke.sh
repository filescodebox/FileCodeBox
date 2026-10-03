#!/usr/bin/env bash
# API Key e2e 回归：签发 → Key 直传/管理 → 无效/吊销 401（依赖 localhost:12345 空闲 + 默认 admin 密码）
set -u
cd "$(dirname "$0")/.."
cd server || exit 1
mkdir -p data logs

FCB_JWT_SECRET=$(openssl rand -hex 32) go run ./cmd/server --config ./configs/config.yaml >/tmp/fcb-e2e.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf http://localhost:12345/live >/dev/null 2>&1 && break; sleep 1; done
curl -sf http://localhost:12345/live >/dev/null || { echo "✗ server 未就绪"; tail -20 /tmp/fcb-e2e.log; exit 1; }
echo "✓ server 就绪"

B=http://localhost:12345
jqq() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)"; }

# 1. admin 登录拿 JWT
JWT=$(curl -sf -X POST $B/admin/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin123"}' | jqq "['data']['token']")
[ -n "$JWT" ] && echo "✓ admin 登录（JWT ${#JWT} 字符）" || { echo "✗ 登录失败"; exit 1; }

# 1.5 清场：吊销历史 Key，避免 5 把上限影响重复执行（旧版本无此端点，忽略失败）
curl -s -o /dev/null -X POST $B/user/api-keys/revoke-all -H "Authorization: Bearer $JWT" || true

# 2. 签发 API Key
RESP=$(curl -sf -X POST $B/user/api-keys -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' -d '{"name":"e2e-smoke"}')
KEY=$(echo "$RESP" | jqq "['data']['key']")
KID=$(echo "$RESP" | jqq "['data']['api_key']['id']")
[ -n "$KEY" ] && echo "✓ 签发 Key：${KEY:0:12}…（id=${KID}）" || { echo "✗ 签发失败: $RESP"; exit 1; }

# 3. Key 直传文本（X-API-Key 头）
R3=$(curl -s -X POST $B/share/text/ -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"text":"api-key e2e smoke","expire_value":1,"expire_style":"hour","require_auth":false}')
echo "$R3" | head -c 200; echo ""
CODE3=$(echo "$R3" | jqq "['code']")
{ [ "$CODE3" = "0" ] || [ "$CODE3" = "200" ]; } && echo "✓ Key 直传文本成功" || { echo "✗ Key 直传失败 code=$CODE3"; exit 1; }

# 4. Bearer fcb_sk_ 列举自己的分享（/api/v1 组）
R4=$(curl -s "$B/api/v1/user/shares?page=1&page_size=10" -H "Authorization: Bearer $KEY")
CODE4=$(echo "$R4" | jqq "['code']")
{ [ "$CODE4" = "0" ] || [ "$CODE4" = "200" ]; } && echo "✓ Bearer fcb_sk_ 列举自己分享成功" || { echo "✗ /api/v1 组 Key 认证失败: $(echo "$R4" | head -c 200)"; exit 1; }

# 5. 无效 Key 必须 401（fail-closed）
R5=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/share/text/ -H "X-API-Key: ${KEY}bad" \
  -H 'Content-Type: application/json' -d '{"text":"x","expire_value":1,"expire_style":"hour","require_auth":false}')
[ "$R5" = "401" ] && echo "✓ 无效 Key 401（fail-closed）" || { echo "✗ 无效 Key 返回 $R5"; exit 1; }

# 6. JWT 吊销 Key
curl -sf -X DELETE "$B/user/api-keys/$KID" -H "Authorization: Bearer $JWT" >/dev/null && echo "✓ 吊销 Key"

# 7. 吊销后再用 → 401
R7=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/share/text/ -H "X-API-Key: $KEY" \
  -H 'Content-Type: application/json' -d '{"text":"x","expire_value":1,"expire_style":"hour","require_auth":false}')
[ "$R7" = "401" ] && echo "✓ 吊销后 Key 401" || { echo "✗ 吊销后仍可用：$R7"; exit 1; }

# 8. 再签发一把（供 revoke-all 与归因验证）
RESP2=$(curl -sf -X POST $B/user/api-keys -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' -d '{"name":"e2e-keep"}')
KEY2=$(echo "$RESP2" | jqq "['data']['key']")
[ -n "$KEY2" ] && echo "✓ 签发第二把 Key" || { echo "✗ 第二把签发失败"; exit 1; }

# 9. Key2 上传 → transfer_logs.api_key_id 应为该 Key（Key 粒度归因）
curl -s -o /dev/null -X POST $B/share/text/ -H "X-API-Key: $KEY2" \
  -H 'Content-Type: application/json' -d '{"text":"attr","expire_value":1,"expire_style":"hour","require_auth":false}'
sleep 1
ATTR=$(sqlite3 data/fileCodeBox.db "SELECT api_key_id FROM transfer_logs WHERE operation='upload' ORDER BY id DESC LIMIT 1")
[ -n "$ATTR" ] && echo "✓ 传输日志归因 api_key_id=$ATTR" || { echo "✗ 传输日志未落 api_key_id"; exit 1; }

# 10. 一键吊销全部（JWT-only）
RA=$(curl -sf -X POST $B/user/api-keys/revoke-all -H "Authorization: Bearer $JWT" | jqq "['data']['revoked']")
[ -n "$RA" ] && echo "✓ revoke-all 吊销 ${RA} 把" || { echo "✗ revoke-all 失败"; exit 1; }
R10=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/share/text/ -H "X-API-Key: $KEY2" \
  -H 'Content-Type: application/json' -d '{"text":"x","expire_value":1,"expire_style":"hour","require_auth":false}')
[ "$R10" = "401" ] && echo "✓ revoke-all 后 Key2 401" || { echo "✗ revoke-all 后仍可用：$R10"; exit 1; }

# 11. refresh 黑名单：登出后旧 JWT 不得再换新 token
curl -s -o /dev/null -X POST $B/api/v1/user/logout -H "Authorization: Bearer $JWT"
R11=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/v1/user/refresh -H "Authorization: Bearer $JWT")
[ "$R11" = "401" ] && echo "✓ 登出后 refresh 401（黑名单生效）" || { echo "✗ 登出后 refresh 仍可用：$R11"; exit 1; }

echo "=== e2e 全链路 OK ==="
