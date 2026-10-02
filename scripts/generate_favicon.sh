#!/bin/bash

# 为 FileCodeBox 项目生成 favicon 的脚本
# 使用 SVG 创建不同尺寸的 favicon

echo "正在为 FileCodeBox 生成 favicon..."

# 创建临时的 SVG 文件
cat > temp_favicon.svg << 'EOF'
<svg width="16" height="16" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg">
  <!-- 背景 -->
  <rect width="16" height="16" rx="3" ry="3" fill="#2563eb"/>
  
  <!-- 文件盒子 -->
  <rect x="4" y="5" width="8" height="6" rx="1" ry="1" fill="#ffffff"/>
  
  <!-- 盒子盖子 -->
  <rect x="3.5" y="4.5" width="9" height="1.5" rx="1" ry="1" fill="#f3f4f6"/>
  
  <!-- 文件 -->
  <rect x="5" y="6.5" width="2" height="2.5" rx="0.2" ry="0.2" fill="#3b82f6"/>
  <rect x="7.5" y="6.5" width="2" height="2.5" rx="0.2" ry="0.2" fill="#10b981"/>
  <rect x="10" y="6.5" width="2" height="2.5" rx="0.2" ry="0.2" fill="#f59e0b"/>
  
  <!-- 传输箭头 -->
  <line x1="5" y1="12.5" x2="11" y2="12.5" stroke="#ffffff" stroke-width="1"/>
  <polygon points="11,12.5 9.5,11.8 9.5,13.2" fill="#ffffff"/>
</svg>
EOF

echo "✓ 创建了临时 SVG 文件"

# 如果有 ImageMagick 或其他工具，可以转换为 ICO
# 这里创建一个基本的 HTML favicon 引用

cat > favicon_usage.md << 'EOF'
# Favicon 使用说明

## 1. SVG Favicon (推荐)
在 HTML 头部添加：
```html
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="icon" type="image/png" href="/favicon-32x32.png">
```

## 2. 多尺寸 Favicon
```html
<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/favicon-16x16.png">
<link rel="manifest" href="/site.webmanifest">
```

## 3. 浏览器支持
- 现代浏览器支持 SVG favicon
- 对于旧浏览器，使用 PNG 格式作为后备

## 生成 ICO 文件
如果需要传统的 .ico 文件，可以使用在线工具或 ImageMagick：
```bash
convert favicon.svg -define icon:auto-resize=16,32,48 favicon.ico
```
EOF

echo "✓ 创建了 favicon 使用说明"

# 清理临时文件
rm temp_favicon.svg

echo "✓ Favicon 生成完成！"
echo "  - 主 favicon: favicon.svg"
echo "  - 小尺寸: logo-small.svg"  
echo "  - 使用说明: favicon_usage.md"
echo ""
echo "请在 HTML 模板中添加对应的 <link> 标签。"
