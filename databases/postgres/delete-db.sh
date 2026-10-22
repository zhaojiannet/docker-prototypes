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

STAMP=$(date +%Y%m%d_%H%M%S)
echo "先备份到 backups/${DB_NAME}_${STAMP}.sql"
docker compose exec -T postgres pg_dump -U "${POSTGRES_USER}" --create -d "${DB_NAME}" > "backups/${DB_NAME}_${STAMP}.sql"

# 连 postgres 库：它一定存在；POSTGRES_DB 若就是要删的库，连着它删不掉。
# FORCE 在同一条语句里断开连接再删，应用的连接池来不及在两步之间重连
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres <<-EOSQL
	DROP DATABASE IF EXISTS ${DB_NAME} WITH (FORCE);
	${DB_USER:+DROP USER IF EXISTS ${DB_USER};}
EOSQL

echo "已删除 ${DB_NAME}${DB_USER:+ 和用户 ${DB_USER}}"
