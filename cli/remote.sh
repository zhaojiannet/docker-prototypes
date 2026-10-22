# shellcheck shell=bash
# 由 dp 引入，用到 dp 里的公共函数和 DP_HOME、DP_ROOT

DP_HOST=""

# 读项目的部署设置到 MODE、HOST、DIR；不是自建服务器部署的项目返回 1
deploy_conf() {
	local env=$DP_ROOT/$1/.env
	MODE=$(env_get "$env" DEPLOY_MODE)
	HOST=$(env_get "$env" DEPLOY_HOST)
	DIR=$(env_get "$env" DEPLOY_DIR)
	[ -n "$MODE" ] || return 1
	case $MODE in pull | push) ;; *) die "$1 的 DEPLOY_MODE 只能是 pull 或 push" ;; esac
	[ -n "$HOST" ] && [ -n "$DIR" ] || die "$1 的 .env 里要同时有 DEPLOY_HOST 和 DEPLOY_DIR"
}

# 解析 [<项目>|all] 和 --host，输出要处理的项目；all 只取写了部署设置的，--host 再按服务器筛
remote_targets() {
	local arg="" name
	while [ $# -gt 0 ]; do
		case $1 in
		--host)
			[ $# -gt 1 ] || die "--host 后面要写 ssh 别名"
			DP_HOST=$2
			shift
			;;
		*)
			[ -z "$arg" ] || die "多余的参数 $1"
			arg=$1
			;;
		esac
		shift
	done
	if [ -z "$arg" ] && [ -n "$DP_HOST" ]; then
		arg=all
	fi
	for name in $(resolve_targets "$arg"); do
		if ! deploy_conf "$name"; then
			[ "$arg" = all ] || die "$name 的 .env 里没有 DEPLOY_MODE，不是部署到自建服务器的项目"
			continue
		fi
		[ -z "$DP_HOST" ] || [ "$HOST" = "$DP_HOST" ] || continue
		echo "$name"
	done
}

# 会拼进远端命令的参数，只放行提交号、标签这类字符
check_arg() {
	case $1 in
	*[!0-9A-Za-z._-]* | -*) die "版本 $1 里有不允许的字符" ;;
	esac
}

deploy_one() {
	local name=$1 version=${DP_VERSION:-}
	deploy_conf "$name"
	echo "${name}：$MODE 模式，${HOST}:${DIR}"
	if [ "$MODE" = pull ]; then
		[ -z "$version" ] || check_arg "$version"
		ssh -t "$HOST" "cd '$DIR' && ./deploy.sh $version"
	else
		# 本机运行，版本照原样交给 git，HEAD~1 这类写法也能用
		cd "$DP_ROOT/$name" || exit
		DEPLOY_HOST=$HOST DEPLOY_DIR=$DIR ./scripts/deploy.sh ${version:+"$version"}
	fi
}

cmd_deploy() {
	local first="" version="" host=() targets
	while [ $# -gt 0 ]; do
		case $1 in
		--host)
			[ $# -gt 1 ] || die "--host 后面要写 ssh 别名"
			host=(--host "$2")
			shift
			;;
		*)
			# 在项目目录里可以只写版本：第一个参数既不是 all 也不是项目名，就当版本
			if [ -z "$first" ] && [ -z "$version" ] && { [ "$1" = all ] || is_project "$DP_ROOT/$1"; }; then
				first=$1
			elif [ -z "$version" ]; then
				version=$1
			else
				die "多余的参数 $1"
			fi
			;;
		esac
		shift
	done
	# bash 3.2 在 set -u 下展开空数组会报未绑定，要用 ${a[@]+...} 的写法
	targets=$(remote_targets "$first" ${host[@]+"${host[@]}"})
	[ -n "$targets" ] || die "没有要部署的项目"
	# shellcheck disable=SC2086
	set -- $targets
	[ -z "$version" ] || [ $# -eq 1 ] || die "指定版本时只能部署一个项目"
	confirm_targets "$@"
	DP_VERSION=$version run_each deploy_one "$@"
}

cmd_rollback() {
	[ $# -eq 2 ] || die "用法: dp rollback <项目> <版本>"
	cmd_deploy "$1" "$2"
}

patch_one() {
	deploy_conf "$1"
	echo "${HOST}:${DIR}"
	ssh "$HOST" "cd '$DIR' && docker compose pull && docker compose up -d --wait --remove-orphans && docker image prune -f >/dev/null && docker compose ps"
}

cmd_patch() {
	local targets
	targets=$(remote_targets "$@")
	[ -n "$targets" ] || die "没有要处理的项目"
	# shellcheck disable=SC2086
	set -- $targets
	confirm_targets "$@"
	run_each patch_one "$@"
}

status_one() {
	ssh "$1" "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"
}

cmd_remote_status() {
	local name hosts=""
	[ $# -eq 0 ] || [ "$1" = --host ] || die "用法: dp remote-status [--host <ssh 别名>]"
	if [ $# -ge 2 ]; then
		hosts=$2
	else
		for name in $(list_projects); do
			if deploy_conf "$name"; then
				case " $hosts " in *" $HOST "*) ;; *) hosts="$hosts $HOST" ;; esac
			fi
		done
	fi
	[ -n "$hosts" ] || die "没有项目在 .env 里写了 DEPLOY_HOST"
	# shellcheck disable=SC2086
	run_each status_one $hosts
}

cmd_backup() {
	local name item="" script dest out path
	if [ $# -gt 0 ] && is_project "$DP_ROOT/$1"; then
		name=$1
		shift
	else
		name=$(resolve_targets "")
	fi
	[ $# -le 1 ] || die "用法: dp backup [<项目>] [备份项]"
	item=${1:-}
	deploy_conf "$name" || die "$name 的 .env 里没有 DEPLOY_MODE，不是部署到自建服务器的项目"
	script=$DP_ROOT/$name/deploy/backup.sh
	[ -f "$script" ] || die "$name 没有 deploy/backup.sh，照 templates/deploy 加上"
	[ -z "$item" ] || check_arg "$item"
	dest=$DP_ROOT/backup/$name
	mkdir -p "$dest"
	chmod 700 "$dest"
	# 本机的脚本经 ssh 送过去执行，服务器上不用事先放好；标准输出只有生成的文件路径
	out=$(ssh "$HOST" "cd '$DIR' && bash -s -- $item" <"$script")
	[ -n "$out" ] || die "backup.sh 没有报告生成的文件"
	while read -r path; do
		case $path in /*) ;; *) path=$DIR/$path ;; esac
		# scp 底下的 ssh 会读标准输入，不挡住就把循环剩下的路径吃掉
		scp -p "$HOST:$path" "$dest/" </dev/null
		echo "已拉回 $dest/$(basename "$path")"
	done <<<"$out"
}
