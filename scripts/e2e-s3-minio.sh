#!/usr/bin/env bash
# S3 存储后端真实 E2E（MinIO）。
#
# 在可访问 Docker registry 的环境运行，验证 storage.type=s3 全链路：
#   上传 → 对象落 MinIO → 取件下载内容一致 → 删除分享后对象消失。
#
# 用法: bash scripts/e2e-s3-minio.sh
# 依赖: docker、curl、python3
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER=fcb-minio-e2e
PORT=9000
DATA="$(mktemp -d)"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$DATA"
}
trap cleanup EXIT

echo "== 1. 启动 MinIO =="
docker run -d --name "$CONTAINER" -p "$PORT":9000 \
  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data >/dev/null
sleep 5

echo "== 2. 以 s3 存储启动 server =="
cd "$ROOT/server"
mkdir -p "$DATA/static" && cp -R static/* "$DATA/static/" 2>/dev/null || true
cat > "$DATA/config.yaml" <<EOF
server: {host: "127.0.0.1", port: 12345, mode: "debug", base_url: "http://127.0.0.1:12345"}
database: {driver: "sqlite", db_name: "$DATA/fcb.db"}
redis: {host: "", port: 6379}
log: {level: "error"}
app: {name: "fcb-e2e", datapath: "$DATA/data", production: false}
upload: {open_upload: true, upload_size: 10485760, enable_chunk: false}
storage:
  type: "s3"
  storage_path: "$DATA/uploads"
  s3:
    endpoint: "http://127.0.0.1:$PORT"
    region: "us-east-1"
    bucket: "fcb-e2e"
    access_key: "minioadmin"
    secret_key: "minioadmin"
    use_ssl: false
    path_style: true
user:
  jwt_secret: "e2e-secret-key-0123456789abcdef0123456789abcdef"
EOF
FCB_JWT_SECRET="e2e-secret-key-0123456789abcdef0123456789abcdef" \
  go run ./cmd/server --config "$DATA/config.yaml" >"$DATA/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; cleanup' EXIT
for i in $(seq 1 30); do curl -sf http://127.0.0.1:12345/live >/dev/null 2>&1 && break; sleep 1; done
curl -sf http://127.0.0.1:12345/live >/dev/null || { echo "✗ server 未就绪"; tail -20 "$DATA/server.log"; exit 1; }
echo "server up"

echo "== 3. 文件分享（应写入 MinIO）=="
printf 'minio-e2e-content-%s' "$(date +%s)" > "$DATA/origin.txt"
CODE=$(curl -sf -X POST http://127.0.0.1:12345/share/file/ \
  -F "file=@$DATA/origin.txt" -F "expire_value=1" -F "expire_style=day" -F "require_auth=false" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['code'])")
echo "share code: $CODE"

echo "== 4. MinIO 中存在对象 =="
docker exec "$CONTAINER" sh -c "ls -R /data 2>/dev/null | grep -q uploads" \
  && echo "✓ 对象已落 MinIO" || { echo "✗ MinIO 中未找到对象"; exit 1; }

echo "== 5. 取件下载内容一致 =="
DL=$(curl -s "http://127.0.0.1:12345/share/select/?code=$CODE" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['download_url'])")
curl -sf "http://127.0.0.1:12345$DL" > "$DATA/downloaded.txt"
cmp -s "$DATA/origin.txt" "$DATA/downloaded.txt" && echo "✓ 下载内容一致" || { echo "✗ 内容不一致"; exit 1; }

echo "== 6. 删除分享 → 对象消失 =="
TOKEN=$(curl -sf -X POST http://127.0.0.1:12345/admin/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin123"}' | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['token'])")
FILE_ID=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:12345/admin/files?keyword=$CODE" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('data') or {}).get('items',[{}])[0].get('id',''))")
curl -sf -X DELETE -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:12345/admin/files/$FILE_ID" >/dev/null
sleep 1
docker exec "$CONTAINER" sh -c "ls -R /data 2>/dev/null | grep -q uploads" \
  && { echo "✗ 删除后对象仍存在"; exit 1; } || echo "✓ 删除后对象已清理"

echo ""
echo "✓✓ S3 存储后端 E2E 全部通过"
