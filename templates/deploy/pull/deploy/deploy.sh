#!/usr/bin/env bash
# 服务器上运行：./deploy.sh 发布 git pull 之后的最新提交；./deploy.sh <完整提交号> 发布或回滚到那个版本。
# 镜像由 CI 按提交号推到 ghcr，CI 还没跑完时拉取会失败，旧版本继续运行
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "先 cp .env.example .env 并填好再发布" >&2; exit 1; }

git pull --ff-only
SHA=${1:-$(git rev-parse HEAD)}
PREV=$(sed -n 's/^IMAGE_TAG=//p' .env | tail -1)
echo "IMAGE_TAG: ${PREV:-无} -> ${SHA}"

# 环境变量优先于 .env：先用新版本拉取、启动，都成功了才写进 .env，失败时 .env 还是正在跑的版本
export IMAGE_TAG=$SHA
docker compose pull
if ! docker compose up -d --wait --remove-orphans; then
	docker compose ps -a >&2
	# up 失败时容器已经换成了新版本，要用原来的提交号再起一次
	if [ -z "$PREV" ]; then
		echo "启动失败" >&2
	elif IMAGE_TAG=$PREV docker compose up -d --wait --remove-orphans; then
		echo "启动失败，已退回 ${PREV}" >&2
	else
		echo "启动失败，退回 ${PREV} 也没起来，看 docker compose logs" >&2
	fi
	exit 1
fi
# cat 写回而不是 mv，.env 的属主和权限保持不变
tmp=$(mktemp)
awk -v tag="$SHA" '!/^IMAGE_TAG=/ { print } END { print "IMAGE_TAG=" tag }' .env > "$tmp"
cat "$tmp" > .env
rm -f "$tmp"

# 本项目的镜像只留当前和上一版；更早的版本 ghcr 上按提交号保留，要用时再拉
for repo in $(docker compose config --images | grep ":${SHA}$" | sed "s/:${SHA}$//" | sort -u); do
	for img in $(docker images "$repo" --format '{{.Repository}}:{{.Tag}}'); do
		case ${img##*:} in
		"$SHA" | "$PREV") ;;
		*) docker rmi "$img" >/dev/null 2>&1 || true ;;
		esac
	done
done
docker image prune -f >/dev/null

echo "发布完成：${SHA}${PREV:+（回滚：./deploy.sh ${PREV}）}"
