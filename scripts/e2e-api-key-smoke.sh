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

echo "=== e2e 全链路 OK ==="
