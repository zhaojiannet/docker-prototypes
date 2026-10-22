#!/usr/bin/env bash
# 新服务器初始化，可重复运行。服务器上不用有这个仓库：
#   curl -fsSL https://raw.githubusercontent.com/zhaojiannet/docker-prototypes/main/server/setup.sh | sudo bash
# 参数走环境变量，放在 sudo 后面：... | sudo SSH_PORT=<端口> bash
#   SSH_PORT              SSH 的新端口，没给就在终端里问
#   TZ_NAME=Asia/Tokyo    时区
#   REBOOT_TIME=04:00     装了要重启的安全更新（如内核）后，在这个时间自动重启
#   SWAP_SIZE=<内存大小>   没有 swap 时建一个，默认和内存一样大
# 项目自己的数据卷、证书、定时备份不在这里，由各项目的脚本做。
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "需要 root：curl ... | sudo bash" >&2; exit 2; }
. /etc/os-release
case ${ID:-} in
ubuntu | debian) ;;
*) echo "只支持 Ubuntu 和 Debian，当前是 ${ID:-未知}" >&2; exit 2 ;;
esac

# 端口不写默认值：仓库是公开的，写在这里等于公开了所有服务器的 SSH 端口。
# curl | bash 时标准输入是脚本本身，只能从 /dev/tty 问
SSH_PORT=${SSH_PORT:-}
if [ -z "$SSH_PORT" ]; then
	if ! { exec 3<>/dev/tty; } 2>/dev/null; then
		echo "没有终端可问，用环境变量给出 SSH 端口：... | sudo SSH_PORT=<端口> bash" >&2
		exit 2
	fi
	read -r -p "SSH 的新端口（1024-65535）: " SSH_PORT <&3 >&3 2>&3 || SSH_PORT=
	exec 3<&-
fi
case $SSH_PORT in
'' | *[!0-9]*) echo "SSH 端口要是数字：${SSH_PORT}" >&2; exit 2 ;;
esac
if [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
	echo "SSH 端口要在 1024-65535 之间：${SSH_PORT}" >&2
	exit 2
fi
TZ_NAME=${TZ_NAME:-Asia/Tokyo}
REBOOT_TIME=${REBOOT_TIME:-04:00}
if [ -z "${SWAP_SIZE:-}" ]; then
	mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
	SWAP_SIZE="$(((mem_kb + 1048575) / 1048576))G"
fi
# 用 sudo 运行时，登录用的是 SUDO_USER，禁 root 登录、关密码登录都看这个用户有没有配好密钥
LOGIN_USER=${SUDO_USER:-root}
LOGIN_HOME=$(getent passwd "$LOGIN_USER" | cut -d: -f6)
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n=== %s\n' "$1"; }

step "软件包"
apt-get update -qq
apt-get install -y -qq ca-certificates curl openssh-server ufw unattended-upgrades fail2ban >/dev/null

SSH_CONF=/etc/ssh/sshd_config.d/99-server-setup.conf
SOCKET_OVERRIDE=/etc/systemd/system/ssh.socket.d/override.conf
# 上次运行留下的端口：socket 激活时在 override 里，否则在 SSH_CONF 的 Port 行。
# 重跑时照上次的状态来：已经收掉的 22 不再打开，换了端口就收掉旧端口
old_ports=$({ cat "$SSH_CONF" "$SOCKET_OVERRIDE" 2>/dev/null || true; } |
	sed -nE 's/^(Port |ListenStream=0\.0\.0\.0:)([0-9]+)$/\2/p' | sort -u | tr '\n' ' ')
keep22=yes
old_port=""
if [ -n "$old_ports" ]; then
	case " $old_ports" in *" 22 "*) ;; *) keep22="" ;; esac
	for p in $old_ports; do
		[ "$p" = 22 ] || old_port=$p
	done
fi
ports="${keep22:+22 }${SSH_PORT}"

step "防火墙：只放行 SSH（${ports}）"
# 先放行再启用，顺序反了当前会话会断。Docker 发布的端口不经过 ufw，网站端口由云控制台的防火墙把关
for p in $ports; do
	ufw allow "${p}/tcp" >/dev/null
done
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
ufw status verbose | sed -n '1,12p'

step "SSH：端口 ${ports}，只用密钥登录"
if [ ! -s "$LOGIN_HOME/.ssh/authorized_keys" ]; then
	# 没有密钥就关掉密码登录，会把自己锁在门外
	echo "跳过：$LOGIN_USER 的 ~/.ssh/authorized_keys 是空的，先配好密钥再重跑" >&2
else
	if [ "$LOGIN_USER" = root ]; then
		# 直接用 root 登录的服务器，禁掉 root 就没人能登录；只禁密码，留密钥
		permit_root=prohibit-password
		echo "当前是 root 直接登录：root 仍可用密钥登录。建好有 sudo 的普通用户、配好密钥后，用它重跑本脚本即可完全禁止 root 登录"
	else
		permit_root=no
	fi
	# 99- 前缀压过 cloud-init 的 50-，系统更新不会覆盖
	{
		for p in $ports; do
			echo "Port $p"
		done
		printf 'PermitRootLogin %s\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\n' "$permit_root"
	} >"$SSH_CONF"
	if [ "$(systemctl is-active ssh.socket 2>/dev/null)" = active ]; then
		# socket 激活时 sshd_config 的 Port 不生效，端口由 socket 单元决定。
		# Ubuntu 的 ssh.socket 设了 BindIPv6Only=ipv6-only，只写端口号就只监听 IPv6，所以 IPv4、IPv6 分开写
		mkdir -p "$(dirname "$SOCKET_OVERRIDE")"
		printf '[Socket]\nListenStream=\n' >"$SOCKET_OVERRIDE"
		for p in $ports; do
			printf 'ListenStream=0.0.0.0:%s\nListenStream=[::]:%s\n' "$p" "$p" >>"$SOCKET_OVERRIDE"
		done
		sed -i '/^Port /d' "$SSH_CONF"
		systemctl daemon-reload
		systemctl restart ssh.socket
	fi
	# sshd 没运行过的机器上没有这个目录（平时由 ssh.service 建），sshd -t 会报错
	install -d -m 0755 /run/sshd
	sshd -t
	systemctl restart ssh
	sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication) ' || true
	# 新端口生效之后才收旧端口；已经连着的会话不受影响
	if [ -n "$old_port" ] && [ "$old_port" != "$SSH_PORT" ]; then
		ufw delete allow "${old_port}/tcp" >/dev/null || true
		echo "已收掉旧端口 ${old_port}，之后用 ${SSH_PORT} 登录"
	fi
fi
printf '[sshd]\nenabled = true\nport = %s\nmaxretry = 3\nbantime = 1h\n' "$(echo $ports | tr ' ' ',')" >/etc/fail2ban/jail.d/sshd.local
systemctl restart fail2ban

step "swap"
if [ -z "$(swapon --show --noheadings)" ]; then
	fallocate -l "$SWAP_SIZE" /swapfile
	chmod 600 /swapfile
	mkswap /swapfile >/dev/null
	swapon /swapfile
	grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi
swapon --show

step "日志持久化、时区 ${TZ_NAME}"
mkdir -p /var/log/journal
systemctl restart systemd-journald
timedatectl set-timezone "$TZ_NAME"

step "Docker（官方 apt 源）"
# 有 download.docker.com 的源就不再加：get.docker.com 装过的也是这个源，重复的源条目 apt 会报错
if ! grep -rqs download.docker.com /etc/apt/sources.list /etc/apt/sources.list.d/; then
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
	apt-get update -qq
fi
command -v docker >/dev/null ||
	apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
docker version --format 'Docker {{.Server.Version}}'
docker compose version
docker network inspect docker-net >/dev/null 2>&1 || docker network create docker-net >/dev/null

step "自动安装安全更新（含 Docker），需要时 ${REBOOT_TIME} 自动重启"
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >/etc/apt/apt.conf.d/20auto-upgrades
# 有的云厂商系统镜像改过 50unattended-upgrades，去掉了 -security 源，安全补丁一直装不上，这里显式加上；
# Docker 来自官方源，不加的话永远不会自动更新。列表项会和 50 里的合并，不会覆盖
cat >/etc/apt/apt.conf.d/52server-setup <<EOF
Unattended-Upgrade::Origins-Pattern {
	"origin=\${distro_id},archive=\${distro_codename}-security";
	"origin=Docker,archive=\${distro_codename}";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
EOF
unattended-upgrade --dry-run --debug 2>&1 | grep -E 'Allowed origins are' || true

if [ -n "$keep22" ]; then
	if [ -f "$SOCKET_OVERRIDE" ]; then
		close22="sudo sed -i -e '/^ListenStream=0\\.0\\.0\\.0:22\$/d' -e '/^ListenStream=\\[::\\]:22\$/d' $SOCKET_OVERRIDE
    sudo systemctl daemon-reload && sudo systemctl restart ssh.socket"
	else
		close22="sudo sed -i '/^Port 22\$/d' $SSH_CONF
    sudo sshd -t && sudo systemctl restart ssh"
	fi
	cat <<EOF

=== 完成。确认 ${SSH_PORT} 能登录后再收掉 22（当前会话先别关）：
  本机：ssh -p ${SSH_PORT} ${LOGIN_USER}@<IP>
  服务器：
    ${close22}
    sudo ufw delete allow 22/tcp
EOF
else
	printf '\n=== 完成。SSH 端口 %s\n' "$SSH_PORT"
fi
[ ! -f /var/run/reboot-required ] || echo "有更新要重启才生效，会在 ${REBOOT_TIME} 自动重启；要马上生效就 sudo reboot"
