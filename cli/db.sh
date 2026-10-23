# shellcheck shell=bash
# 由 dp 引入，用到 dp 里的公共函数和 DP_HOME、DP_ROOT

DB_KEEP_FULL=5
DB_KEEP_BEFORE_DAYS=30

# 复制出去的目录名写成 PostgreSQL、MariaDB…，和机器上已有的实例目录一致；类型名和仓库里的 databases/ 子目录一致
db_dir() {
	case $1 in
	postgres) echo "$DP_ROOT/PostgreSQL" ;;
	mariadb) echo "$DP_ROOT/MariaDB" ;;
	mysql) echo "$DP_ROOT/MySQL" ;;
	valkey) echo "$DP_ROOT/Valkey" ;;
	*) die "数据库类型只能是 postgres、mariadb、mysql、valkey" ;;
	esac
}

db_require() {
	local dir
	dir=$(db_dir "$1")
	[ -f "$dir/compose.yaml" ] || die "$dir 还没建，先 dp db new $1"
	echo "$dir"
}

db_new() {
	local type=$1 dir volume
	dir=$(db_dir "$type")
	[ ! -e "$dir" ] || die "$dir 已存在"
	volume=$type-data
	# 卷里已有数据时，库按卷里的旧密码运行，新生成的 .env 密码对不上
	if docker volume inspect "$volume" >/dev/null 2>&1; then
		die "数据卷 $volume 已存在。要接着用就把原来的 .env 放进 ${dir}；确定不要旧数据就先自己 docker volume rm $volume"
	fi
	cp -R "$DP_HOME/databases/$type" "$dir"
	rm -rf "${dir:?}/backups"
	mkdir -p "$dir/backups"
	# 十六进制密码不含 / + =，拼进连接串不用转义
	awk -v cmd="openssl rand -hex 24" '
		/^[A-Z_]*PASSWORD=/ { cmd | getline pw; close(cmd); sub(/=.*/, "=" pw) }
		{ print }' "$dir/.env.example" > "$dir/.env"
	chmod 600 "$dir/.env"
	ensure_shared "$dir"
	docker volume create "$volume" >/dev/null
	(cd "$dir" && docker compose up -d --wait)
	echo "已在 $dir 启动，密码在 $dir/.env"
}

db_script() {
	local type=$1 script=$2 dir
	shift 2
	dir=$(db_require "$type")
	[ -x "$dir/$script" ] || die "$type 没有 $script"
	"$dir/$script" "$@"
}

# 没在运行的实例临时启动，备份完再停掉；备份后清理旧文件：
# all_databases_* 留最新 DB_KEEP_FULL 份，名字带 before- 的快照留 DB_KEEP_BEFORE_DAYS 天，其他文件不动
db_backup_one() {
	local type=$1 db=${2:-} dir
	dir=$(db_require "$type")
	[ -x "$dir/backup.sh" ] || die "$type 没有 backup.sh"
	cd "$dir" || exit
	if [ -z "$(docker compose ps --status running --quiet)" ]; then
		echo "未运行，临时启动，备份完再停掉"
		trap 'docker compose stop' EXIT
		docker compose up -d --wait
	fi
	./backup.sh ${db:+"$db"}
	# 文件名里的时间戳按字典序就是时间顺序
	find backups -maxdepth 1 -name 'all_databases_*.sql.gz' | sort -r | tail -n +$((DB_KEEP_FULL + 1)) |
		while read -r f; do
			echo "删除 $f"
			rm -f "$f"
		done
	# 按修改时间算，文件被复制过时间会重置
	find backups -mindepth 1 -maxdepth 1 -name '*before-*' -mtime +"$DB_KEEP_BEFORE_DAYS" \
		-exec echo "删除 {}" \; -exec rm -rf {} +
	du -sh backups
}

db_backup() {
	local target=${1:-} type types=""
	[ -n "$target" ] || die "用法: dp db backup <类型>|all [库名]"
	if [ "$target" != all ]; then
		db_backup_one "$@"
		return
	fi
	[ $# -eq 1 ] || die "备份全部时不能指定库名"
	# Valkey 没有 backup.sh，不在其中
	for type in postgres mariadb mysql; do
		if [ -f "$(db_dir "$type")/compose.yaml" ]; then types="$types $type"; fi
	done
	[ -n "$types" ] || die "$DP_ROOT 下还没有数据库"
	# shellcheck disable=SC2086
	run_each db_backup_one $types
}

db_restore() {
	local type=${1:-} file=${2:-} dir
	[ $# -ge 2 ] || die "用法: dp db restore <类型> <备份文件> [库名]"
	dir=$(db_require "$type")
	# 文件名可以只写 backups/ 下的名字
	if [ ! -f "$file" ] && [ -f "$dir/backups/$file" ]; then
		file=$dir/backups/$file
	fi
	[ -f "$file" ] || die "找不到 $file"
	file=$(cd "$(dirname "$file")" && pwd)/$(basename "$file")
	shift 2
	db_script "$type" restore.sh "$file" "$@"
}

cmd_db() {
	local sub=${1:-}
	[ $# -eq 0 ] || shift
	case $sub in
	new)
		[ $# -eq 1 ] || die "用法: dp db new <类型>"
		db_new "$1"
		;;
	create)
		[ $# -ge 3 ] || die "用法: dp db create <类型> <库名> <用户名> [密码]"
		local type=$1
		shift
		db_script "$type" create-db.sh "$@"
		;;
	drop)
		[ $# -ge 2 ] || die "用法: dp db drop <类型> <库名> [用户名]"
		local type=$1
		shift
		db_script "$type" delete-db.sh "$@"
		;;
	users)
		[ $# -ge 1 ] || die "用法: dp db users <类型> [用户名]"
		local type=$1
		shift
		db_script "$type" check-user.sh "$@"
		;;
	backup) db_backup "$@" ;;
	restore) db_restore "$@" ;;
	*) die "用法: dp db new|create|drop|users|backup|restore ...，见 dp help" ;;
	esac
}
