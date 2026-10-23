# shellcheck shell=bash
# 由 dp 引入，用到 dp 里的公共函数和 DP_HOME、DP_ROOT

# compose 项目名只允许小写字母、数字、- 和 _，且以字母或数字开头
compose_name() {
	local name
	name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/^[^a-z0-9]*//')
	[ -n "$name" ] || die "目录名 $1 转不成 compose 项目名"
	echo "$name"
}

# 照 .env.example 写 .env，只改项目名；已有 .env 不动
write_env() {
	local dir=$1 name=$2
	[ ! -f "$dir/.env" ] || return 0
	if [ -f "$dir/.env.example" ]; then
		sed "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=$(compose_name "$name")/" "$dir/.env.example" > "$dir/.env"
	else
		echo "COMPOSE_PROJECT_NAME=$(compose_name "$name")" > "$dir/.env"
	fi
}

new_target() {
	local dir=$DP_ROOT/$1
	# write_env 里的 compose_name 在 $(...) 里，die 只退出子 shell；建目录之前在这里先拦下
	compose_name "$1" >/dev/null
	if [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
		die "$dir 已存在且不为空"
	fi
	echo "$dir"
}

cmd_new() {
	local kind=${1:-} name=${2:-} astro="" module="" dir
	[ $# -ge 2 ] || die "用法: dp new node|go <名字> [--astro [模板]] [--module <模块路径>]"
	shift 2
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
			[ $# -gt 1 ] || die "--module 后面要写模块路径"
			module=$2
			shift
			;;
		*) die "不认识的参数 $1" ;;
		esac
		shift
	done
	case $kind in
	node) [ -z "$module" ] || die "--module 只用于 go" ;;
	go) [ -z "$astro" ] || die "--astro 只用于 node" ;;
	*) die "类型只能是 node 或 go" ;;
	esac

	dir=$(new_target "$name")
	mkdir -p "$dir"
	cp -R "$DP_HOME/templates/$kind/." "$dir/"
	mkdir -p "$dir/app"
	write_env "$dir" "$name"
	ensure_shared "$dir"
	cd "$dir" || exit

	if [ "$kind" = node ]; then
		if [ -n "$astro" ]; then
			# /app/node_modules 是挂载点，脚手架会把 /app 当成非空目录拒绝，先生成到临时目录再拷进来
			docker compose run --rm --no-deps app sh -c "pnpm create astro@latest /tmp/site --template '$astro' --no-install --no-git --yes >/dev/null && cp -a /tmp/site/. /app/ && rm -rf /tmp/site"
		else
			# pnpm init 默认把仓库里最新的 pnpm 钉进 devEngines，刚发布的版本之后每条命令都要下载，
			# 会被 minimumReleaseAge 拦下；版本由下一行按镜像里的写
			docker compose run --rm --no-deps app pnpm init --no-init-package-manager >/dev/null
		fi
		# 写上镜像里 pnpm 的版本，之后由 Dependabot 跟新版本
		docker compose run --rm --no-deps app sh -c 'pnpm pkg set packageManager="pnpm@$(pnpm --version)"'
		if [ -z "$astro" ]; then
			echo "已创建 ${dir}。在 app/package.json 里加好 dev 脚本后运行 dp up"
			return
		fi
		# 脚手架常写入刚发布几天的版本，被 pnpm-workspace.yaml 的 minimumReleaseAge 拦下。
		# 容器启动时的安装没有终端，没法确认；这里在终端里先装一次，由人决定放不放行
		docker compose run --rm --no-deps app pnpm install
	else
		# CUSTOM: Go 没有「发布满几天才用」的设置，@latest 会取到刚发布的版本；
		# 和 pnpm 的 minimumReleaseAge 一样只取满 3 天的，之后由 Dependabot 按冷却期更新
		docker compose run --rm --no-deps -T app sh -s -- "${module:-$name}" <<-'EOF'
			set -e
			go mod init "$1"
			cutoff=$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)
			# go list 的版本已按语义版本从小到大排好，倒过来从最新的试；带 - 的是预发布版，跳过
			for v in $(go list -m -versions github.com/air-verse/air | tr ' ' '\n' | tail -n +2 | grep -v -- - | tac); do
				t=$(go list -m -f '{{.Time.UTC.Format "2006-01-02T15:04:05Z"}}' "github.com/air-verse/air@$v")
				if [ "$t" \< "$cutoff" ]; then
					go get -tool "github.com/air-verse/air@$v"
					exit 0
				fi
			done
			echo "air 没有发布满 3 天的版本" >&2
			exit 1
		EOF
	fi

	docker compose up -d
	echo "已创建 ${dir}，访问 https://$(compose_name "$name").orb.local"
}

cmd_copy() {
	local from=${1:-} name=${2:-} src dir
	[ $# -eq 2 ] || die "用法: dp copy <已有项目> <新名字>"
	src=$DP_ROOT/$from
	is_project "$src" || die "$src 不是项目"
	git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || die "$src 不是 git 仓库，没法区分源码和依赖、密钥"
	dir=$(new_target "$name")
	mkdir -p "$dir"
	# 只拷进了 git 的和没被忽略的新文件：node_modules、构建产物、.env 这类都在 .gitignore 里，不会带过去
	# 删掉还没提交的文件 git 照样列出，tar 找不到会中断，先滤掉
	(cd "$src" && git ls-files -z -co --exclude-standard |
		while IFS= read -r -d '' f; do if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\0' "$f"; fi; done |
		tar --null -T - -cf -) | tar -xf - -C "$dir"
	write_env "$dir" "$name"
	ensure_shared "$dir"
	(cd "$dir" && docker compose up -d)
	echo "已从 $from 复制出 ${dir}。.env 和 app/.env 这类密钥文件没有复制；package.json 等文件里的项目名要自己改"
}

cmd_clone() {
	local url=${1:-} name=${2:-} dir
	[ -n "$url" ] || die "用法: dp clone <git 地址> [名字]"
	[ -n "$name" ] || name=$(basename "$url" .git)
	dir=$(new_target "$name")
	git clone "$url" "$dir"
	write_env "$dir" "$name"
	ensure_shared "$dir"
	(cd "$dir" && docker compose up -d)
	echo "已克隆到 ${dir}。app/.env 这类不进 git 的密钥文件要另外拷过来"
}

# 起不来的服务会一直自动重启，等下次重启时健康状态停在 unhealthy；改好以后 compose 配置没变，
# up 不会动它，--wait 读到旧状态就报失败。先重启这些服务，健康检查从头算。
# 只认 restarting：在运行、只是暂时不健康的（比如负载高的数据库）不去打断
restart_crashed() {
	local bad
	bad=$(docker compose ps --status restarting --services | sort -u)
	# shellcheck disable=SC2086
	[ -z "$bad" ] || docker compose restart --no-deps $bad
}

# --wait：有健康检查的服务（开发容器、数据库）等到通过才算成功，起不来时报失败
compose_up() {
	ensure_shared
	restart_crashed
	docker compose up -d --wait
}
compose_down() { docker compose down; }
compose_restart() { docker compose restart; }
compose_status() { docker compose ps -a; }
# 基础镜像写的是浮动标签，build 要加 --pull 才会去拿新版本；本地构建的镜像不去仓库拉
compose_update() {
	docker compose pull --ignore-buildable
	docker compose build --pull
	ensure_shared
	restart_crashed
	docker compose up -d --wait
}

run_compose() { cd "$DP_ROOT/$1" && "compose_$DP_ACTION"; }

cmd_compose() {
	local action=$1 targets
	shift
	targets=$(resolve_targets "${1:-}")
	if [ "$action" = status ] && [ "${1:-}" = all ]; then
		docker compose ls -a
		return
	fi
	# shellcheck disable=SC2086
	set -- $targets
	[ "$action" = status ] || confirm_targets "$@"
	DP_ACTION=$action run_each run_compose "$@"
}

cmd_logs() {
	local name
	[ "${1:-}" != all ] || die "logs 一次只看一个项目，写上项目名"
	if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
		name=$(resolve_targets "$1")
		shift
	else
		name=$(resolve_targets "")
	fi
	cd "$DP_ROOT/$name" || exit
	if [ $# -eq 0 ]; then
		docker compose logs -f --tail 100
	else
		docker compose logs "$@"
	fi
}
