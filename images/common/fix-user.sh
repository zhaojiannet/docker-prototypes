#!/bin/sh
set -eu

PUID=${1:?用法: fix-user <uid> <gid>}
PGID=${2:?用法: fix-user <uid> <gid>}

cur_uid=$(id -u "$DEV_USER")
cur_gid=$(id -g "$DEV_USER")
if [ "$PUID" = "$cur_uid" ] && [ "$PGID" = "$cur_gid" ]; then
	exit 0
fi

# -o 允许和已有 uid 重号：宿主机 uid 可能恰好被镜像里的系统用户占着
groupmod -o -g "$PGID" "$DEV_USER"
usermod -o -u "$PUID" -g "$PGID" "$DEV_USER"

home=$(getent passwd "$DEV_USER" | cut -d: -f6)
# shellcheck disable=SC2086
chown -R "$PUID:$PGID" "$home" $DEV_DIRS
