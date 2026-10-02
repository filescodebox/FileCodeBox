#!/bin/bash
# 拉齐/更新 FileCodeBox 工作区的四个模块仓库。
# 幂等:已存在则 git pull --ff-only。
set -e
cd "$(dirname "$0")/.."

clone_or_update() {
  local repo=$1 dir=$2 branch=$3
  if [ -d "$dir/.git" ]; then
    echo "⟳ 更新 $dir"
    git -C "$dir" pull --ff-only
  else
    echo "↓ 克隆 $repo → $dir"
    git clone -b "$branch" "https://github.com/filescodebox/$repo.git" "$dir"
  fi
}

clone_or_update contracts contracts main
clone_or_update core        core        main
clone_or_update server      server      main
clone_or_update frontend    frontend    main

# 可选:飞牛 fnOS 应用适配层(默认跳过,SETUP_FNOS=1 启用)
if [ "${SETUP_FNOS:-0}" = "1" ]; then
  clone_or_update filecodebox-fnos filecodebox-fnos master
fi

echo "✓ 工作区就绪:$(ls -d */ 2>/dev/null | tr -d '/' | tr '\n' ' ')"
