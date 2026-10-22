#!/usr/bin/env bash
# 本机运行：把 deploy/ 目录在某个提交时的内容传到服务器的 DEPLOY_DIR，拉镜像并启动。首次部署和升级都用它，可重复执行。
#   scripts/deploy.sh            部署当前提交
#   scripts/deploy.sh <提交>     部署或回滚到那个提交的配置
# 服务器和目录读 .env 里的 DEPLOY_HOST（ssh 别名）、DEPLOY_DIR，环境变量优先
set -euo pipefail
cd "$(dirname "$0")/.."

# compose 认 KEY="值" 和 KEY='值'，引号不算值的一部分
env_get() { [ -f .env ] && sed -n "s/^$1=//p" .env | tail -1 | sed -E "s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/"; }
HOST=${DEPLOY_HOST:-$(env_get DEPLOY_HOST || true)}
DIR=${DEPLOY_DIR:-$(env_get DEPLOY_DIR || true)}
REV=${1:-HEAD}
if [ -z "$HOST" ] || [ -z "$DIR" ]; then
	echo "在 .env 里填 DEPLOY_HOST 和 DEPLOY_DIR" >&2
	exit 1
fi

# 上传的是提交里的内容，未提交的改动不会生效，先拦下免得以为改了
if [ "$REV" = HEAD ] && [ -n "$(git status --porcelain -- deploy)" ]; then
	echo "deploy/ 下有未提交的改动，提交后再部署：" >&2
	git status --short -- deploy >&2
	exit 1
fi
SHORT=$(git rev-parse --short "${REV}^{commit}")
echo "部署 ${SHORT} 到 ${HOST}:${DIR}"

# 第一次要 sudo 建目录，-t 让 sudo 能问密码
ssh -t "$HOST" "[ -d '$DIR' ] || { sudo mkdir -p '$DIR' && sudo chown \$(id -un): '$DIR'; }"

# 只覆盖不删除：deploy/ 里删掉的文件会留在服务器上，要手动删；不在远端批量删，免得 DEPLOY_DIR 填错时删错目录
git archive "$REV" deploy | ssh "$HOST" "tar -x -C '$DIR' --strip-components=1"

# DIR、SHORT 要在本机展开后再送过去
# shellcheck disable=SC2087
ssh "$HOST" "bash -s" <<REMOTE
set -euo pipefail
cd '$DIR'
[ -f .env ] || { echo "服务器上没有 $DIR/.env，照 .env.example 建好再部署" >&2; exit 1; }
docker compose pull
if ! docker compose up -d --wait --remove-orphans; then
	docker compose ps -a >&2
	echo "启动失败，回滚：scripts/deploy.sh <上一个提交>，正在跑的版本见 $DIR/REVISION" >&2
	exit 1
fi
docker image prune -f >/dev/null
# 启动成功才记，失败时 REVISION 仍是正在跑的那版
echo $SHORT > REVISION
docker compose ps
REMOTE

echo "部署完成：${SHORT}"
