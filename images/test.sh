#!/bin/sh
# 用法: images/test.sh <node 镜像> <go 镜像>
# 对已构建好的两个镜像做冒烟测试，CI 推送前和本机改完 Dockerfile 后都跑这个。
set -eu

NODE_IMAGE=${1:?用法: test.sh <node 镜像> <go 镜像>}
GO_IMAGE=${2:?用法: test.sh <node 镜像> <go 镜像>}

ALT_UID=1234
ALT_GID=1234
VOL_PREFIX="devimg-test-$$"
trap 'docker volume ls -q --filter "name=${VOL_PREFIX}" | xargs -r docker volume rm >/dev/null; docker image rm -f "${NODE_IMAGE}-fixed" "${GO_IMAGE}-fixed" >/dev/null 2>&1 || true' EXIT

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1" >&2; exit 1; }

# 用项目 compose 里同样的内嵌指令，构建一个 uid 改成 ALT_UID 的派生镜像
build_fixed() {
	base=$1
	user=$2
	printf 'FROM %s\nUSER root\nRUN fix-user %s %s\nUSER %s\n' "$base" "$ALT_UID" "$ALT_GID" "$user" \
		| docker build -q -t "${base}-fixed" - >/dev/null
}

echo "== node: $NODE_IMAGE"

out=$(docker run --rm "$NODE_IMAGE" sh -c 'id -u; id -g; whoami; node --version; pnpm --version; echo "$PNPM_HOME"; pnpm store path; cat /etc/timezone 2>/dev/null || echo "$TZ"')
echo "$out" | sed -n '1p' | grep -qx 1000 || fail "node 镜像默认 uid 不是 1000"
echo "$out" | sed -n '3p' | grep -qx node || fail "node 镜像默认用户不是 node"
echo "$out" | sed -n '4p' | grep -q '^v24\.' || fail "Node 大版本不是 24"
echo "$out" | sed -n '7p' | grep -q '^/home/node/.local/share/pnpm/store' || fail "pnpm store 不在 PNPM_HOME 下: $(echo "$out" | sed -n '7p')"
pass "node 默认用户、版本、store 位置"

docker run --rm "$NODE_IMAGE" sh -c 'git --version >/dev/null && test -s /etc/ssl/certs/ca-certificates.crt' || fail "node 镜像缺 git 或 CA 证书"
pass "node 镜像带 git 和 CA 证书"

docker run --rm -v "${VOL_PREFIX}-nm:/app/node_modules" -v "${VOL_PREFIX}-pnpm:/home/node/.local/share/pnpm" "$NODE_IMAGE" \
	sh -c 'touch /app/node_modules/x /home/node/.local/share/pnpm/x' || fail "node 用户写不进空 volume"
pass "node 空 volume 首次挂载可写"

build_fixed "$NODE_IMAGE" node
out=$(docker run --rm -v "${VOL_PREFIX}-nm2:/app/node_modules" "${NODE_IMAGE}-fixed" sh -c 'id -u; whoami; touch /app/node_modules/x && echo ok; node -e "console.log(require(\"os\").userInfo().username)"')
echo "$out" | sed -n '1p' | grep -qx "$ALT_UID" || fail "fix-user 后 uid 不是 $ALT_UID"
echo "$out" | sed -n '2p' | grep -qx node || fail "fix-user 后用户名丢失"
echo "$out" | sed -n '3p' | grep -qx ok || fail "fix-user 后写不进 volume"
echo "$out" | sed -n '4p' | grep -qx node || fail "fix-user 后 os.userInfo 读不到用户"
pass "node fix-user 改 uid 为 $ALT_UID 后用户记录、volume 属主正确"

# 项目文件在容器内生成：CI runner 的 uid 和镜像用户不同，bind mount 宿主机目录会写不进去
docker run --rm -v "${VOL_PREFIX}-nm3:/app/node_modules" -v "${VOL_PREFIX}-pnpm:/home/node/.local/share/pnpm" "$NODE_IMAGE" sh -c '
	set -e
	cd /app
	printf "{ \"name\": \"smoke\", \"private\": true, \"packageManager\": \"pnpm@%s\" }\n" "$(pnpm --version)" > package.json
	printf "allowBuilds:\n  sharp: true\n" > pnpm-workspace.yaml
	pnpm add sharp >/dev/null
	node -e "require(\"sharp\")"
	test -d /home/node/.local/share/pnpm/store
' || fail "pnpm add sharp 或加载失败"
pass "pnpm 安装带二进制的包并写入共享 store"

echo "== go: $GO_IMAGE"

out=$(docker run --rm "$GO_IMAGE" sh -c 'id -u; whoami; go version; go env GOMODCACHE GOCACHE')
echo "$out" | sed -n '1p' | grep -qx 1000 || fail "go 镜像默认 uid 不是 1000"
echo "$out" | sed -n '2p' | grep -qx go || fail "go 镜像默认用户不是 go"
echo "$out" | sed -n '3p' | grep -q 'go1\.' || fail "go version 失败"
echo "$out" | sed -n '4p' | grep -qx /go/pkg/mod || fail "GOMODCACHE 不是 /go/pkg/mod"
echo "$out" | sed -n '5p' | grep -qx /go/cache || fail "GOCACHE 不是 /go/cache"
pass "go 默认用户、版本、缓存位置"

docker run --rm "$GO_IMAGE" sh -c 'git --version >/dev/null && test -s /etc/ssl/certs/ca-certificates.crt' || fail "go 镜像缺 git 或 CA 证书"
pass "go 镜像带 git 和 CA 证书"

docker run --rm -v "${VOL_PREFIX}-gomod:/go/pkg/mod" -v "${VOL_PREFIX}-gocache:/go/cache" "$GO_IMAGE" sh -c '
	set -e
	cd /app
	printf "package main\n\nimport \"fmt\"\n\nfunc main() { fmt.Println(\"ok\") }\n" > main.go
	go mod init smoke >/dev/null 2>&1
	go build -o /tmp/smoke .
	/tmp/smoke | grep -qx ok
	test -n "$(ls -A /go/cache)"
' || fail "go build 失败或编译缓存没写进 volume"
pass "go 编译并写入共享缓存"

build_fixed "$GO_IMAGE" go
out=$(docker run --rm -v "${VOL_PREFIX}-gomod2:/go/pkg/mod" "${GO_IMAGE}-fixed" sh -c 'id -u; whoami; touch /go/pkg/mod/x && echo ok')
echo "$out" | sed -n '1p' | grep -qx "$ALT_UID" || fail "go fix-user 后 uid 不是 $ALT_UID"
echo "$out" | sed -n '2p' | grep -qx go || fail "go fix-user 后用户名丢失"
echo "$out" | sed -n '3p' | grep -qx ok || fail "go fix-user 后写不进 volume"
pass "go fix-user 改 uid 为 $ALT_UID 后用户记录、volume 属主正确"

echo "全部通过"
