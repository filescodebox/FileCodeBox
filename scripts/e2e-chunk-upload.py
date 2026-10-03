#!/usr/bin/env python3
"""大文件分片上传端到端验证（对标上游踩坑清单头号主题：大文件上传失败）。

场景：48MB 随机文件 / 2MB 分片 = 24 片
  1. init（带 SHA-256）
  2. 并发上传 22 片（跳过 #5 #17，6 并发模拟真实客户端）
  3. status 断点续传：uploaded_indexes 恰为 22
  4. 补传缺失 2 片 → status 全齐
  5. complete（require_auth + password）→ 返回真实分享码（回归 P0：曾返回 uploadID）
  6. select 无密码 401 / 正确密码 200 拿下载令牌
  7. 下载内容 SHA-256 与原文件一致
  8. 分片通道秒传：同哈希二次 init → is_quick_upload=true 且复用分享码
"""
import concurrent.futures
import hashlib
import io
import json
import os
import sys
import urllib.request
import uuid

BASE = "http://localhost:12345"
CHUNK = 2 * 1024 * 1024
SIZE = 48 * 1024 * 1024
TOTAL = SIZE // CHUNK

failures = []


def check(name, ok, detail=""):
    print(("  ✓ " if ok else "  ✗ ") + name + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def post_form(url, fields, files=None):
    boundary = uuid.uuid4().hex
    body = io.BytesIO()
    for k, v in (fields or {}).items():
        body.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    for k, (fn, data) in (files or {}).items():
        body.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"; filename=\"{fn}\"\r\nContent-Type: application/octet-stream\r\n\r\n".encode())
        body.write(data)
        body.write(b"\r\n")
    body.write(f"--{boundary}--\r\n".encode())
    req = urllib.request.Request(BASE + url, data=body.getvalue(), method="POST",
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def get(url):
    try:
        with urllib.request.urlopen(BASE + url, timeout=120) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


print("== 准备 48MB 随机文件 ==")
data = os.urandom(SIZE)
sha = hashlib.sha256(data).hexdigest()
print(f"  sha256={sha[:16]}... total_chunks={TOTAL}")

print("== 1. init ==")
st, res = post_form("/chunk/upload/init/", {
    "file_name": "e2e-big.bin", "file_size": str(SIZE),
    "file_hash": sha, "chunk_size": str(CHUNK), "total_chunks": str(TOTAL),
})
check("init 200", st == 200 and res["code"] == 200, str(res)[:120])
upload_id = res["data"]["upload_id"]
print(f"  upload_id={upload_id[:24]}...")

print("== 2. 并发上传 22/24（跳过 #5 #17, 6 并发）==")
skip = {5, 17}
idxs = [i for i in range(TOTAL) if i not in skip]

def put_chunk(i):
    st, res = post_form(f"/chunk/upload/chunk/{upload_id}/{i}",
                        {}, {"chunk": (f"c{i}", data[i*CHUNK:(i+1)*CHUNK])})
    return i, st == 200 and res["code"] == 200

with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
    results = list(ex.map(put_chunk, idxs))
ok_cnt = sum(1 for _, ok in results if ok)
check(f"并发 22 片成功（实际 {ok_cnt}）", ok_cnt == 22)

print("== 3. status 断点续传 ==")
st, body = get(f"/chunk/upload/status/{upload_id}")
st_data = json.loads(body)["data"]
check("uploaded=22", st_data["uploaded_chunks"] == 22, str(st_data)[:120])
have = set(st_data["uploaded_indexes"])
check("缺失恰为 #5 #17", have == set(idxs), str(have ^ set(idxs)))

print("== 4. 断点补传 ==")
for i in sorted(skip):
    _, ok = put_chunk(i)
    check(f"补传 #{i}", ok)
st, body = get(f"/chunk/upload/status/{upload_id}")
check("补传后 uploaded=24", json.loads(body)["data"]["uploaded_chunks"] == TOTAL)

print("== 5. complete（带密码）==")
PASSWORD = "e2e-pass-123"
st, res = post_form(f"/chunk/upload/complete/{upload_id}", {
    "expire_value": "1", "expire_style": "day",
    "require_auth": "true", "password": PASSWORD,
})
check("complete 200", st == 200 and res["code"] == 200, str(res)[:200])
share_code = res["data"]["share_code"]
check("返回真实分享码(非 uploadID)", share_code and share_code != upload_id, share_code)
print(f"  share_code={share_code}")

print("== 6. 密码校验 ==")
st, body = get(f"/share/select/?code={share_code}")
check("无密码 401", st == 401, str(st))
st, body = get(f"/share/select/?code={share_code}&password=wrong-pass")
check("错密码 401", st == 401, str(st))
st, body = get(f"/share/select/?code={share_code}&password={PASSWORD}")
sel = json.loads(body)
check("对密码 200", st == 200 and sel["code"] == 200, str(body)[:120])
dl_url = sel["data"]["download_url"]
check("下发下载令牌", "token=" in dl_url)

print("== 7. 下载内容比对 ==")
st, content = get(dl_url)
check("下载 200", st == 200, str(st))
dl_sha = hashlib.sha256(content).hexdigest()
check(f"SHA-256 一致（{len(content)} 字节）", dl_sha == sha, f"{dl_sha[:16]} vs {sha[:16]}")

print("== 8. 分片通道秒传 ==")
st, res = post_form("/chunk/upload/init/", {
    "file_name": "e2e-big-copy.bin", "file_size": str(SIZE),
    "file_hash": sha, "chunk_size": str(CHUNK), "total_chunks": str(TOTAL),
})
qd = res["data"]
check("is_quick_upload=true", qd.get("is_quick_upload") is True, str(qd)[:150])
check("复用分享码", qd.get("share_code") == share_code, f"{qd.get('share_code')} vs {share_code}")

print()
if failures:
    print(f"✗ {len(failures)} 项失败: {failures}")
    sys.exit(1)
print("✓✓ 大文件分片端到端全部通过（断点续传/并发/密码/秒传/内容一致性）")
