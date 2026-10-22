#!/usr/bin/env bash
# 由 tests/e2e.sh 在测试容器里调用，不单独运行。每组在子 shell 里跑，一组失败不影响后面的组
set -euo pipefail
case $BASH_VERSION in
3.2.*) ;;
*) echo "要在 bash 3.2 下跑，当前是 ${BASH_VERSION}" >&2; exit 2 ;;
esac

REPO=$PWD
DP=$REPO/dp
P=$DP_ROOT
export DP_ROOT

# dp 直接调 ssh、scp，测试服务器的设置经包装脚本用 -F 传进去，不碰用户自己的 ~/.ssh/config
mkdir -p "$WORK/bin"
# 在 Mac 上跑时 Docker 经 ssh 连 OrbStack 虚拟机，也走这里的包装脚本，要带上 OrbStack 的设置。
# Include 写在 Host 段后面只对那个 Host 生效，所以放最前面
: >"$WORK/ssh_config"
if [ -f "$HOME/.orbstack/ssh/config" ]; then
	echo "Include $HOME/.orbstack/ssh/config" >"$WORK/ssh_config"
fi
cat >>"$WORK/ssh_config" <<EOF
Host e2e-server
  HostName $E2E_SSH_HOST
  Port $E2E_SSH_PORT
  User root
  IdentityFile $WORK/home/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
for tool in ssh scp; do
	printf '#!/bin/sh\nexec %s -F %s "$@"\n' "$(command -v "$tool")" "$WORK/ssh_config" >"$WORK/bin/$tool"
	chmod +x "$WORK/bin/$tool"
done
chmod 600 "$WORK/home/id_ed25519"
PATH=$WORK/bin:$PATH

fail() {
	echo "  失败：$*" >&2
	exit 1
}
ok() { echo "  通过：$*"; }

# 命令应当失败；把输出留下供后面检查
expect_fail() {
	if OUT=$("$@" 2>&1); then
		fail "应该失败却成功了：$*"
	fi
}

# 开发服务器、air 首次编译要一会儿，多等几轮
expect_http() {
	local body
	body=$(docker exec dp-e2e-curl curl -fsS --retry 60 --retry-delay 2 --retry-all-errors --max-time 5 "$1" 2>&1) || fail "$1 打不开：${body}"
	case $body in
	*"$2"*) ok "$1 返回 $2" ;;
	*) fail "$1 返回「${body}」，不含「$2」" ;;
	esac
}

expect_eq() {
	[ "$1" = "$2" ] || fail "$3：期望「$2」，实际「$1」"
	ok "$3"
}

# ls 的输出交给 awk 取第一行，不用 head：head 提前退出会让 ls 收到 SIGPIPE，pipefail 下整条命令失败
newest() {
	# shellcheck disable=SC2012
	ls -t "$@" 2>/dev/null | awk 'NR == 1'
}

# 测试代码自己也要在 macOS 和 Linux 上都能跑：sed -i、stat 两边写法不同
edit() {
	sed "$1" "$2" >"$2.tmp"
	mv "$2.tmp" "$2"
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

git_commit() {
	git -C "$1" add -A
	git -C "$1" -c user.name=e2e -c user.email=e2e@example.com commit -qm "$2"
}

group_project() {
	"$DP" help >/dev/null

	"$DP" new node web
	cd "$P/web"
	cat >app/server.cjs <<'EOF'
require('http').createServer((req, res) => res.end('node-ok ' + Intl.DateTimeFormat().resolvedOptions().timeZone)).listen(4321, '0.0.0.0');
EOF
	echo 'web-build-ok' >app/index.html
	docker compose run --rm --no-deps app pnpm pkg set 'scripts.dev=node server.cjs' 'scripts.build=mkdir -p dist && cp index.html dist/'
	# 在项目目录里不写项目名
	"$DP" up
	expect_http http://web-app-1:4321 'node-ok Asia/Tokyo'
	[ -f app/pnpm-lock.yaml ] || fail "没有生成 app/pnpm-lock.yaml，生产构建的 COPY 会失败"
	docker build -q --target runtime -t e2e-web:rt . >/dev/null
	docker run -d --name e2e-web-rt --network docker-net e2e-web:rt >/dev/null
	expect_http http://e2e-web-rt:80 web-build-ok
	docker rm -f e2e-web-rt >/dev/null

	"$DP" new go api --module example.com/api
	mkdir -p "$P/api/app/cmd/api"
	cat >"$P/api/app/cmd/api/main.go" <<'EOF'
package main

import (
	"fmt"
	"net/http"
	"time"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "go-ok ", time.Now().Format("MST"))
	})
	http.ListenAndServe(":8080", nil)
}
EOF
	printf '[build]\n  cmd = "go build -o ./tmp/main ./cmd/api"\n' >"$P/api/app/.air.toml"
	"$DP" restart api
	expect_http http://api-app-1:8080 'go-ok JST'
	docker build -q --target runtime -t e2e-api:rt "$P/api" >/dev/null
	docker run -d --name e2e-api-rt --network docker-net -e TZ=Asia/Tokyo e2e-api:rt api >/dev/null
	expect_http http://e2e-api-rt:8080 'go-ok JST'
	docker rm -f e2e-api-rt >/dev/null

	cd "$P/web"
	git init -q
	echo gone >notes.txt
	git_commit . init
	echo 'SECRET=1' >app/.env
	# 已提交、又在工作区删掉的文件
	rm notes.txt
	"$DP" copy web web2
	expect_eq "$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$P/web2/.env")" web2 "复制出的 .env 用新项目名"
	[ ! -e "$P/web2/app/.env" ] || fail "app/.env 不该被复制"
	[ ! -e "$P/web2/notes.txt" ] || fail "工作区已删的文件不该被复制"
	expect_http http://web2-app-1:4321 node-ok

	expect_fail "$DP" new node 日本
	[ ! -e "$P/日本" ] || fail "转不成项目名时不该建目录"
	ok "转不成项目名的名字在建目录前拒绝"

	git clone -q --bare "$P/web" "$WORK/origin/web.git"
	"$DP" clone "$WORK/origin/web.git" web3
	expect_http http://web3-app-1:4321 node-ok

	OUT=$("$DP" status web)
	case $OUT in *web-app-1*) ok "status" ;; *) fail "status 里没有 web-app-1：${OUT}" ;; esac
	OUT=$("$DP" status all)
	case $OUT in *web2*) ok "status all" ;; *) fail "status all 里没有 web2：${OUT}" ;; esac
	"$DP" logs web --tail 5 >/dev/null
	expect_fail "$DP" logs all
	case $OUT in *一次只看一个项目*) ok "logs all 时提示写项目名" ;; *) fail "logs all 的提示不对：${OUT}" ;; esac
	"$DP" update web
	expect_http http://web-app-1:4321 node-ok
	cd "$P/web/app"
	"$DP" restart
	expect_http http://web-app-1:4321 node-ok

	# 一个项目坏了：其他照常处理，最后汇总并返回非 0
	mkdir -p "$P/broken"
	printf 'services:\n  app:\n    image: 127.0.0.1:5000/e2e/missing:none\n' >"$P/broken/compose.yaml"
	"$DP" -y down all
	expect_fail "$DP" -y up all
	case $OUT in *失败*broken*) ok "all 里有失败时汇总" ;; *) fail "汇总里没有 broken：${OUT}" ;; esac
	expect_http http://web-app-1:4321 node-ok
	rm -rf "${P:?}/broken"
}

pg() { docker exec -i postgres sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -At "$@"' sh "$@"; }

group_postgres() {
	"$DP" db new postgres
	local d=$P/PostgreSQL f fa pw
	pw=$("$DP" db create postgres app app_user | sed -n 's/^ *密码: *//p')
	pg -d app -c "CREATE TABLE t (x int); INSERT INTO t VALUES (1)"
	"$DP" db users postgres app_user >/dev/null

	"$DP" db backup postgres app
	f=$(newest "$d"/backups/app_*.sql*)
	pg -d app -c "UPDATE t SET x = 2"
	printf 'y\n' | "$DP" db restore postgres "$f"
	expect_eq "$(pg -d app -c 'SELECT x FROM t')" 1 "单库恢复覆盖已有库"
	[ -n "$(newest "$d"/backups/app_*before-restore*)" ] || fail "覆盖前没有留快照"

	"$DP" db backup postgres
	fa=$(newest "$d"/backups/all_databases_*)
	pg -d app -c "UPDATE t SET x = 3"
	printf 'y\n' | "$DP" db restore postgres "$(basename "$fa")" app
	expect_eq "$(pg -d app -c 'SELECT x FROM t')" 1 "从整库备份里恢复一个库"
	expect_fail sh -c "printf 'y\n' | '$DP' db restore postgres '$fa'"
	ok "实例里已有库时拒绝整个导入"

	# 属主被删掉后恢复：先报错，不先删库
	printf 'y\n' | "$DP" db drop postgres app app_user
	expect_fail sh -c "printf '' | '$DP' db restore postgres '$f'"
	case $OUT in *属主*) ok "属主不存在时提示" ;; *) fail "没有提示属主：${OUT}" ;; esac
	pg -d postgres -c "CREATE ROLE app_user LOGIN PASSWORD 'x'"
	"$DP" db restore postgres "$f"
	expect_eq "$(pg -d app -c 'SELECT x FROM t')" 1 "建回属主后恢复"

	# 只剩默认库时可以整个导入
	printf 'y\n' | "$DP" db drop postgres app app_user
	printf 'y\n' | "$DP" db restore postgres "$fa"
	expect_eq "$(pg -d app -c 'SELECT x FROM t')" 1 "整个导入"

	# POSTGRES_DB 写成业务库时，恢复这个库也要能删旧库重建
	edit 's/^POSTGRES_DB=.*/POSTGRES_DB=app/' "$d/.env"
	pg -d app -c "UPDATE t SET x = 4"
	printf 'y\n' | "$DP" db restore postgres "$f"
	expect_eq "$(pg -d app -c 'SELECT x FROM t')" 1 "POSTGRES_DB 是要恢复的库时也能恢复"
	edit 's/^POSTGRES_DB=.*/POSTGRES_DB=postgres/' "$d/.env"

	"$DP" update PostgreSQL
	"$DP" db backup all

	# 已有的用户再建库：没给密码时不动它的密码，原来的照样能登录（走 TCP 才校验密码）
	OUT=$("$DP" db create postgres app2 app_user)
	case $OUT in *密码没有改*) ok "postgres 已有用户再建库时提示密码没改" ;; *) fail "没有提示密码没改：${OUT}" ;; esac
	expect_eq "$(docker exec postgres psql "host=127.0.0.1 user=app_user dbname=app2 password=${pw}" -Atc 'SELECT 1' 2>&1)" 1 "postgres 已有用户再建库后原密码照样能登录"

	expect_fail sh -c "printf 'y\n' | '$DP' db restore postgres '$fa' postgres"
	case $OUT in *维护库*) ok "拒绝恢复 postgres 维护库" ;; *) fail "恢复 postgres 库时的提示不对：${OUT}" ;; esac
}

# MariaDB、MySQL 的脚本是同一份，按类型换客户端和变量名
mysqlish() {
	local type=$1 dir=$2 client=$3 rootvar=$4 d f fa pw
	d=$P/$dir
	sq() { docker exec -i "$type" sh -c "$client -uroot -p\"\$$rootvar\" -N \"\$@\" 2>/dev/null" sh "$@"; }

	"$DP" db new "$type"
	pw=$("$DP" db create "$type" app app_user | sed -n 's/^ *密码: *//p')
	[ -n "$pw" ] || fail "create-db 没打印密码"
	sq app -e "CREATE TABLE t (x int); INSERT INTO t VALUES (1)"
	"$DP" db users "$type" app_user >/dev/null

	"$DP" db backup "$type" app
	f=$(newest "$d"/backups/app_*.sql*)
	sq app -e "UPDATE t SET x = 2"
	printf 'y\n' | "$DP" db restore "$type" "$f"
	expect_eq "$(sq app -e 'SELECT x FROM t')" 1 "$type 单库恢复"

	"$DP" db backup "$type"
	fa=$(newest "$d"/backups/all_databases_*)
	sq app -e "UPDATE t SET x = 3"
	printf 'y\n' | "$DP" db restore "$type" "$fa" app
	expect_eq "$(sq app -e 'SELECT x FROM t')" 1 "$type 从整库备份里恢复一个库"
	expect_fail sh -c "printf 'y\n' | '$DP' db restore $type '$fa'"
	ok "$type 实例里已有库时拒绝整个导入"

	printf 'y\n' | "$DP" db drop "$type" app app_user
	expect_fail sh -c "printf 'y\n' | '$DP' db restore $type '$f'"
	ok "$type 库不存在时拒绝单库恢复"

	# 整个导入后用户要能登录（导入 mysql 库后要 FLUSH PRIVILEGES）
	printf 'y\n' | "$DP" db restore "$type" "$fa"
	expect_eq "$(sq app -e 'SELECT x FROM t')" 1 "$type 整个导入"
	expect_eq "$(docker exec "$type" "$client" -uapp_user -p"$pw" -N app -e 'SELECT x FROM t' 2>/dev/null)" 1 "$type 导入后用户能登录"

	# 换成全新的实例（升级大版本时的做法）再整个导入：健康检查要照样通过
	(cd "$d" && docker compose down && docker volume rm "$type-data" >/dev/null && docker volume create "$type-data" >/dev/null &&
		docker compose up -d --wait)
	# 新实例的 root 密码和备份里的不同：.env 写新实例的，导入后 root 变成备份里的（容器环境变量里那个）
	sq -e "ALTER USER 'root'@'%' IDENTIFIED BY 'e2e-other'; ALTER USER 'root'@'localhost' IDENTIFIED BY 'e2e-other'"
	cp "$d/.env" "$d/.env.orig"
	edit "s/^${rootvar}=.*/${rootvar}=e2e-other/" "$d/.env"
	printf 'y\n' | "$DP" db restore "$type" "$fa"
	mv "$d/.env.orig" "$d/.env"
	expect_eq "$(sq app -e 'SELECT x FROM t')" 1 "$type 新实例整个导入"
	# shellcheck disable=SC2046
	docker exec "$type" $(docker inspect -f '{{range $i, $a := .Config.Healthcheck.Test}}{{if $i}}{{$a}} {{end}}{{end}}' "$type") >/dev/null 2>&1 ||
		fail "$type 新实例整个导入后健康检查不通过"
	ok "$type 新实例整个导入后健康检查通过"

	# 已有的用户再建库：没给密码时不动它的密码，原来的照样能登录；给了密码就换成新的
	OUT=$("$DP" db create "$type" app2 app_user)
	case $OUT in *密码没有改*) ok "$type 已有用户再建库时提示密码没改" ;; *) fail "没有提示密码没改：${OUT}" ;; esac
	expect_eq "$(docker exec "$type" "$client" -uapp_user -p"$pw" -N app2 -e 'SELECT 1' 2>/dev/null)" 1 "$type 已有用户再建库后原密码照样能登录"
	"$DP" db create "$type" app3 app_user e2e-new-pass >/dev/null
	expect_eq "$(docker exec "$type" "$client" -uapp_user -pe2e-new-pass -N app3 -e 'SELECT 1' 2>/dev/null)" 1 "$type 给了密码时换成新密码"
}

group_mariadb() { mysqlish mariadb MariaDB mariadb MARIADB_ROOT_PASSWORD; }
group_mysql() { mysqlish mysql MySQL mysql MYSQL_ROOT_PASSWORD; }

group_valkey() {
	"$DP" db new valkey
	expect_eq "$(docker exec valkey sh -c 'valkey-cli --no-auth-warning -a "$VALKEY_PASSWORD" ping')" PONG "valkey 带密码连接"
}

srv() { docker exec dp-e2e-server sh -c "$1"; }

# 拉取模式的镜像：内容是版本号，推到测试用的镜像仓库
push_image() {
	printf 'FROM busybox:1.37\nRUN mkdir /www && echo %s > /www/index.html\nCMD ["httpd", "-f", "-p", "8080", "-h", "/www"]\n' "$2" |
		docker build -q -t "127.0.0.1:5000/e2e/pullapp:$1" - >/dev/null
	docker push -q "127.0.0.1:5000/e2e/pullapp:$1" >/dev/null
}

group_remote() {
	ssh e2e-server true

	local a=$P/pullapp b=$P/pushapp sha1 sha2 bad
	mkdir -p "$a"
	cp -R "$REPO/templates/deploy/pull/." "$a/"
	printf 'services:\n  app:\n    image: busybox:1.37\n' >"$a/compose.yaml"
	edit 's/^name: PROJECT$/name: pullapp/; s#ghcr.io/OWNER/REPO#127.0.0.1:5000/e2e/pullapp#' "$a/deploy/compose.yaml"
	git -C "$a" init -q
	git_commit "$a" v1
	sha1=$(git -C "$a" rev-parse HEAD)
	echo 2 >"$a/version"
	git_commit "$a" v2
	sha2=$(git -C "$a" rev-parse HEAD)
	push_image "$sha1" v1
	push_image "$sha2" v2
	git clone -q --bare "$a" "$WORK/origin/pullapp.git"
	srv "git clone -q '$WORK/origin/pullapp.git' /srv/pullapp && cp /srv/pullapp/deploy/.env.example /srv/pullapp/deploy/.env"
	printf 'COMPOSE_PROJECT_NAME=pullapp\nDEPLOY_MODE=pull\nDEPLOY_HOST=e2e-server\nDEPLOY_DIR=/srv/pullapp/deploy\n' >"$a/.env"

	(cd "$a" && "$DP" deploy)
	expect_http http://pullapp-app-1:8080 v2
	"$DP" rollback pullapp "$sha1"
	expect_http http://pullapp-app-1:8080 v1
	expect_eq "$(srv "sed -n 's/^IMAGE_TAG=//p' /srv/pullapp/deploy/.env")" "$sha1" "回滚后 .env 记下的版本"
	expect_fail "$DP" deploy pullapp 0000000000000000000000000000000000000000
	expect_http http://pullapp-app-1:8080 v1
	expect_fail "$DP" deploy pullapp 'x;true'
	ok "拒绝带特殊字符的版本"
	push_image "$sha1" v1-patched
	"$DP" patch pullapp
	expect_http http://pullapp-app-1:8080 v1-patched
	# 镜像拉得下来但健康检查不过：自动换回原来的版本，.env 不变
	bad=1111111111111111111111111111111111111111
	printf 'FROM busybox:1.37\nHEALTHCHECK --interval=1s --retries=2 CMD false\nCMD ["httpd", "-f", "-p", "8080"]\n' |
		docker build -q -t "127.0.0.1:5000/e2e/pullapp:$bad" - >/dev/null
	docker push -q "127.0.0.1:5000/e2e/pullapp:$bad" >/dev/null
	expect_fail "$DP" deploy pullapp "$bad"
	expect_http http://pullapp-app-1:8080 v1-patched
	expect_eq "$(srv "sed -n 's/^IMAGE_TAG=//p' /srv/pullapp/deploy/.env")" "$sha1" "新版本起不来时退回原来的版本"

	mkdir -p "$b"
	cp -R "$REPO/templates/deploy/push/." "$b/"
	printf 'services:\n  app:\n    image: busybox:1.37\n' >"$b/compose.yaml"
	cat >"$b/deploy/compose.yaml" <<'EOF'
name: pushapp
services:
  app:
    image: busybox:1.37
    command: ["sh", "-c", "mkdir -p /www && echo v1 > /www/index.html && exec httpd -f -p 8080 -h /www"]
    networks: [docker-net]
  postgres:
    image: postgres:18-trixie
    environment:
      POSTGRES_USER: app
      POSTGRES_DB: app
      POSTGRES_PASSWORD: ${PG_PASSWORD:?}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 2s
      retries: 30
    networks: [docker-net]
networks:
  docker-net:
    external: true
    name: docker-net
EOF
	git -C "$b" init -q
	git_commit "$b" v1
	srv "mkdir -p /srv/pushapp && echo PG_PASSWORD=e2e > /srv/pushapp/.env"
	# 值带引号也要认（compose 的写法）
	printf '%s\n' COMPOSE_PROJECT_NAME=pushapp DEPLOY_MODE=push 'DEPLOY_HOST="e2e-server"' "DEPLOY_DIR='/srv/pushapp'" >"$b/.env"

	"$DP" deploy pushapp
	expect_http http://pushapp-app-1:8080 v1
	edit 's/echo v1/echo v2/' "$b/deploy/compose.yaml"
	expect_fail "$DP" deploy pushapp
	ok "deploy/ 有未提交的改动时拒绝"
	git_commit "$b" v2
	"$DP" deploy pushapp
	expect_http http://pushapp-app-1:8080 v2
	expect_eq "$(srv 'cat /srv/pushapp/REVISION')" "$(git -C "$b" rev-parse --short HEAD)" "REVISION 记下的版本"
	"$DP" rollback pushapp HEAD~1
	expect_http http://pushapp-app-1:8080 v1

	"$DP" -y deploy all --host e2e-server
	expect_http http://pullapp-app-1:8080 v2
	expect_http http://pushapp-app-1:8080 v2
	OUT=$("$DP" remote-status)
	case $OUT in *pushapp-postgres-1*) ok "remote-status" ;; *) fail "remote-status 里没有 pushapp：${OUT}" ;; esac

	"$DP" backup pushapp
	[ -s "$(newest "$P"/backup/pushapp/db_*.dump)" ] || fail "没拉回数据库备份"
	[ -n "$(newest "$P"/backup/pushapp/env_*.tgz)" ] || fail "没拉回 .env 备份"
	expect_eq "$(mode_of "$(newest "$P"/backup/pushapp/db_*.dump)")" 600 "备份文件只有自己能读"
	"$DP" backup pullapp env
	[ -n "$(newest "$P"/backup/pullapp/env_*.tgz)" ] || fail "没拉回 pullapp 的 .env 备份"
	expect_fail "$DP" backup pullapp 'env;true'

	expect_fail "$DP" deploy pullapp --host
	case $OUT in *ssh\ 别名*) ok "--host 缺值时提示" ;; *) fail "--host 缺值没有提示：${OUT}" ;; esac
	expect_fail "$DP" deploy web
	ok "没有部署设置的项目拒绝部署"
}

[ $# -gt 0 ] || set -- project postgres mariadb mysql valkey remote
FAILED=""
for g in "$@"; do
	echo "=== $g"
	# 子 shell 放进 if 会忽略 set -e，所以先关掉，在子 shell 里重新打开
	set +e
	(
		set -e
		"group_$g"
	)
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || FAILED="$FAILED $g"
done
if [ -n "$FAILED" ]; then
	echo "失败的组：${FAILED}" >&2
	exit 1
fi
echo "全部通过"
