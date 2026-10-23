#!/bin/bash
# 创建数据库和对应用户
# 用法: ./create-db.sh 数据库名 用户名 [密码]
# 不给密码时，新用户随机生成一个，已有的用户不改密码
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

DB_NAME=${1:?用法: ./create-db.sh 数据库名 用户名 [密码]}
DB_USER=${2:?用法: ./create-db.sh 数据库名 用户名 [密码]}
DB_PASS=${3:-}

sql() { docker compose exec -T mariadb mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "$@"; }
# 已有的用户可能正被别的库的应用用着，没给密码就不动它
if [ -z "$(sql -N -e "SELECT 1 FROM mysql.user WHERE user = '${DB_USER}' AND host = '%'" </dev/null)" ] || [ -n "$DB_PASS" ]; then
	DB_PASS=${DB_PASS:-$(openssl rand -hex 24)}
	set_user="CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}'; ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';"
fi

sql <<-EOSQL
	CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
	${set_user:-}
	GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
	FLUSH PRIVILEGES;
EOSQL

echo "创建完成"
echo "  数据库: ${DB_NAME}"
echo "  用户名: ${DB_USER}"
echo "  密码:   ${DB_PASS:-（用户已存在，密码没有改）}"
echo "  连接:   mysql://${DB_USER}:密码@localhost:${MARIADB_PORT:-3307}/${DB_NAME}"
