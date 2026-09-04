#!/bin/bash
# 查看用户和权限
# 用法: ./check-user.sh [用户名]   不给用户名就列出全部
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

USER_NAME=${1:-}

if [ -z "$USER_NAME" ]; then
	docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "\du"
else
	docker compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" <<-EOSQL
		\echo '--- 角色属性 ---'
		SELECT rolname AS 角色, rolsuper AS 超级用户, rolcreatedb AS 可建库,
		       rolcreaterole AS 可建角色, rolcanlogin AS 可登录
		FROM pg_roles WHERE rolname = '${USER_NAME}';

		\echo '--- 各个库的权限 ---'
		SELECT datname AS 数据库,
		       has_database_privilege('${USER_NAME}', datname, 'CONNECT') AS 可连接,
		       has_database_privilege('${USER_NAME}', datname, 'CREATE') AS 可建表
		FROM pg_database WHERE NOT datistemplate ORDER BY datname;
	EOSQL
fi
