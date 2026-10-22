#!/bin/bash
# 从备份恢复，覆盖已有的库之前先把它再备份一份到 backups/
# 用法: ./restore.sh 备份文件 [库名]
#   单库备份（<库名>_<时间>.sql[.gz]）：恢复成同名库
#   整库备份（all_databases_<时间>.sql[.gz]）：给了库名只恢复这一个库；
#     不给就整个导入，只用于新实例，实例里已经有别的库时拒绝
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

USAGE="用法: ./restore.sh 备份文件 [库名]"
FILE=${1:?$USAGE}
DB_NAME=${2:-}
[ -f "$FILE" ] || { echo "找不到 $FILE" >&2; exit 1; }

psql_admin() { docker compose exec -T postgres psql -q -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" "$@"; }
read_file() { case $FILE in *.gz) gzip -dc "$FILE" ;; *) cat "$FILE" ;; esac; }
# 单条查询不读标准输入，否则 exec -T 会把后面 confirm 要读的回答吃掉
query() { psql_admin -d postgres -Atc "$1" </dev/null; }
db_exists() { [ -n "$(query "SELECT 1 FROM pg_database WHERE datname = '$1'")" ]; }

confirm() {
	read -r -p "$1 确认吗? [y/N] " ans || ans=
	[ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; exit 1; }
}

# 覆盖前的快照，名字带 before- 才会被 dp db backup 按 30 天清理
snapshot() {
	local out
	out="backups/${1}_$(date +%Y%m%d_%H%M%S)_before-restore.sql.gz"
	docker compose exec -T postgres pg_dump -U "${POSTGRES_USER}" --create -d "$1" </dev/null | gzip > "$out"
	echo "已备份当前的 $1 到 $out"
}

# 管理操作都连 postgres 库：它一定存在；POSTGRES_DB 若就是要删的库，连着它删不掉。
# FORCE 在同一条语句里断开连接再删，应用的连接池来不及在两步之间重连
drop_db() { psql_admin -d postgres -c "DROP DATABASE IF EXISTS $1 WITH (FORCE)" </dev/null; }

base=$(basename "$FILE")
case $base in
all_databases_*)
	if [ -z "$DB_NAME" ]; then
		others=$(query \
			"SELECT string_agg(datname, ' ') FROM pg_database WHERE NOT datistemplate AND datname NOT IN ('postgres', '${POSTGRES_DB}')")
		if [ -n "$others" ]; then
			echo "实例里已经有这些库：${others}。整个导入只用于新实例，要恢复其中一个库就带上库名" >&2
			exit 1
		fi
		confirm "要把 $FILE 整个导入这个实例，"
		# 角色 postgres 已存在，导入时会报一条 already exists，属正常，所以不在出错时停下
		read_file | docker compose exec -T postgres psql -q -U "${POSTGRES_USER}" -d postgres
		echo "导入完成"
		exit 0
	fi
	;;
*)
	inferred=$(printf '%s\n' "$base" | sed -nE 's/^(.+)_[0-9]{8}_[0-9]{6}(_before-restore)?\.sql(\.gz)?$/\1/p')
	[ -n "$inferred" ] || { echo "认不出 $base 是哪个库的备份，文件名应为 <库名>_<日期>_<时间>.sql[.gz]" >&2; exit 1; }
	if [ -n "$DB_NAME" ] && [ "$DB_NAME" != "$inferred" ]; then
		echo "$base 是库 $inferred 的备份，不能恢复成 $DB_NAME" >&2
		exit 1
	fi
	DB_NAME=$inferred
	;;
esac

# pg_dumpall 里 postgres 库那段没有建库语句，删库重建也都要连着它
[ "$DB_NAME" != postgres ] || { echo "postgres 是维护库，不能用这个脚本恢复" >&2; exit 1; }

# 要恢复的 SQL 只解压一次，写到临时文件：单个库就可能有几 GB，放进变量会占满内存，反复解压又慢
sql=$(mktemp backups/.restore.XXXXXX)
trap 'rm -f "$sql"' EXIT
case $base in
all_databases_*)
	# pg_dumpall 里每个库是一段完整的 pg_dump --create 输出，从「-- Database "库名" dump」开始，到下一个库或结尾为止
	read_file | awk -v db="$DB_NAME" '
		/^-- Database ".*" dump$/ { on = ($0 == "-- Database \"" db "\" dump") }
		/^-- PostgreSQL database cluster dump complete$/ { on = 0 }
		on' >"$sql"
	[ -s "$sql" ] || { echo "$FILE 里没有库 $DB_NAME" >&2; exit 1; }
	;;
*) read_file >"$sql" ;;
esac

if grep -q '^CREATE DATABASE ' "$sql"; then
	# 备份里带建库语句和库级权限：删掉旧库，由备份重建。
	# 建库后紧跟 ALTER DATABASE ... OWNER TO，属主已被 delete-db.sh 删掉时会在删旧库之后才失败，所以先查
	owner=$(sed -nE 's/^ALTER DATABASE .* OWNER TO "?([^";]+)"?;$/\1/p' "$sql" | awk 'NR == 1')
	if [ -n "$owner" ] && [ -z "$(query "SELECT 1 FROM pg_roles WHERE rolname = '${owner}'")" ]; then
		echo "库 $DB_NAME 的属主 $owner 不存在，先建好这个用户再恢复：" >&2
		echo "  docker compose exec postgres psql -U ${POSTGRES_USER} -d postgres -c \"CREATE ROLE ${owner} LOGIN PASSWORD '<密码>'\"" >&2
		exit 1
	fi
	if db_exists "$DB_NAME"; then
		confirm "要用 $FILE 覆盖库 ${DB_NAME}，"
		snapshot "$DB_NAME"
		drop_db "$DB_NAME"
	fi
	psql_admin -d postgres <"$sql"
else
	# 不带建库语句的备份（pg_dump 没加 --create 导出的）：按库原来的属主重建空库，权限跟 create-db.sh 一致，再导入
	db_exists "$DB_NAME" || { echo "库 $DB_NAME 不存在，先用 create-db.sh 建好再恢复" >&2; exit 1; }
	owner=$(query "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${DB_NAME}'")
	confirm "要用 $FILE 覆盖库 ${DB_NAME}，"
	snapshot "$DB_NAME"
	drop_db "$DB_NAME"
	psql_admin -d postgres <<-EOSQL
		CREATE DATABASE ${DB_NAME} TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'PG_UNICODE_FAST' LOCALE 'C.UTF-8' OWNER ${owner};
		REVOKE ALL ON DATABASE ${DB_NAME} FROM PUBLIC;
		GRANT CONNECT ON DATABASE ${DB_NAME} TO ${owner};
	EOSQL
	psql_admin -d "$DB_NAME" <"$sql"
fi

echo "已恢复库 $DB_NAME"
