#!/usr/bin/env bash
# 用法:
#   new-project.sh                                         不带参数，逐项问
#   new-project.sh node <目录> [--astro [模板名]] [--access domain|port] [--port N]
#   new-project.sh go   <目录> [--module <模块路径>] [--access domain|port] [--port N]
set -euo pipefail

usage() {
	sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

ask() {
	# ask <变量名> <提示> [默认值]
	local __var=$1 __prompt=$2 __default=${3:-} __answer
	if [ -n "$__default" ]; then
		read -r -p "$__prompt [$__default]: " __answer
		__answer=${__answer:-$__default}
	else
		read -r -p "$__prompt: " __answer
	fi
	printf -v "$__var" '%s' "$__answer"
}

orbstack=""
if [ "$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)" = OrbStack ]; then
	orbstack=1
fi
default_access=port
[ -z "$orbstack" ] || default_access=domain

kind=${1:-}
target=${2:-}
if [ $# -ge 2 ]; then shift 2; else set --; fi

astro=""
module=""
access=""
port=""
while [ $# -gt 0 ]; do
	case $1 in
	--astro)
		astro=minimal
		if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then
			astro=$2
			shift
		fi
		;;
	--module)
		[ $# -gt 1 ] || usage
		module=$2
		shift
		;;
	--access)
		[ $# -gt 1 ] || usage
		access=$2
		shift
		;;
	--port)
		[ $# -gt 1 ] || usage
		port=$2
		shift
		;;
	*) usage ;;
	esac
	shift
done

if [ -z "$kind" ]; then
	ask kind "项目类型 (node/go)" node
	ask target "项目目录"
	case $kind in
	node)
		ask yn "在容器里生成 Astro 项目? (y/N)" N
		if [ "$yn" = y ] || [ "$yn" = Y ]; then
			ask astro "Astro 模板名" minimal
		fi
		;;
	go)
		ask module "Go 模块路径（留空则不 go mod init）"
		;;
	esac
	ask access "访问方式 (domain: OrbStack 域名 / port: localhost 加端口)" "$default_access"
	if [ "$access" = port ]; then
		case $kind in
		node) ask port "宿主机端口" 4321 ;;
		go) ask port "宿主机端口" 8080 ;;
		esac
	fi
fi

if [ -z "$access" ]; then
	if [ -n "$port" ]; then access=port; else access=$default_access; fi
fi

case $kind in
node | go) ;;
*) usage ;;
esac
[ -n "$target" ] || usage
[ -z "$astro" ] || [ "$kind" = node ] || { echo "--astro 只用于 node" >&2; exit 1; }
[ -z "$module" ] || [ "$kind" = go ] || { echo "--module 只用于 go" >&2; exit 1; }
case $access in
domain | port) ;;
*) usage ;;
esac
[ -z "$port" ] || [ "$access" = port ] || { echo "--port 只用于 --access port" >&2; exit 1; }
[ "$access" = port ] || [ -n "$orbstack" ] || echo "当前 Docker 不是 OrbStack，<项目名>.orb.local 域名访问不到" >&2

root=$(cd "$(dirname "$0")" && pwd)
template="$root/templates/$kind"

if [ -e "$target" ] && [ -n "$(ls -A "$target")" ]; then
	echo "目录已存在且不为空: $target" >&2
	exit 1
fi
mkdir -p "$target"
target=$(cd "$target" && pwd)

# compose 项目名只允许小写字母、数字、- 和 _，且以字母或数字开头
name=$(basename "$target" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/^[^a-z0-9]*//')
[ -n "$name" ] || { echo "目录名无法转成 compose 项目名: $(basename "$target")" >&2; exit 1; }

cp -R "$template/." "$target/"
mkdir -p "$target/app"

{
	echo "COMPOSE_PROJECT_NAME=$name"
	echo "TZ=Asia/Tokyo"
	if [ "$access" = port ]; then
		echo "COMPOSE_FILE=compose.yaml:compose.ports.yaml"
		[ -z "$port" ] || echo "APP_PORT=$port"
	fi
	# 只有 Linux 上容器 uid 和宿主机不一致才真的冲突；Mac 的文件共享层会自动映射
	if [ "$(uname)" = Linux ] && { [ "$(id -u)" != 1000 ] || [ "$(id -g)" != 1000 ]; }; then
		echo "PUID=$(id -u)"
		echo "PGID=$(id -g)"
	fi
} > "$target/.env"

cd "$target"
# 网络是 external，compose 不会自己建
docker network inspect docker-net >/dev/null 2>&1 || docker network create docker-net >/dev/null
docker compose up -d

if [ -n "$astro" ]; then
	# /app/node_modules 已是挂载点，脚手架会把 /app 当非空目录拒绝，先生成到临时目录再拷进来
	docker compose exec app sh -c "pnpm create astro@latest /tmp/site --template '$astro' --no-install --no-git --yes >/dev/null && cp -a /tmp/site/. /app/ && rm -rf /tmp/site"
	mv pnpm-workspace.yaml app/
	docker compose exec app sh -c 'pnpm pkg set packageManager="pnpm@$(pnpm --version)"'
	docker compose exec app pnpm install
fi

if [ -n "$module" ]; then
	docker compose exec app go mod init "$module"
fi

echo
# bash 3.2 会把紧跟在变量名后的全角括号算进变量名，必须加花括号
echo "已创建 ${target}（compose 项目 ${name}）"
if [ "$access" = domain ]; then
	url="https://${name}.orb.local"
else
	case $kind in
	node) url="http://localhost:${port:-4321}" ;;
	go) url="http://localhost:${port:-8080}" ;;
	esac
fi
echo "  访问地址 ${url}（开发服务器启动后）"
case $kind in
node)
	if [ -n "$astro" ]; then
		echo "  docker compose exec app pnpm dev --host"
	else
		echo "  在容器里初始化项目后，把 pnpm-workspace.yaml 移到 app/ 下，见 README.md"
	fi
	;;
go)
	[ -n "$module" ] || echo "  docker compose exec app go mod init <模块路径>"
	echo "  docker compose exec app go get -tool github.com/air-verse/air@latest"
	;;
esac
