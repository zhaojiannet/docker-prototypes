#!/usr/bin/env bash
# 端到端测试：把 dp 的命令在真的 Docker 上跑一遍。只在 CI 或一次性的虚拟机里跑：
# 模板里数据库的容器名、数据卷名和共用缓存卷的名字是固定的，日常用的 Docker 上会碰到真实的库和缓存。
#   tests/e2e.sh                     在本机 Docker 上跑（CI、虚拟机里），dp 在 bash 3.2 的容器里运行
#   E2E_MACHINE=dp-e2e tests/e2e.sh  在 Mac 上跑：dp 用本机的 bash 和 BSD 工具，Docker 用这台 OrbStack 虚拟机里的
#   tests/e2e.sh db remote           只跑这几组，组名见 tests/cases.sh 末尾
#   E2E_KEEP=1 tests/e2e.sh          跑完不清理，留着查问题
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
FIXED_VOLUMES="pnpm go-mod go-build postgres-data mariadb-data mysql-data valkey-data dp-e2e-srv"
FIXED_CONTAINERS="postgres mariadb mysql valkey"

if [ -n "${E2E_MACHINE:-}" ]; then
	# 项目目录要在 Mac 和虚拟机里是同一个路径：compose 的 bind mount 由虚拟机里的 Docker 解析，
	# OrbStack 把 /Users 原样挂进虚拟机，/tmp 不挂
	WORK=${E2E_WORK:-$REPO/tests/.work/run}
	# Docker 自带的 ssh 方式（远端跑 docker system dial-stdio）；用 ssh -L 转发 socket 时容器的输出传不回来。
	# 虚拟机里的默认用户要在 docker 组里
	export DOCKER_HOST=ssh://${E2E_MACHINE}@orb
	docker info >/dev/null || { echo "连不上虚拟机 ${E2E_MACHINE} 的 Docker" >&2; exit 2; }
	SSH_HOST=${E2E_MACHINE}.orb.local
	SSH_PORT=2222
	SERVER_PUBLISH="-p 2222:22"
else
	# 同上，项目目录在宿主和测试容器里路径要一致
	WORK=${E2E_WORK:-/tmp/dp-e2e}
	SSH_HOST=dp-e2e-server
	SSH_PORT=22
	SERVER_PUBLISH=""
fi

for v in $FIXED_VOLUMES; do
	if docker volume inspect "$v" >/dev/null 2>&1; then
		echo "这台 Docker 上已有数据卷 ${v}，像是日常在用的环境，不在这里跑。用 CI 或一次性的虚拟机" >&2
		exit 2
	fi
done
for c in $FIXED_CONTAINERS; do
	if docker container inspect "$c" >/dev/null 2>&1; then
		echo "这台 Docker 上已有容器 ${c}，不在这里跑" >&2
		exit 2
	fi
done

# 测试里的文件有 root 的（Go 开发容器以 root 运行），宿主用户删不掉，交给容器删
wipe_work() {
	docker run --rm -v "$(dirname "$WORK"):/p" alpine:3.24 rm -rf "/p/$(basename "$WORK")"
}

# 上面确认过这些固定名字原先都不存在，所以收尾时可以放心删
cleanup() {
	set +e
	docker ps -aq --filter label=com.docker.compose.project.working_dir | while read -r id; do
		case $(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id") in
		"$WORK"/* | /srv/*) docker rm -f -v "$id" >/dev/null ;;
		esac
	done
	# shellcheck disable=SC2086
	docker rm -f -v dp-e2e-server dp-e2e-registry dp-e2e-curl dp-e2e-static $FIXED_CONTAINERS >/dev/null 2>&1
	# shellcheck disable=SC2086
	docker volume rm $FIXED_VOLUMES >/dev/null 2>&1
	docker volume ls -q | grep -E '^(web|web2|web3|api|pushapp)_' | xargs -r docker volume rm >/dev/null 2>&1
	wipe_work
	docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^(e2e-|127\.0\.0\.1:5000/|web|api|pushapp|dp-e2e-)' | xargs -r docker rmi -f >/dev/null 2>&1
}
[ -n "${E2E_KEEP:-}" ] || trap cleanup EXIT

docker network inspect docker-net >/dev/null 2>&1 || docker network create docker-net >/dev/null
docker build -q -t dp-e2e-runner -f tests/runner.Dockerfile tests >/dev/null
docker build -q -t dp-e2e-server -f tests/server.Dockerfile tests >/dev/null

# 测试以 uid 1000 运行：Node 开发容器的用户是 1000，Linux 上它写不进别的用户建的目录（macOS 上 OrbStack 会自动处理属主）
wipe_work
docker run --rm -v "$(dirname "$WORK"):/p" alpine:3.24 sh -c \
	"mkdir -p /p/$(basename "$WORK")/projects /p/$(basename "$WORK")/home && chown -R 1000:1000 /p/$(basename "$WORK")"
SOCK_GID=$(docker run --rm -v /var/run/docker.sock:/s alpine:3.24 stat -c %g /s)
run_as_tester() {
	docker run --rm --network docker-net --user 1000:1000 --group-add "$SOCK_GID" \
		-v /var/run/docker.sock:/var/run/docker.sock -v "$REPO:$REPO" -v "$WORK:$WORK" \
		-v "$WORK/home:/home/tester" -e HOME=/home/tester -e WORK="$WORK" -e DP_ROOT="$WORK/projects" \
		-e E2E_SSH_HOST="$SSH_HOST" -e E2E_SSH_PORT="$SSH_PORT" -w "$REPO" \
		"$@"
}

run_as_tester dp-e2e-runner ssh-keygen -q -t ed25519 -N "" -f "$WORK/home/id_ed25519"
docker run -d --name dp-e2e-registry -p 127.0.0.1:5000:5000 registry:3 >/dev/null
# shellcheck disable=SC2086
docker run -d --name dp-e2e-server --network docker-net $SERVER_PUBLISH \
	-v /var/run/docker.sock:/var/run/docker.sock -v "$WORK:$WORK" -v dp-e2e-srv:/srv dp-e2e-server >/dev/null
docker exec dp-e2e-server sh -c "cp '$WORK/home/id_ed25519.pub' /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
# 开发服务器、生产镜像的地址只在 docker-net 里解析得到，访问都从这个容器发出
docker run -d --name dp-e2e-curl --network docker-net dp-e2e-runner sleep infinity >/dev/null

if [ -n "${E2E_MACHINE:-}" ]; then
	# 不改 HOME：Docker CLI 的插件（compose）在 ~/.docker 下
	export WORK DP_ROOT=$WORK/projects E2E_SSH_HOST=$SSH_HOST E2E_SSH_PORT=$SSH_PORT
	/bin/bash tests/cases.sh "$@"
else
	run_as_tester dp-e2e-runner bash tests/cases.sh "$@"
fi
