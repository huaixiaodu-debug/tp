#!/bin/sh
# 用法: sh deploy.sh 你的用户名/仓库名
# 前提：仓库已创建，Deploy Key 已添加且勾选 Allow write access
set -e
cd "$(dirname "$0")"

REPO="$1"
if [ -z "$REPO" ]; then echo "用法: sh deploy.sh 用户名/仓库名"; exit 1; fi

git init -b main 2>/dev/null || true
git config user.email "deploy@local"
git config user.name "ninebot-cast"
git add -A
git commit -m "NinebotCast: ReplayKit 录屏 → H.264 Annex-B → 九号仪表 UDP 推流" || echo "(无变更)"
git remote remove origin 2>/dev/null || true
git remote add origin "git@github-dc:${REPO}.git"
git push -u origin main
echo "推送完成。去 GitHub 仓库的 Actions 页看构建进度。"
