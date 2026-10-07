#!/bin/bash
# 创建数据库和对应用户，并收紧 public schema 的权限
# 用法: ./create-db.sh 数据库名 用户名 [密码]
# 不给密码就随机生成一个
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

DB_NAME=${1:?用法: ./create-db.sh 数据库名 用户名 [密码]}
DB_USER=${2:?用法: ./create-db.sh 数据库名 用户名 [密码]}
DB_PASS=${3:-$(openssl rand -base64 18)}

docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" <<-EOSQL
	DO \$\$
	BEGIN
	    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
	        CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
	    ELSE
	        ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
	    END IF;
	END
	\$\$;

	-- 排序规则用 builtin 的 PG_UNICODE_FAST，不依赖实例初始化时的 locale，原因见 README
	SELECT 'CREATE DATABASE ${DB_NAME} TEMPLATE template0 ENCODING ''UTF8'' LOCALE_PROVIDER builtin BUILTIN_LOCALE ''PG_UNICODE_FAST'' LOCALE ''C.UTF-8'' OWNER ${DB_USER}'
	WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec
EOSQL

# 连到新库里设权限。PG15 之后 public schema 默认已经不给 PUBLIC 建表权，这里再收一道
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${DB_NAME}" <<-EOSQL
	REVOKE ALL ON DATABASE ${DB_NAME} FROM PUBLIC;
	REVOKE ALL ON SCHEMA public FROM PUBLIC;

	GRANT CONNECT ON DATABASE ${DB_NAME} TO ${DB_USER};
	GRANT USAGE, CREATE ON SCHEMA public TO ${DB_USER};
	GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
	GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};

	ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
	ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
EOSQL

echo "创建完成"
echo "  数据库: ${DB_NAME}"
echo "  用户名: ${DB_USER}"
echo "  密码:   ${DB_PASS}"
echo "  连接:   postgresql://${DB_USER}:密码@localhost:${POSTGRES_PORT:-5432}/${DB_NAME}"
