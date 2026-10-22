# 设计

本文记录这个仓库为什么是现在这个样子。用法见根目录和各目录的 README。

## 要解决的事

1. 开发机不装语言运行时和依赖，Node、Go、pnpm、依赖都在容器里，容器重建不丢依赖和缓存。
2. 很多相似的项目，彼此只有小差别。新建、复制项目时选一下就行，各项目的 Dockerfile 不越改越不一样。
3. 升级省事：Node、Go 跟着官方走，一条命令拿到；数据库停在大版本线上，到期前有提醒。
4. 生产也从这里出：构建、部署、回滚、备份有固定做法。

## 决定

| 项 | 决定 | 依据 |
|---|---|---|
| 仓库的角色 | 只放模板和 `dp`，项目复制出去后不引用仓库 | 服务器和部分开发机不克隆仓库；项目只用官方镜像，运行时不引用仓库里的任何东西 |
| 基础镜像 | 直接用官方镜像，标签跟官方浮动：`node:lts-trixie-slim`、`golang:trixie`、`caddy:alpine`、`gcr.io/distroless/static:nonroot` | 自定义的内容少（CA 证书、pnpm、几个环境变量），几行 Dockerfile 就够，不值得维护一套镜像和它的 CI。浮动标签由官方更新，`build --pull` 就拿到。Node、Go 的大版本也跟官方走：官方认定的长期支持版、最新版就是要用的版本。Debian 版本 `trixie` 写明：`node:lts-slim` 这类不写系统名的标签官方为兼容还停在上一版 Debian，下一版 Debian 出来时手动改这两行 |
| 不钉 digest | Dockerfile 和数据库 compose 都只写标签 | 钉 digest 要靠工具不停改文件，每个项目都改一遍；补丁要能自动到达；要挡住大版本的（数据库）在标签里写版本线 |
| Dockerfile 统一 | 各项目保持模板原样，差别放 `compose.yaml`、`.env`、构建参数 `OUTPUT_DIR` | 一个文件三段（dev、build、runtime），开发和生产用同一个基础镜像，复制即可，不用生成器 |
| 开发容器 | 启动就跑开发服务器：Node `pnpm install && pnpm dev --host`，Go `go tool air` | 空转再 exec 进去多一步；依赖变了重启容器就装上 |
| 支持的机器 | 只支持 Mac 加 OrbStack | 只在 Mac 上开发；OrbStack 下 bind mount 的文件属主自动对上，不用处理 uid |
| 访问 | OrbStack 域名 `<项目名>.orb.local`，要端口时 `.env` 里打开 `COMPOSE_FILE` 合并 `compose.ports.yaml` | 多个项目同时开不抢端口，自带 https |
| 时区 | 开发容器、生产 compose、数据库、服务器都能设，默认 `Asia/Tokyo`：项目和数据库在 `.env` 的 `TZ`，服务器是 `setup.sh` 的 `TZ_NAME` | 官方镜像默认 UTC；不同服务器、项目可能要不同时区。Node 自带时区数据，golang、distroless 镜像带 `/usr/share/zoneinfo`，Caddy 日志是 Unix 时间戳，都不用另装 |
| 依赖和缓存 | `node_modules` 每个项目一个 volume；pnpm store、Go 模块和编译缓存所有项目共用一个 volume | 不落到宿主机，原生模块不跨平台；共用后一个包只下载一次 |
| pnpm | 镜像里 `npm install -g pnpm`，项目 `packageManager` 写版本，pnpm 按它自动切换 | corepack 从 Node 25 起不随 Node 发行。`node:lts` 2026-10-28 换到 26 时不用改什么 |
| 项目依赖更新 | 各项目仓库自己的 Dependabot，满 3 天才开 PR，非大版本自动合并 | 官方运行时不设冷却期，第三方依赖要观察几天；小版本人工看没有意义 |
| 数据库 | 和项目一样是模板，`dp db new` 复制到 `~/Cores/Projects/<名字>`；标签写到大版本线（`postgres:18-trixie`、`mariadb:12.3`、`mysql:9.7`、`valkey/valkey:9.1-trixie`） | `mariadb:lts`、`mysql:lts` 会自动跳大版本，大版本要导出导入，不能自动换 |
| 大版本提醒 | 仓库 CI 每周查 endoflife.date，离停止支持不到半年开 issue | 版本线停在原地，到期前要有人知道 |
| 数据卷 | `<类型>-data`，标 `external` | `down -v` 和 compose 的命令都删不到数据 |
| 数据库备份 | 导出 SQL，不拷数据目录；`dp db backup` 整库，留 5 份；改动前快照留 30 天；`restore.sh` 恢复前先给目标库做快照 | 拷数据文件要先停库；恢复会覆盖库，留一份回退用 |
| 命令 | 一个 bash 脚本 `dp`，加 `cli/` 下三个子文件，从仓库运行，不装到系统 | 只靠系统自带的 bash 3.2 和 docker，不往系统目录放东西 |
| 找项目 | 扫描 `~/Cores/Projects` 下一层有 compose 文件的目录；在项目目录里可省略项目名 | 项目都在那里，不用另建清单 |
| 批量操作 | `all` 时一个失败不停，最后汇总，有失败退出码非 0 | 一个项目坏了不该挡住其他项目的补丁 |
| 部署 | 两种模板：拉取（服务器有仓库，CI 按提交号构建镜像）和推送（本机把 `deploy/` 传过去） | 两种都在用：自己写的服务用拉取，跑别人发布的镜像用推送 |
| 部署设置 | 写在项目根 `.env` 的 `DEPLOY_MODE`、`DEPLOY_HOST`、`DEPLOY_DIR` | 一台开发机对多台服务器；服务器地址不进 git |
| 服务器备份 | 各项目自己的 `deploy/backup.sh`，`dp backup` 送到服务器执行再拉回本机 | 每个项目要备份的东西不同，按项目、按项备份 |
| 服务器初始化 | `server/setup.sh` 一行 curl 运行，可重复跑 | 服务器上不克隆仓库 |
| 服务器补丁 | unattended-upgrades 装系统安全更新和 Docker，需要时定时重启；镜像补丁用 `dp patch` | 有的云镜像去掉了 `-security` 源；Docker 来自官方源，默认不在自动更新范围 |

## 不做的

- 不做生成器：模板复制出去就是最终文件。
- 不做项目和模板的一致性检查：Dockerfile 原样复制，`dp update` 只依赖标签。
- 不自动换数据库大版本，不做部署锁，不做删除项目、清理命令。

## 已查证的事实

### OrbStack（2.2.3）、Vite

- 不映射端口时，标签 `dev.orbstack.domains` 给的 `https://<项目名>.orb.local` 能访问容器内的开发服务器，证书宿主机直接信任。
- Vite 默认对 `.orb.local` 主机名返回 403，环境变量 `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=.orb.local` 后返回 200。
- Mac 上改 bind mount 里的文件，容器内 `fs.watch` 收得到，不用开 `usePolling`；热重载 WebSocket 经 https 域名握手返回 101。
- bind mount 的文件在容器内一律显示为当前容器 uid。
- `node:lts-trixie-slim` 没有 `ca-certificates`；装上并设 `NODE_USE_SYSTEM_CA=1` 后，容器里的 Node 访问 `https://*.orb.local` 返回 200。

### pnpm 12

- 跨 named volume 硬链接报 `Invalid cross-device link`，所以 store 和 `node_modules` 不在同一卷时用复制；store 不显式指定时会建到 `node_modules/.pnpm-store`，共享落空。只认 `pnpm_config_*` 前缀的环境变量。
- 按 `packageManager` 自动下载切换版本，开关 `pmOnFail`，默认 `download`。
- 默认拦截依赖的安装脚本，报 `ERR_PNPM_IGNORED_BUILDS`，要在 `allowBuilds` 里放行。
- `minimumReleaseAge` 也对已在 lockfile 里的条目生效；交互安装时放行会写进 `minimumReleaseAgeExclude`。
- 没有终端时删 `node_modules` 前的确认会失败，设 `pnpm_config_confirm_modules_purge=false`。

### compose（5.1.2）、Docker

- 一个项目建的卷，另一个项目只写 `name:` 不写 `external` 时警告 `already exists but was created for project ...`，之后 `down -v` 会删它；共用缓存卷接受这个行为。
- 网络标 `external` 时不存在 `up` 就报错，`down` 不删；不标时网络归先起的项目，后起的收到警告。
- `docker volume prune -a` 只看有没有容器挂载这个卷，已停止的容器也算。
- `docker volume create` 对已存在的卷返回 0，`docker network create` 对已存在的网络返回 1，所以先 `inspect` 再建。
- `docker compose exec -T` 会读走标准输入，脚本里管道后面的交互确认要从 `/dev/null` 隔开。

### 数据库

- MariaDB 12.3、MySQL 9.7、PostgreSQL 18 的入口脚本以 root 启动时把数据目录里属主不对的文件改成镜像用户。
- `pg_dumpall` 的输出每个库一段，以 `-- Database "x" dump` 开头，等同 `pg_dump --create`；`restore.sh` 按它从整库备份里取出一个库。
- `mysqldump --all-databases` 每个库一段，以 ``-- Current Database: `x` `` 开头；MySQL 的导出带 `SET @@GLOBAL.GTID_PURGED`，导回已有数据的实例报错 3546，所以备份加 `--set-gtid-purged=OFF`，恢复时也滤掉这行。
- MariaDB 导入 `mysql` 库后要 `FLUSH PRIVILEGES`，否则导入的用户登录不了。

### 服务器

- Ubuntu 26.04 默认的 unattended-upgrades 包含 `-security`；`Origins-Pattern` 在另一个文件里追加时和默认列表合并。
- Docker 官方 apt 源的 Release 里 Origin 是 `Docker`，Suite 是系统代号。
- Ubuntu 的 `ssh.socket` 激活时 `sshd_config` 的 `Port` 不生效，端口由 socket 单元决定；它设了 `BindIPv6Only=ipv6-only`，IPv4、IPv6 要分开写。
