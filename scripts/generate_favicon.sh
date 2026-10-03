#!/bin/bash

# 为 FilesCodeBox 生成 favicon 全套资源
# 真相源: frontend/public/favicon.svg(512 画布, 圆角快递柜图标)
# 产物(写入 frontend/public/):
#   favicon.ico(16/32/48)  favicon-16x16.png  favicon-32x32.png
#   apple-touch-icon.png(180, 全出血无圆角, iOS 自行裁切)
# 依赖: python3 + cairosvg(pip install cairosvg)
#
# 用法: bash scripts/generate_favicon.sh   (在 hub 根目录执行)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/frontend/public/favicon.svg"
OUT="$ROOT/frontend/public"

[ -f "$SRC" ] || { echo "✗ 找不到真相源 $SRC"; exit 1; }
python3 -c 'import cairosvg' 2>/dev/null || { echo "✗ 缺少 cairosvg: pip install cairosvg"; exit 1; }

echo "正在为 FilesCodeBox 生成 favicon..."

python3 - "$SRC" "$OUT" <<'PYEOF'
import io, struct, sys
import cairosvg

src, out = sys.argv[1], sys.argv[2]
svg = open(src).read()

def render(size, s=svg):
    return cairosvg.svg2png(bytestring=s.encode(), output_width=size, output_height=size)

# 平铺 PNG 后备
for s in (16, 32):
    open(f"{out}/favicon-{s}x{s}.png", "wb").write(render(s))

# apple-touch-icon: 去掉背景圆角 → 全出血(iOS 会自动裁圆角, 透明区域会变黑须避免)
full_bleed = svg.replace(' rx="116"', '')
open(f"{out}/apple-touch-icon.png", "wb").write(
    cairosvg.svg2png(bytestring=full_bleed.encode(), output_width=180, output_height=180))

# favicon.ico: PNG 压缩条目(Vista+ 全支持), 每档由矢量直出, 不经位图重采样
sizes = [16, 32, 48]
blobs = [render(s) for s in sizes]
ico = struct.pack("<HHH", 0, 1, len(blobs))
offset = 6 + 16 * len(blobs)
for s, b in zip(sizes, blobs):
    ico += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(b), offset)
    offset += len(b)
open(f"{out}/favicon.ico", "wb").write(ico + b"".join(blobs))
print("✓ favicon.ico(16/32/48) favicon-16x16.png favicon-32x32.png apple-touch-icon.png")
PYEOF

echo "✓ 生成完成 → frontend/public/"
echo "  改动图标后请同步: cd frontend && npm run build, 再 rsync dist/ → server/static/"
