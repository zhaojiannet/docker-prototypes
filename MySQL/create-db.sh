#!/bin/bash
# 创建数据库和对应用户
# 用法: ./create-db.sh 数据库名 用户名 [密码]
# 不给密码就随机生成一个
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

DB_NAME=${1:?用法: ./create-db.sh 数据库名 用户名 [密码]}
DB_USER=${2:?用法: ./create-db.sh 数据库名 用户名 [密码]}
DB_PASS=${3:-$(openssl rand -base64 18)}

docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
	CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
	CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
	GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
	FLUSH PRIVILEGES;
EOSQL

echo "创建完成"
echo "  数据库: ${DB_NAME}"
echo "  用户名: ${DB_USER}"
echo "  密码:   ${DB_PASS}"
echo "  连接:   mysql://${DB_USER}:密码@localhost:${MYSQL_PORT:-3306}/${DB_NAME}"
