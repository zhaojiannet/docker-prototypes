#!/bin/bash
# 查看用户和权限
# 用法: ./check-user.sh [用户名]   不给用户名就列出全部
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

USER_NAME=${1:-}

if [ -z "$USER_NAME" ]; then
	docker compose exec -T mariadb mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" -e \
		"SELECT user AS 用户, host AS 来源主机, plugin AS 认证插件 FROM mysql.user ORDER BY user;"
else
	docker compose exec -T mariadb mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" -e \
		"SELECT user AS 用户, host AS 来源主机, plugin AS 认证插件 FROM mysql.user WHERE user='${USER_NAME}';"
	echo "--- 权限 ---"
	# MariaDB 的 SHOW GRANTS 会带出密码哈希，截掉
	docker compose exec -T mariadb mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" -N -e \
		"SHOW GRANTS FOR '${USER_NAME}'@'%';" | sed 's/ IDENTIFIED BY PASSWORD .*//'
fi
