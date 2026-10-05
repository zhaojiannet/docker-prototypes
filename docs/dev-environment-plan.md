# 开发容器环境方案

状态：已定，2026-10-03。本文记录这个仓库要做成什么样以及每条决定的依据。实施完成后，各目录的 README 以代码为准，本文只保留决定和依据。

## 目标

一台机器上的所有 Node、Go 项目用同一套开发容器环境，满足四条要求：

1. 宿主机不安装任何语言运行时和依赖。
2. 依赖安装在容器内。
3. 依赖和缓存持久化，容器重建不丢。
4. 容器写到 bind mount 目录里的文件，和宿主机用户没有属主冲突。

同时解决「每个项目各抄一份配置，越抄越不一样」的问题：环境的定义只在一处（基础镜像），项目里只剩一份很短的 compose。

## 决定

| 项 | 决定 | 依据 |
|---|---|---|
| 支持的机器 | macOS（OrbStack）和 Linux；镜像出 `linux/arm64` 和 `linux/amd64` | 本机是 arm64 Mac，CI 和服务器是 amd64 Linux |
| 使用者 | 本人和 AI 代理为主；仓库公开，别人能直接拿走 | 不写只在本机才成立的假设 |
| 基础系统 | Debian 稳定版 slim（当前 trixie） | glibc；实测 sharp、wrangler 在 trixie-slim 直接可用，Alpine 的 musl 对带二进制的 npm 包不友好 |
| 镜像 | `dev-node`、`dev-go` 两个，共用同一套底层设置 | Node 和 Go 升级节奏不同，合成一个会互相牵连 |
| Node 大版本 | 只出当前长期支持版 | 现在是 24；Node 26 于 2026-10-28 转为长期支持版后换 26，24 的旧标签保留 |
| pnpm 安装 | 镜像内用 npm 装一个确定版本的 pnpm | corepack 从 Node 25 起不再随 Node 发行，不能再依赖它 |
| pnpm 版本与项目的关系 | 项目 `package.json` 的 `packageManager` 写和镜像相同的版本 | 实测 pnpm 12 会按该字段自动下载切换版本（开关 `pmOnFail`），一致时不下载 |
| 标签 | 每次构建推两个：版本标签如 `dev-node:24.21.0-pnpm12.8.1`，指向该组版本的最新一次构建；构建号标签如 `dev-node:24.21.0-pnpm12.8.1-r42`，永不覆写。不提供 `latest` | 版本号不变的 Debian 安全补丁要能到达 ghcr，纯不覆写的标签做不到；要完全钉死的项目用构建号标签 |
| 可见性 | 仓库和镜像都公开，放个人账号 `zhaojiannet` | 个人和公司项目都用，公开镜像任何机器免登录可拉；仓库内容已审查无凭证 |
| 源码 | 宿主机目录 bind mount 到容器 `/app` | 编辑器和 git 在宿主机工作 |
| node_modules | 每个项目一个 named volume，挂在 `/app/node_modules` | 不落到宿主机目录；原生模块不跨平台 |
| pnpm store 与缓存 | 所有 Node 项目共用一个 named volume，安装时从 store 复制到项目 | 实测跨 volume 硬链接报 EXDEV，同卷子目录分别挂载也一样；复制模式仍只下载一次 |
| Go 缓存 | 模块缓存、编译缓存各一个 named volume，所有 Go 项目共用 | Go 模块缓存按内容寻址，官方设计上可共用 |
| 构建产物 | `dist`、`.astro`、`.wrangler`、Go 二进制留在项目目录，靠 `.gitignore` | 它们不是依赖，宿主机要能看到构建结果 |
| uid | 项目 compose 用 `dockerfile_inline` 内嵌 `FROM` 加五行构建指令，在基础镜像上按 `PUID`、`PGID` 调用镜像自带的 `fix-user` 改用户记录和挂载点属主，默认 1000 | Linux 上容器 uid 就是宿主机 uid，不一致就冲突。构建时改而不是启动时改，因为 `docker compose exec` 不经过入口脚本，启动时改需要容器以 root 运行，exec 进去的命令就都是 root。Mac 上实测 OrbStack 把 bind mount 文件一律显示为当前容器 uid，任意 uid 可写，此步在 Mac 上是空操作 |
| 项目引用方式 | 项目目录里只有 `compose.yaml`，基础镜像的标签写在内嵌构建指令的 `FROM` 行 | 要额外系统库的项目再换成一个独立的 Dockerfile |
| 进容器方式 | 容器空转，命令全部 `docker compose exec` 执行 | 不做编辑器挂进容器，不引入 Dev Containers CLI |
| 共享服务 | PostgreSQL、MariaDB、MySQL、Valkey 各自一个目录一个 compose，按需起 | 四种都要，但不一次全装 |
| 共享网络 | 各 compose 都声明同名网络 `dev-net`，不标 `external` | 实测先起的建网络，后起的直接加入，先停任何一个不影响另一个；不需要手动建网络 |
| 版本更新 | Dependabot 开 PR，CI 构建验证通过后人工合并；新版本发布满 3 天才升。pnpm 版本写在 `images/node/package.json` 的依赖里，由 Dependabot 的 npm 生态盯 | GitHub 内置，不装第三方 App、不给外部服务仓库权限。Dependabot 认不出 Dockerfile 里 `ARG` 的版本号，写在 `package.json` 里它能按 npm 包处理，冷却和忽略大版本的规则照用 |
| 模板里的镜像标签 | `images.yml` 推送成功后改 `templates/*/compose.yaml` 的 `FROM` 标签，直接提交到 main | 推送成功后标签一定存在；改的只是一个版本号，升级本身已在 Dependabot 的 PR 里人工审过。个人仓库默认不允许工作流开 PR，直接提交不用改仓库设置 |
| 访问方式 | 默认用 OrbStack 域名 `<项目名>.orb.local`，不映射端口；要端口时 `.env` 里用 `COMPOSE_FILE` 合并 `compose.ports.yaml` | 多个项目同时开不抢端口，OrbStack 自带 https。`COMPOSE_FILE` 写在 `.env` 是 compose 文档给的用法，切换只改一行；`compose.override.yaml` 会被自动读取，留给项目自己用 |
| 漏洞扫描 | Trivy 每次构建扫一次；镜像每周一定时重建，重建里也扫 | `apt-get upgrade` 只在构建时跑，Debian 的安全补丁要靠重建带上 |
| 泄漏扫描 | gitleaks 跑在 CI | 仓库公开 |

## 目录

```
docker-prototypes/
  images/
    node/        Dockerfile、package.json（只登记 pnpm 版本）
    go/          Dockerfile
    common/      fix-user.sh
    test.sh
  templates/
    node/        compose.yaml、compose.ports.yaml、.env.example、README.md
    go/          compose.yaml、compose.ports.yaml、.env.example、README.md
  services/
    postgres/    compose.yaml、.env.example、conf/、init-scripts/
    mariadb/
    mysql/
    valkey/
  .github/        workflows/、dependabot.yml
  new-project.sh
  docs/
  README.md
```

`new-project.sh` 把「复制模板、写 `.env`、起容器、跑脚手架」合成一条命令，带参数直接执行，不带参数逐项问。只用 bash 和 docker，宿主机不多装东西；有参数形式是为了让 AI 代理也能调用。

`images/` 是被引用的，`templates/` 是复制出去用的，`services/` 是起在本机的。三类更新节奏不同，分开放。

## 镜像

两个镜像共用的部分：

- 以官方 `node:<ver>-trixie-slim` 或 `golang:<ver>-trixie` 为底，`FROM` 同时写标签和 digest。
- 安装 `ca-certificates`、`tzdata`、`git`，`TZ` 默认 `Asia/Tokyo`。
- 普通用户 uid 1000。Node 镜像沿用自带的 `node` 用户；Go 官方镜像默认是 root、没有普通用户，自己建一个。
- 预建所有会被 named volume 覆盖的挂载点并设属主为 1000。空 volume 首次挂载会继承镜像内目录的属主，不预建就是 root 的、普通用户写不进去（实测）。
- 带 `fix-user` 脚本（`images/common/fix-user.sh`）：以 root 在构建时调用，参数是目标 uid、gid，和当前用户不同就改用户记录并修正家目录和 `DEV_DIRS` 列出的挂载点属主。默认命令是空转。

Node 镜像另有：

- `npm install -g pnpm@<ver>`，版本构建时从 `images/node/package.json` 读，和标签一致。
- `PNPM_HOME`、`pnpm_config_store_dir`、`pnpm_config_cache_dir` 都指到 `/home/node/.local/share/pnpm` 下，共享 volume 挂这一个目录。store 必须显式指定：实测不指定时 pnpm 发现默认位置和 node_modules 不在同一文件系统，会把 store 建到 `node_modules/.pnpm-store`，共享就落空。pnpm 12 只认 `pnpm_config_*` 前缀的环境变量，`npm_config_*` 无效。
- pnpm 自己的缓存（`pnpm_config_cache_dir`，指到 `/home/node/.local/share/pnpm/cache`）和按 `packageManager` 下载的其他版本（`PNPM_HOME` 下）也在共享 volume 里，容器重建不重新下载。

Go 镜像另有：

- `GOMODCACHE`、`GOCACHE` 指向两个共享 volume 的挂载点。
- 不装 air、sqlc 等项目工具，项目用 `go.mod` 的 `tool` 指令登记，`go tool air` 运行。air 官方支持这种装法（要求 Go 1.25 以上）。

不进镜像的：npm 依赖、Go 依赖、数据库和其他服务、只有个别项目要的系统库、凭证、个人顺手工具。

## 项目模板

`templates/node/compose.yaml` 的要点：

- `build.dockerfile_inline` 内嵌 `FROM ghcr.io/zhaojiannet/dev-node:<完整标签>`，然后 `ARG PUID`、`ARG PGID`、`USER root`、`RUN fix-user "$$PUID" "$$PGID"`、`USER node` 五行，构建参数从 `.env` 读，默认 1000。`.dockerignore` 写 `*`，不把项目目录送给 daemon。
- `./app` 挂到 `/app`；项目自己的 volume 挂 `/app/node_modules`；共享 volume 用固定名字 `pnpm`，所有项目同名，先起的建、后起的用；不标 `external`，所以 `docker compose down -v` 会把它一起删，它只是缓存。
- `PUID`、`PGID`、`TZ` 从 `.env` 读。
- 标签 `dev.orbstack.domains=${COMPOSE_PROJECT_NAME}.orb.local` 给短域名，`dev.orbstack.http-port` 写明容器内端口，OrbStack 不用自己探测。环境变量 `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=.orb.local` 让 Vite 响应这个域名。
- 端口映射单独放 `compose.ports.yaml`，只绑 `127.0.0.1`，`.env` 里写 `COMPOSE_FILE` 时才合并。
- 加入网络 `dev-net`，写法和 services 一致。
- 容器空转，`restart: unless-stopped`。

项目里要配的 pnpm 设置写在 `pnpm-workspace.yaml`：允许运行安装脚本的包白名单（pnpm 12 默认拦截 esbuild、workerd 这类包的安装脚本，实测会报 `ERR_PNPM_IGNORED_BUILDS`）、新版本发布满 3 天才装、不装信任等级降低的版本。

`templates/go/compose.yaml` 同理，volume 换成 `go-mod`、`go-build` 两个共享卷。

## 共享服务

每种服务一个目录，各自 `compose.yaml` 加 `.env.example`，用官方镜像，标签写完整版本号并钉 digest。MariaDB、MySQL 取官方 `lts` 标签对应的版本，不取滚动发布的 `latest`。数据放 named volume，由镜像自己的用户运行，compose 不指定 uid；Valkey 的 `command` 以 `sh` 开头、入口脚本不降权，单独写 `user: valkey`。端口只绑 `127.0.0.1`，网络声明同上。三个数据库各附建库、查权限、删库、备份脚本。

备份用 `mariadb-dump`、`mysqldump`、`pg_dumpall` 导出 SQL，不拷数据目录：PostgreSQL 文档写明拷数据文件必须先停库或对整个文件系统做原子快照才可用。`services/backup-all.sh` 依次调用各目录的 `backup.sh`，不写死目录名，认同时有 `backup.sh` 和 `create-db.sh` 的目录，复制到别处、目录改名后照样能用。不建定时任务，在清理容器、升级或迁移数据库前手动跑。保留规则：`all_databases_*` 每个实例留最新 5 份，名字带 `before-` 的改动前快照按修改时间留 30 天，其他文件不动。导出文件只在本机 `backups/` 下，不另存第二份。

## CI

- 构建（`.github/workflows/images.yml`）：`images/` 下有改动推到 main、每周一定时、手动触发三种情况跑。不用缓存从头构建本机架构并载入，跑 `images/test.sh` 和 Trivy，通过后用 QEMU 构建 `linux/amd64,linux/arm64` 推到 ghcr.io，推版本标签和 `-r<运行号>` 构建号标签各一个。标签从 Dockerfile 的 `FROM` 行和 `images/node/package.json` 算出。PR 上到扫描为止，不推送。推送成功后另一个 job 把模板里的标签改成新的并提交到 main，这个 job 单独拿 `contents: write`。
- 扫描（`.github/workflows/scan.yml`）：gitleaks 每次推送和 PR。
- Dependabot（`.github/dependabot.yml`）：每周查 `images/*` 的 Dockerfile、`images/node/package.json`、`services/*` 的 compose、工作流里的 action，冷却 3 天。Node、pnpm 忽略大版本更新，换大版本时改这两条。

## 待验证

- `fix-user` 改 uid 后 bind mount 内文件属主是否正确，要在 Linux 宿主机上验；Mac 上 OrbStack 的映射让这一点验不出来。
- QEMU 模拟 amd64 构建 Node 镜像的耗时。
- 升级版本时重新查当天的最新稳定版，不用本文写下的数字。
- OrbStack 图形界面里删除整个 compose 项目时，会不会连带删掉它的 named volume。文档没写。

## 已查证的事实（2026-10-03）

- 跨 named volume 硬链接报 `Invalid cross-device link`；同一 volume 的两个 subpath 分别挂载也一样；整卷单点挂载内正常。
- pnpm 12.8.1 按 `packageManager` 自动下载切换版本，控制项 `pmOnFail`，默认 `download`。
- OrbStack 下 bind mount 文件在容器内一律显示为当前容器 uid，宿主机侧一律是宿主机用户。
- 空 named volume 首次挂载继承镜像内目录属主。
- `node:24-trixie-slim`、`golang:1.27.1-trixie` 都自带 `setpriv`（util-linux）。
- corepack 从 Node 25.0.0 起不再随 Node 分发。
- 两个独立 compose 声明同名非 external 网络可共用，先停一个不影响另一个。
- compose 的 `dockerfile_inline` 加 `args` 在 compose v5.1.2 可用。内嵌文本里引用构建参数要写 `$$PUID`：compose 会先对整段文本做自己的变量替换，写 `$PUID` 时 `.env` 里没有这个变量就被替换成空字符串。
- 用本机构建的镜像按模板起容器，`PUID=1234` 时容器内 `id` 为 `1234(node)`，exec 进去的命令同 uid，`pnpm add sharp` 写进共享 store，第二个项目安装时下载数为 0。

## 已查证的事实（2026-10-05，OrbStack 2.2.3）

- 不映射端口时，`https://app.<项目名>.orb.local` 和标签 `dev.orbstack.domains` 给的 `https://<项目名>.orb.local` 都能访问容器内的开发服务器，证书宿主机直接信任。
- Astro 7.3.5 开发服务器默认对 `.orb.local` 主机名返回 403 `Blocked request`；设环境变量 `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=.orb.local` 后返回 200，不用改项目配置。
- Mac 上新建、修改 bind mount 里的文件，容器内 `fs.watch` 收到事件；不开 `usePolling`，通过域名打开的页面在 Mac 上改 `.astro` 文件后自动刷新。经 https 域名的 Vite 热重载 WebSocket 握手返回 101。
- `.env` 里写 `COMPOSE_FILE=compose.yaml:compose.ports.yaml` 时 compose 合并两个文件，不写时只读 `compose.yaml`。
- 没有 `.env` 时，compose 用目录名作为 `${COMPOSE_PROJECT_NAME}` 的值。
- 据 Docker CLI 文档：`docker system prune` 默认不删卷，加 `--volumes` 只删匿名卷；`docker volume prune` 默认只删匿名卷，加 `-a` 才删没有容器在用的 named volume；`docker compose down -v` 删 compose 文件 `volumes` 段声明的卷，标了 `external` 的不删。
- 据 OrbStack 文档：named volume 存在虚拟磁盘 `~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img` 里，Mac 上从 `~/OrbStack/docker/volumes/` 可以浏览；容器读写 volume 比 bind mount 快。
