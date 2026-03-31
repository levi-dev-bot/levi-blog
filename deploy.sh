#!/bin/bash
# Blog 部署脚本
# 使用方法: ./deploy.sh

GITHUB_USER="YOUR_GITHUB_USERNAME"

echo "=== Hexo Blog 部署脚本 ==="

# 检查 GitHub 用户名
if [ "$GITHUB_USER" = "YOUR_GITHUB_USERNAME" ]; then
    echo "请先修改脚本中的 GITHUB_USER 为你的 GitHub 用户名"
    echo "然后运行: git init && git remote add origin https://github.com/$GITHUB_USER/levi-blog.git"
    exit 1
fi

# 初始化 git（如果还没有）
if [ ! -d ".git" ]; then
    git init
    git remote add origin https://github.com/$GITHUB_USER/levi-blog.git
    git checkout -b main
    echo "Git 已初始化"
fi

# 安装依赖
npm install

# 清理并生成
hexo clean
hexo generate

# 部署到 GitHub
hexo deploy

echo "=== 部署完成 ==="
