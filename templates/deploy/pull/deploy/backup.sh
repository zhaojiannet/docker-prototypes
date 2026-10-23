#!/usr/bin/env bash
# 在服务器的部署目录（DEPLOY_DIR）里运行。dp backup 经 ssh 把本文件送过去执行，服务器上不用有这个文件。
# 用法: backup.sh [备份项]   不写就把下面 case 里的各项都备份一遍
# 约定：每生成一个备份文件，把它相对部署目录的路径打到标准输出，dp 按这些路径拉回本机；其他信息一律打到标准错误
set -euo pipefail

KEEP=5
STAMP=$(date +%Y%m%d_%H%M%S)
# 备份里有密钥和业务数据，只给自己读
umask 077
mkdir -p backups

# 每种只留最近 KEEP 份，文件名里的时间戳按字典序就是时间顺序
prune() { ls -1 backups/"$1"_* 2>/dev/null | sort -r | tail -n +$((KEEP + 1)) | xargs -r rm -f --; }

backup_env() {
	tar -czf "backups/env_${STAMP}.tgz" .env
	prune env
	echo "backups/env_${STAMP}.tgz"
}

# 示例：库在本项目 compose 里名为 postgres 的服务，账号从 .env 读。库在共享实例或云数据库时改这里
backup_db() {
	docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "backups/db_${STAMP}.dump"
	prune db
	echo "backups/db_${STAMP}.dump"
}

case ${1:-all} in
env) backup_env ;;
db) backup_db ;;
all)
	backup_env
	backup_db
	;;
*)
	echo "没有备份项 $1，可选：env db all" >&2
	exit 1
	;;
esac
