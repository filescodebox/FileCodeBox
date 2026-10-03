#!/bin/bash
# FilesCodeBox 全能力真机冒烟（39 项断言）：健康面/openapi 运行时生成/api config/admin 登录/
# 文本+密码分享/元数据不泄露/select 不扣次数/文件分享+Range/多文件+zip/chunk 完成+秒传/
# 本地文件管理(穿越防护)/寄件码全链路/MCP/二维码/匿名码(需 Redis)/robots。
# 用法: bash scripts/smoke-full.sh（自动编译 server、起临时实例、跑完即清理）
J() { python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(eval(sys.argv[1], {'d': d}))
except Exception as e:
    print('JERR:'+str(e))
" "$1" 2>/dev/null; }

mkdir -p "$SMOKE"/{data,uploads,import,src}
echo "smoke-local-content-$(date +%s)" > "$SMOKE/import/local-nas.txt"
printf 'hello-filescodebox-range' > "$SMOKE/src/smoke-range.txt"
head -c 300000 /dev/zero | tr '\0' 'A' > "$SMOKE/src/big-a.txt"
echo "multi-file-one" > "$SMOKE/src/m1.txt"
echo "multi-file-two" > "$SMOKE/src/m2.txt"

cat > "$SMOKE/config.yaml" <<EOF
server:
  host: "127.0.0.1"
  port: $PORT
  mode: "dev"
  base_url: "$BASE"
redis:
  host: "127.0.0.1"
  port: 16379
  password: ""
  db: 0
database:
  driver: "sqlite"
  db_name: "$SMOKE/data/fcb.db"
app:
  name: "FilesCodeBox-Smoke"
  datapath: "$SMOKE/data"
upload:
  open_upload: true
  upload_size: 104857600
  enable_chunk: true
  chunk_size: 1048576
  max_file_size: 104857600
  local_import:
    enabled: true
    roots: ["$SMOKE/import"]
storage:
  type: "local"
  storage_path: "$SMOKE/uploads"
log:
  level: "warn"
user:
  allow_user_registration: true
observability:
  metrics:
    enabled: false
EOF

# 编译 + 起服务
cd /Users/zhangyi/my_project/filecodebox-project/FilesCodeBox/server || exit 1
go build -o "$SMOKE/server-bin" ./cmd/server || { echo "BUILD FAILED"; exit 1; }
FCB_JWT_SECRET=smoke-secret-$(date +%s) "$SMOKE/server-bin" --config "$SMOKE/config.yaml" > "$SMOKE/server.log" 2>&1 &
SRV=$!
redis-server --port 16379 --daemonize no --save '' --appendonly no > "$SMOKE/redis.log" 2>&1 &
RPID=$!
trap 'kill $SRV $RPID 2>/dev/null' EXIT
for i in $(seq 1 30); do
  curl -sf "$BASE/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf "$BASE/health" >/dev/null || { echo "SERVER NOT UP"; tail -20 "$SMOKE/server.log"; exit 1; }

# S1 健康面
[ -n "$(curl -s "$BASE/live")" ] && ok "S1a live" || bad "S1a live" "$(curl -s $BASE/live)"
curl -s "$BASE/readyz" | grep -qi 'ok\|ready\|true' && ok "S1b readyz" || bad "S1b readyz" "$(curl -s $BASE/readyz | head -c 120)"
[ -n "$(curl -s "$BASE/version")" ] && ok "S1c version" || bad "S1c version" "-"

# S2 openapi.json 运行时生成
OA=$(curl -s "$BASE/openapi.json")
echo "$OA" | grep -q '"/share/metadata/{code}"' && ok "S2a openapi 含 metadata 端点" || bad "S2a openapi metadata" "-"
echo "$OA" | grep -q '"/admin/local-files"' && ok "S2b openapi 含 local-files 端点" || bad "S2b openapi local-files" "-"
N=$(echo "$OA" | J "len(d['paths'])")
case "$N" in JERR*|"") bad "S2c openapi paths 数" "$N";; [0-9]*) [ "$N" -ge 90 ] && ok "S2c openapi paths=$N" || bad "S2c openapi paths=$N" "<90";; esac

# S3 /api/config
AC=$(curl -s "$BASE/api/config")
echo "$AC" | J "d['data']['expireStyle']" | grep -q week && ok "S3 api/config 下发 expireStyle" || bad "S3 api/config" "$(echo $AC | head -c 100)"

# S4 admin 登录
TOK=$(curl -s -X POST "$BASE/admin/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin123"}' | J "d['data']['token']")
[ -n "$TOK" ] && [ "$TOK" != "JERR"* ] && ok "S4 admin 登录" || bad "S4 admin 登录" "$TOK"
AH="Authorization: Bearer $TOK"

# S5 文本分享
CODE_T=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"smoke-text-hello","expire_value":1,"expire_style":"day","require_auth":false}' | J "d['data']['code']")
[ -n "$CODE_T" ] && [ "${CODE_T:0:4}" != "JERR" ] && ok "S5 文本分享 code=$CODE_T" || bad "S5 文本分享" "$CODE_T"

# S6 metadata（text）
MD=$(curl -s "$BASE/share/metadata/$CODE_T")
[ "$(echo "$MD" | J "d['data']['type']")" = "text" ] && ok "S6a metadata type=text" || bad "S6a metadata text" "$MD"
[ "$(echo "$MD" | J "d['data']['has_password']")" = "False" ] && ok "S6b metadata has_password=false" || bad "S6b metadata" "$MD"
echo "$MD" | grep -q "smoke-text-hello" && bad "S6c metadata 泄露文本内容!" "$MD" || ok "S6c metadata 不外泄内容"

# S7 select 查询不扣次数 + 下载（次数=1 的分享，查询 3 次后仍可下载）
CODE_1=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"once-only","expire_value":1,"expire_style":"count","require_auth":false}' | J "d['data']['code']")
SEL=$(curl -s "$BASE/share/select/?code=$CODE_1")
DL=$(echo "$SEL" | J "d['data']['download_url']"); case "$DL" in /*) DL="$BASE$DL";; esac
for i in 1 2 3; do curl -s "$BASE/share/select/?code=$CODE_1" >/dev/null; done
BODY=$(curl -s "$DL")
echo "$BODY" | grep -q "once-only" && ok "S7 select 不扣次数+令牌下载" || bad "S7 下载" "$(echo "$BODY" | head -c 80)"

# S8 密码分享
CODE_P=$(curl -s -X POST "$BASE/share/text/" -F "text=secret-pwd" -F "expire_value=1" -F "expire_style=day" -F "require_auth=true" -F "password=pw123" | J "d['data']['code']")
[ "$(curl -s "$BASE/share/metadata/$CODE_P" | J "d['data']['has_password']")" = "True" ] && ok "S8a 密码分享 metadata has_password" || bad "S8a has_password" "-"
curl -s "$BASE/share/select/?code=$CODE_P" | grep -q "密码\|password" && ok "S8b 无密码查询被拒" || bad "S8b 无密码查询" "-"
curl -s "$BASE/share/select/?code=$CODE_P&password=pw123" | grep -q "download_url" && ok "S8c 带密码查询通过" || bad "S8c 带密码查询" "-"

# S9 文件上传 + metadata + Range
CODE_F=$(curl -s -X POST "$BASE/share/file/" -F "file=@$SMOKE/src/smoke-range.txt" -F "expire_value=1" -F "expire_style=day" | J "d['data']['code']")
[ -n "$CODE_F" ] && [ "${CODE_F:0:4}" != "JERR" ] && ok "S9a 文件分享 code=$CODE_F" || bad "S9a 文件分享" "$CODE_F"
[ "$(curl -s "$BASE/share/metadata/$CODE_F" | J "d['data']['name']")" = "smoke-range.txt" ] && ok "S9b metadata 文件名" || bad "S9b metadata name" "-"
DLF=$(curl -s "$BASE/share/select/?code=$CODE_F" | J "d['data']['download_url']"); case "$DLF" in /*) DLF="$BASE$DLF";; esac
R=$(curl -s -H "Range: bytes=0-4" -o /dev/null -w "%{http_code}" "$DLF")
[ "$R" = "206" ] && ok "S9c Range 206" || bad "S9c Range" "$R"
PART=$(curl -s -H "Range: bytes=0-4" "$DLF")
[ "$PART" = "hello" ] && ok "S9d Range 内容正确" || bad "S9d Range 内容" "$PART"

# S10 多文件直传 + zip
CODE_M=$(curl -s -X POST "$BASE/api/v1/share/multi-direct" -F "files=@$SMOKE/src/m1.txt" -F "files=@$SMOKE/src/m2.txt" -F "expire_value=1" -F "expire_style=day" | J "d['data']['code']")
[ -n "$CODE_M" ] && [ "${CODE_M:0:4}" != "JERR" ] && ok "S10a 多文件分享 code=$CODE_M" || bad "S10a 多文件" "$CODE_M"
DLM=$(curl -s "$BASE/share/select/?code=$CODE_M" | J "d['data']['download_url']"); case "$DLM" in /*) DLM="$BASE$DLM";; esac
curl -s "$DLM" -o "$SMOKE/dl.zip"
python3 -c "
import zipfile,sys
z = zipfile.ZipFile('$SMOKE/dl.zip')
names = z.namelist()
assert len(names) == 2, names
assert z.read(names[0]).rstrip(b'\n') in (b'multi-file-one', b'multi-file-two')
print('ZIP-OK')
" 2>/dev/null && ok "S10b 多文件 zip 2 entries" || bad "S10b zip" "$(file $SMOKE/dl.zip | head -c 80)"

# S11 chunk 分片上传完整闭环 + 完成后秒传
UPID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
HA=$(sha256sum "$SMOKE/src/big-a.txt" | cut -d' ' -f1)
INIT=$(curl -s -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"big-a.txt\",\"file_size\":300000,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$HA\"}")
UPID=$(echo "$INIT" | J "d['data']['upload_id']")
curl -s -X POST "$BASE/chunk/upload/chunk/$UPID/0" -F "chunk=@$SMOKE/src/big-a.txt" > /dev/null
CMP=$(curl -s -X POST "$BASE/chunk/upload/complete/$UPID" -H 'Content-Type: application/json' -d '{"expire_value":1,"expire_style":"day","require_auth":false}')
CMP_CODE=$(echo "$CMP" | J "d['data']['share_code']") ; [ "$CMP_CODE" = "JERR"* ] || [ -z "$CMP_CODE" ] && CMP_CODE=$(echo "$CMP" | J "d['data']['code']")
[ -n "$CMP_CODE" ] && [ "${CMP_CODE:0:4}" != "JERR" ] && ok "S11a 分片完成→建分享 code=$CMP_CODE" || bad "S11a chunk complete" "$(echo $CMP | head -c 120)"
HA=$(sha256sum "$SMOKE/src/big-a.txt" | cut -d' ' -f1)
QI=$(curl -s -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"big-a.txt\",\"file_size\":300000,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$HA\"}")
[ "$(echo "$QI" | J "d['data']['is_quick_upload']")" = "True" ] && ok "S11b 秒传命中" || bad "S11b 秒传" "$(echo $QI | head -c 120)"

# S12 管理端本地文件
LF=$(curl -s "$BASE/admin/local-files?root=0" -H "$AH")
[ "$(echo "$LF" | J "len(d['data']['entries'])")" -ge 1 ] && ok "S12a local-files 列表" || bad "S12a 列表" "$(echo $LF | head -c 100)"
CODE_L=$(curl -s -X POST "$BASE/admin/local-files/import" -H "$AH" -H 'Content-Type: application/json' -d "{\"root\":0,\"path\":\"local-nas.txt\",\"expire_value\":1,\"expire_style\":\"day\"}" | J "d['data']['code']")
[ -n "$CODE_L" ] && [ "${CODE_L:0:4}" != "JERR" ] && ok "S12b 本地文件生成提取码 code=$CODE_L" || bad "S12b 导入" "$CODE_L"
DLL=$(curl -s "$BASE/share/select/?code=$CODE_L" | J "d['data']['download_url']"); case "$DLL" in /*) DLL="$BASE$DLL";; esac
curl -s "$DLL" | grep -q "smoke-local-content" && ok "S12c 导入分享可下载" || bad "S12c 下载" "-"
DEL=$(curl -s -X DELETE "$BASE/admin/local-files?root=0&path=local-nas.txt" -H "$AH")
[ ! -f "$SMOKE/import/local-nas.txt" ] && ok "S12d 本地文件删除" || bad "S12d 删除" "$DEL"
curl -s "$BASE/admin/local-files?root=0&dir=../../etc" -H "$AH" | grep -qi "非法\|越界\|不在" && ok "S12e 路径穿越被拒" || bad "S12e 穿越防护" "-"

# S13 寄件码（用户注册→建链接→访客投递）
curl -s -X POST "$BASE/user/register" -H 'Content-Type: application/json' -d '{"username":"smoker","password":"smoke12345","nickname":"smoker","email":"smoker@example.com"}' >/dev/null
UTOK=$(curl -s -X POST "$BASE/user/login" -H 'Content-Type: application/json' -d '{"username":"smoker","password":"smoke12345"}' | J "d['data']['token']")
[ -n "$UTOK" ] && [ "${UTOK:0:4}" != "JERR" ] && ok "S13a 用户注册登录" || bad "S13a 用户登录" "$UTOK"
REQ=$(curl -s -X POST "$BASE/api/v1/user/requests" -H "Authorization: Bearer $UTOK" -H 'Content-Type: application/json' -d '{"title":"smoke-req","expire_value":1,"expire_style":"day"}')
RTOK=$(echo "$REQ" | J "d['data']['token']")
[ -n "$RTOK" ] && [ "${RTOK:0:4}" != "JERR" ] && ok "S13b 建寄件链接 token" || bad "S13b 寄件链接" "$REQ"
curl -s "$BASE/request/$RTOK" | grep -q "smoke-req\|title" && ok "S13c 访客可取链接信息" || bad "S13c 访客取链接" "-"
GUP=$(curl -s -X POST "$BASE/api/v1/request/$RTOK/upload" -F "files=@$SMOKE/src/m1.txt")
echo "$GUP" | grep -qi "code\|success" && ok "S13d 访客投递" || bad "S13d 投递" "$(echo $GUP | head -c 100)"

# S14 MCP
MCP=$(curl -s -X POST "$BASE/api/v1/mcp" -H "$AH" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
NT=$(echo "$MCP" | J "len(d['result']['tools'])")
case "$NT" in [0-9]*) [ "$NT" -ge 8 ] && ok "S14 MCP tools=$NT" || bad "S14 MCP tools=$NT" "<8";; *) bad "S14 MCP" "$(echo $MCP | head -c 100)";; esac

# S15 二维码
curl -s -X POST "$BASE/qrcode/generate" -H 'Content-Type: application/json' -d "{\"data\":\"$BASE/share/$CODE_T\",\"size\":200}" | grep -qi "png\|base64\|id" && ok "S15 二维码生成" || bad "S15 二维码" "-"

# S16 匿名口令分享
AG=$(curl -s -X POST "$BASE/anonymous/generate" -H 'Content-Type: application/json' -d '{"file_name":"anon.txt","file_size":12,"expire_value":"1","expire_style":"day"}')
ACODE=$(echo "$AG" | J "d['data']['code']")
[ -n "$ACODE" ] && [ "${ACODE:0:4}" != "JERR" ] && ok "S16a 匿名码 code=$ACODE" || bad "S16a 匿名生成" "$AG"
curl -s "$BASE/anonymous/search/$ACODE" | grep -qi "anon.txt\|file_name" && ok "S16b 匿名码可检索" || bad "S16b 匿名检索" "-"
curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' -d "{\"code\":\"$ACODE\"}" | grep -qi "不存在\|未上传\|过期\|code" && ok "S16c 未上传检索优雅拒绝" || bad "S16c 检索" "-"

# S17 robots
curl -s "$BASE/robots.txt" | grep -q "User-agent" && ok "S17 robots.txt" || bad "S17 robots" "-"

echo ""
echo "=============================="
echo "SMOKE RESULT: PASS=$PASS FAIL=$FAIL"
exit $FAIL
