#!/bin/bash
# 给同一层的各数据库做整库备份，再清理各自 backups/ 下的旧文件
# 用法: ./backup-all.sh
set -euo pipefail
cd "$(dirname "$0")"

KEEP_FULL=5
KEEP_BEFORE_DAYS=30

for dir in */; do
	dir=${dir%/}
	# 不写死目录名：仓库里是 mariadb，复制到别处可能叫 MariaDB。
	# 只认同时有 backup.sh 和 create-db.sh 的，避免调到别的项目碰巧同名的 backup.sh；Valkey 没有这两个，自然跳过
	[ -x "$dir/backup.sh" ] && [ -x "$dir/create-db.sh" ] || continue
	echo "== $dir"
	(
		cd "$dir"
		if [ -z "$(docker compose ps --status running --quiet)" ]; then
			echo "未运行，临时启动，备份完再停掉"
			trap 'docker compose stop' EXIT
			docker compose up -d --wait
		fi

		./backup.sh

		# 文件名里的时间戳按字典序就是时间顺序
		find backups -maxdepth 1 -name 'all_databases_*.sql.gz' | sort -r | tail -n +$((KEEP_FULL + 1)) |
			while read -r f; do
				echo "删除 $f"
				rm -f "$f"
			done
		# 按修改时间算，文件被复制过时间会重置
		find backups -mindepth 1 -maxdepth 1 -name '*before-*' -mtime +"$KEEP_BEFORE_DAYS" \
			-exec echo "删除 {}" \; -exec rm -rf {} +
		du -sh backups
	)
done
