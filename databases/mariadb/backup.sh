#!/bin/bash
# 备份数据库到 backups/
# 用法: ./backup.sh [数据库名]   不给库名就备份全部
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

STAMP=$(date +%Y%m%d_%H%M%S)
DB_NAME=${1:-}

if [ -z "$DB_NAME" ]; then
	OUT="backups/all_databases_${STAMP}.sql"
	docker compose exec -T mariadb mariadb-dump -uroot -p"${MARIADB_ROOT_PASSWORD}" \
		--all-databases --single-transaction --routines --triggers --events > "$OUT"
else
	OUT="backups/${DB_NAME}_${STAMP}.sql"
	docker compose exec -T mariadb mariadb-dump -uroot -p"${MARIADB_ROOT_PASSWORD}" \
		--single-transaction --routines --triggers --events "$DB_NAME" > "$OUT"
fi

gzip "$OUT"
echo "备份完成: ${OUT}.gz ($(du -h "${OUT}.gz" | cut -f1))"
