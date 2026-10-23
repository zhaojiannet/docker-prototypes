#!/usr/bin/env bash
# 本机运行：构建静态产物，rsync 到服务器的 DEPLOY_DIR/releases/<提交号>，再把 DEPLOY_DIR/current 指过去。
#   scripts/deploy.sh            构建当前提交并发布
#   scripts/deploy.sh <提交>     把 current 切回服务器上已有的那一版（回滚），不重新构建
# 服务器和目录读 .env 里的 DEPLOY_HOST（ssh 别名）、DEPLOY_DIR，环境变量优先；产物目录不是 dist 时写 OUTPUT_DIR
set -euo pipefail
cd "$(dirname "$0")/.."

# 服务器上留几版，回滚只能回到这几版里
KEEP=5

# compose 认 KEY="值" 和 KEY='值'，引号不算值的一部分
env_get() {
	[ -f .env ] || return 0
	sed -n "s/^$1=//p" .env | tail -1 | sed -E "s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/"
}
die() {
	echo "$*" >&2
	exit 1
}
HOST=${DEPLOY_HOST:-$(env_get DEPLOY_HOST)}
DIR=${DEPLOY_DIR:-$(env_get DEPLOY_DIR)}
OUTPUT_DIR=${OUTPUT_DIR:-$(env_get OUTPUT_DIR)}
[ -n "$HOST" ] && [ -n "$DIR" ] || die "在 .env 里填 DEPLOY_HOST 和 DEPLOY_DIR"
# DIR 会拼进远端命令
case $DIR in
/*[!0-9A-Za-z._/-]* | /) die "DEPLOY_DIR 只能用字母、数字和 ._/-，也不能是 /" ;;
/*) ;;
*) die "DEPLOY_DIR 要写绝对路径" ;;
esac

# 切换 current：新建软链接再改名盖过去，改名是原子的，访问不会碰上没有 current 的瞬间。
# 软链接写相对路径，反向代理把 DEPLOY_DIR 整个挂进容器时也指得对
switch() {
	ssh "$HOST" "cd '$DIR' && ln -sfn 'releases/$1' current.tmp && mv -Tf current.tmp current && touch 'releases/$1'"
}

if [ $# -gt 0 ]; then
	SHA=$(git rev-parse --verify "${1}^{commit}")
	ssh "$HOST" "[ -d '$DIR/releases/$SHA' ]" || die "服务器上没有 ${SHA:0:7} 这一版，只留了最近 $KEEP 版；要重新发布就先 git checkout 它再运行 scripts/deploy.sh"
	switch "$SHA"
	echo "已切回 ${SHA:0:7}"
	exit 0
fi

# 构建用的是工作区里的文件，有未提交的改动时发布的内容和提交号对不上
if [ -n "$(git status --porcelain -- app Dockerfile .dockerignore)" ]; then
	echo "有未提交的改动，提交后再部署：" >&2
	git status --short -- app Dockerfile .dockerignore >&2
	exit 1
fi
SHA=$(git rev-parse HEAD)
# 同一提交的产物已经在服务器上：再 rsync 会改正在提供访问的目录，直接切过去就行
if ssh "$HOST" "[ -d '$DIR/releases/$SHA' ]"; then
	switch "$SHA"
	echo "服务器上已有 ${SHA:0:7}，已切到这一版"
	exit 0
fi
echo "部署 ${SHA:0:7} 到 ${HOST}:${DIR}"

OUT=$(mktemp -d)
trap 'rm -rf "${OUT:?}"' EXIT
docker build --pull --target files --build-arg OUTPUT_DIR="${OUTPUT_DIR:-dist}" --output "type=local,dest=$OUT" .
[ -n "$(ls -A "$OUT")" ] || die "构建产物是空的，检查 OUTPUT_DIR"

# 第一次要 sudo 建目录，-t 让 sudo 能问密码
ssh -t "$HOST" "[ -d '$DIR' ] || { sudo mkdir -p '$DIR' && sudo chown \$(id -un): '$DIR'; }"
ssh "$HOST" "mkdir -p '$DIR/releases'"
# 没变的文件和上一版共用硬链接，不重传也不多占空间。每次构建产物的修改时间都是新的，
# 所以按内容比（-c）、不带修改时间（不加 -t），否则一个也链不上。
# 权限统一放开读，反向代理换了用户也读得到；在本机改，macOS 自带的 openrsync 处理 --chmod 不可靠
LINK=()
if ssh "$HOST" "[ -d '$DIR/current/' ]"; then
	LINK=(--link-dest="$DIR/current/")
fi
chmod -R u=rwX,go=rX "$OUT"
rsync -rlpc --delete ${LINK[@]+"${LINK[@]}"} "$OUT/" "$HOST:$DIR/releases/$SHA/"
switch "$SHA"

# 按切换时间留最近 KEEP 版，正在用的那版不删；目录名都是提交号，读自 releases/ 本身
ssh "$HOST" "cd '$DIR' && cur=\$(readlink current) && ls -1t releases | tail -n +$((KEEP + 1)) | while read -r r; do [ \"releases/\$r\" = \"\$cur\" ] || rm -rf -- \"releases/\$r\"; done"

echo "部署完成：${SHA:0:7}"
