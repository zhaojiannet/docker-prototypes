#!/bin/bash
# 备份数据库到 backups/
# 用法: ./backup.sh [数据库名]   不给库名就备份全部（含角色和权限）
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

STAMP=$(date +%Y%m%d_%H%M%S)
DB_NAME=${1:-}

if [ -z "$DB_NAME" ]; then
	OUT="backups/all_databases_${STAMP}.sql"
	docker compose exec -T postgres pg_dumpall -U "${POSTGRES_USER}" > "$OUT"
else
	OUT="backups/${DB_NAME}_${STAMP}.sql"
	docker compose exec -T postgres pg_dump -U "${POSTGRES_USER}" -d "${DB_NAME}" > "$OUT"
fi

gzip "$OUT"
echo "备份完成: ${OUT}.gz ($(du -h "${OUT}.gz" | cut -f1))"
