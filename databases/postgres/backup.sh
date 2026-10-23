#!/bin/bash
# 备份数据库到 backups/
# 用法: ./backup.sh [数据库名]   不给库名就备份全部（含角色和权限）
set -euo pipefail
cd "$(dirname "$0")"
. ./.env

DB_NAME=${1:-}
# 文件名只精确到秒，同一秒里再备份同一个库时等到下一秒，不覆盖前一份
STAMP=$(date +%Y%m%d_%H%M%S)
while [ -e "backups/${DB_NAME:-all_databases}_${STAMP}.sql.gz" ]; do
	sleep 1
	STAMP=$(date +%Y%m%d_%H%M%S)
done

if [ -z "$DB_NAME" ]; then
	OUT="backups/all_databases_${STAMP}.sql"
	docker compose exec -T postgres pg_dumpall -U "${POSTGRES_USER}" > "$OUT"
else
	OUT="backups/${DB_NAME}_${STAMP}.sql"
	docker compose exec -T postgres pg_dump -U "${POSTGRES_USER}" --create -d "${DB_NAME}" > "$OUT"
fi

gzip "$OUT"
echo "备份完成: ${OUT}.gz ($(du -h "${OUT}.gz" | cut -f1))"
