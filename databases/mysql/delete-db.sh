#!/bin/bash
# 删除数据库和用户，删之前先备份
# 用法: ./delete-db.sh 数据库名 [用户名]
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

DB_NAME=${1:?用法: ./delete-db.sh 数据库名 [用户名]}
DB_USER=${2:-}

read -r -p "要删除数据库 ${DB_NAME}${DB_USER:+ 和用户 ${DB_USER}}，确认吗? [y/N] " ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "已取消"; exit 1; }

# 和单库备份同一个格式，dp db restore 认得
./backup.sh "${DB_NAME}"

docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
	DROP DATABASE IF EXISTS \`${DB_NAME}\`;
	${DB_USER:+DROP USER IF EXISTS '${DB_USER}'@'%';}
	FLUSH PRIVILEGES;
EOSQL

echo "已删除 ${DB_NAME}${DB_USER:+ 和用户 ${DB_USER}}"
