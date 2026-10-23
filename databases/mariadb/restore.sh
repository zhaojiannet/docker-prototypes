#!/bin/bash
# 从备份恢复，覆盖已有的库之前先把它再备份一份到 backups/
# 用法: ./restore.sh 备份文件 [库名]
#   单库备份（<库名>_<时间>.sql[.gz]）：恢复成同名库，库要已存在（用 create-db.sh 建）
#   整库备份（all_databases_<时间>.sql[.gz]）：整个导入，只用于新实例，实例里已经有别的库时拒绝
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

# 和 mysql/restore.sh 只有下面几行不同，正文保持同一份：GTID 过滤只对 MySQL 的备份起作用，
# 重建 healthcheck 用户只对 MariaDB 起作用，在另一种库上什么也不做
SERVICE=mariadb
CLIENT=mariadb
DUMP=mariadb-dump
ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
DEFAULT_DB=${MARIADB_DATABASE:-default_db}
DUMP_OPTS=(--single-transaction --routines --triggers --events)

USAGE="用法: ./restore.sh 备份文件 [库名]"
FILE=${1:?$USAGE}
DB_NAME=${2:-}
[ -f "$FILE" ] || { echo "找不到 $FILE" >&2; exit 1; }

sql() { docker compose exec -T "$SERVICE" "$CLIENT" -uroot -p"${ROOT_PASSWORD}" "$@"; }
# 单条查询不读标准输入，否则 exec -T 会把后面 confirm 要读的回答吃掉
query() { sql -N -B -e "$1" </dev/null; }
# MySQL 开着 GTID 时备份里会有 SET @@GLOBAL.GTID_PURGED，导回已有 GTID 的实例会报 3546；不做主从复制，去掉即可
read_file() {
	case $FILE in *.gz) gzip -dc "$FILE" ;; *) cat "$FILE" ;; esac |
		awk '/^SET @@GLOBAL.GTID_PURGED/ { skip = 1 } !skip { print } skip && /;$/ { skip = 0 }'
}
db_exists() { [ -n "$(query "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$1'")" ]; }

confirm() {
	read -r -p "$1 确认吗? [y/N] " ans || ans=
	[ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; exit 1; }
}

# 覆盖前的快照，名字带 before- 才会被 dp db backup 按 30 天清理
snapshot() {
	local out
	out="backups/${1}_$(date +%Y%m%d_%H%M%S)_before-restore.sql.gz"
	# 同一秒里第二次恢复同一个库时等到下一秒，不覆盖前一份快照
	while [ -e "$out" ]; do
		sleep 1
		out="backups/${1}_$(date +%Y%m%d_%H%M%S)_before-restore.sql.gz"
	done
	docker compose exec -T "$SERVICE" "$DUMP" -uroot -p"${ROOT_PASSWORD}" "${DUMP_OPTS[@]}" "$1" </dev/null | gzip > "$out"
	echo "已备份当前的 $1 到 $out"
}

base=$(basename "$FILE")
case $base in
all_databases_*)
	# 不从整库备份里切出单个库：存储过程的代码原样导出，里面可以伪造分库的注释行，
	# 切出来的内容会以 root 执行
	[ -z "$DB_NAME" ] || { echo "整库备份只能整个导入新实例；恢复单个库要用单库备份（dp db backup <类型> <库名>）" >&2; exit 1; }
	others=$(query "SELECT GROUP_CONCAT(SCHEMA_NAME SEPARATOR ' ') FROM information_schema.SCHEMATA
		WHERE SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys', '${DEFAULT_DB}')")
	if [ -n "$others" ] && [ "$others" != NULL ]; then
		echo "实例里已经有这些库：${others}。整个导入只用于新实例" >&2
		exit 1
	fi
	confirm "要把 $FILE 整个导入这个实例（含用户和权限，root 密码也会变成备份时的值），"
	read_file | sql
	# 备份里的 healthcheck 用户带着原实例的密码（原实例没有时就缺这几个用户），和本实例数据目录里
	# .my-healthcheck.cnf 的对不上，镜像自带的健康检查会一直失败，所以按 cnf 重建。
	# 要在 FLUSH 之前做：刷新后 root 就换成备份里的密码，.env 里的登不上。MySQL 镜像没有这个文件，跳过
	docker compose exec -T "$SERVICE" sh -s "$CLIENT" "$ROOT_PASSWORD" <<-'EOSH'
		cnf=/var/lib/mysql/.my-healthcheck.cnf
		[ -f "$cnf" ] || exit 0
		pw=$(sed -n 's/^password=//p' "$cnf")
		for h in 127.0.0.1 ::1 localhost; do
			echo "CREATE OR REPLACE USER healthcheck@'$h' IDENTIFIED BY '$pw';"
			echo "GRANT USAGE ON *.* TO healthcheck@'$h';"
		done | "$1" -uroot -p"$2"
	EOSH
	# 导入只改了 mysql 库里的权限表，不刷新的话恢复出来的用户登不上
	query "FLUSH PRIVILEGES"
	echo "导入完成。root 密码若和 .env 里的不同，把 .env 改成备份时的密码"
	exit 0
	;;
*)
	inferred=$(printf '%s\n' "$base" | sed -nE 's/^(.+)_[0-9]{8}_[0-9]{6}(_before-restore)?\.sql(\.gz)?$/\1/p')
	[ -n "$inferred" ] || { echo "认不出 $base 是哪个库的备份，文件名应为 <库名>_<日期>_<时间>.sql[.gz]" >&2; exit 1; }
	if [ -n "$DB_NAME" ] && [ "$DB_NAME" != "$inferred" ]; then
		echo "$base 是库 $inferred 的备份，不能恢复成 $DB_NAME" >&2
		exit 1
	fi
	DB_NAME=$inferred
	db_exists "$DB_NAME" || { echo "库 $DB_NAME 不存在，先用 create-db.sh 建好再恢复" >&2; exit 1; }
	# 单库备份不带建库语句，按原来的字符集重建，备份里删掉的表才不会残留
	charset=$(query "SELECT CONCAT(DEFAULT_CHARACTER_SET_NAME, ' COLLATE ', DEFAULT_COLLATION_NAME)
		FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${DB_NAME}'")
	confirm "要用 $FILE 覆盖库 ${DB_NAME}，"
	snapshot "$DB_NAME"
	query "DROP DATABASE \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET ${charset}"
	read_file | sql "$DB_NAME"
	;;
esac

echo "已恢复库 $DB_NAME"
