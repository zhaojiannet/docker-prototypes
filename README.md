# docker-prototypes

本机开发用的容器环境：两个基础镜像（Node、Go）、两套项目模板、四套数据库服务。

## 为什么有这个仓库

做了几个 Node 和 Go 项目之后，每个项目都有一份自己抄来改去的 Dockerfile 和 compose。时间一长它们各不相同：基础镜像标签有的浮动有的钉死，pnpm 版本一个项目一个样，缓存放的位置、容器用户的 uid、有没有装 CA 证书，全靠记忆。新建项目时「先看一遍旧项目再照着搭」，还是会漏。

这个仓库把环境的定义收到一处。基础镜像里装好所有项目都要的东西，项目里只剩一份很短的 compose。修一个问题，所有项目换个标签就都生效。

## 要解决的四件事

1. **宿主机不装任何语言运行时和依赖。** 宿主机只要有 Docker。Node、pnpm、Go 都在镜像里。
2. **依赖装在容器里，持久化不丢。** `node_modules`、pnpm store、Go 的模块缓存和编译缓存都放 named volume，容器重建不重新下载。pnpm store 和 Go 缓存所有项目共用，一个包只下载一次。
3. **源码在宿主机，用自己的编辑器和 git。** 源码目录 bind mount 进容器，构建产物也留在源码目录里。
4. **容器写出来的文件和宿主机用户同属主。** 项目 compose 里按 `PUID`、`PGID` 把容器用户改成宿主机用户的 uid。Mac 上不需要，Linux 上 uid 不是 1000 时填两行 `.env` 再 `docker compose up -d --build` 就行。

## 起步

宿主机只需要 Docker（Mac 上用 OrbStack 或 Docker Desktop 都行）和 bash。模板用到 compose 的 `dockerfile_inline`，在 Docker 29.4、Compose v5.1.2 上验证过，老版本 compose 不认这个字段。数据库目录下的脚本还会在宿主机上调用 `openssl` 生成随机密码，macOS 和主流 Linux 自带。

```bash
git clone https://github.com/zhaojiannet/docker-prototypes.git ~/Cores/Projects/docker-prototypes
```

## 组成

| 目录 | 是什么 | 怎么用 |
|---|---|---|
| `images/node`、`images/go` | 基础镜像的 Dockerfile，由 GitHub Actions 构建推送到 ghcr.io | 项目 compose 里 `FROM` 它 |
| `templates/node`、`templates/go` | 新项目的起步文件：`compose.yaml`、`compose.ports.yaml`、`.env.example`、`.gitignore`、`.dockerignore`、README，Node 另有 `pnpm-workspace.yaml` | 用 `new-project.sh` 复制到新项目目录 |
| `services/postgres`、`services/mariadb`、`services/mysql`、`services/valkey` | 一台机器一套的共享数据库，各自独立，按需起 | `cd services/postgres && docker compose up -d` |
| `docs/` | 方案文档，记录每条决定和依据 | |

## 镜像

```
ghcr.io/zhaojiannet/node:<Node 版本>-<Debian 代号>-dev     例 24.21.0-trixie-dev
ghcr.io/zhaojiannet/golang:<Go 版本>-<Debian 代号>-dev     例 1.27.1-trixie-dev
```

- 命名照 Docker Hardened Images：镜像名是语言，标签是版本加 Debian 代号，`-dev` 后缀表示带 shell、包管理器、git 的开发和构建变体。现在只有 `-dev` 变体；以后生产要跑 Node 服务时，同版本不带工具的运行变体就是去掉 `-dev` 的同名标签。
- 用途：本机开发，以及生产 Dockerfile 的构建阶段，两边的 Node、Go、pnpm 版本一致。生产的运行阶段不用它，编译产物复制进 distroless、caddy 这类最小镜像。
- Debian 稳定版（trixie）底，`linux/amd64` 和 `linux/arm64`。
- 预装 `ca-certificates`、`tzdata`、`git`，时区 `Asia/Tokyo`，普通用户 uid 1000。
- Node 镜像装一个确定版本的 pnpm，版本写在镜像描述（`org.opencontainers.image.description`）里，不进标签：项目实际用的 pnpm 由 `package.json` 的 `packageManager` 决定。不带 npm 和 corepack：`npx` 用 `pnpm dlx`，`npm create` 用 `pnpm create`。pnpm store 和缓存的路径已指向 `/home/node/.local/share/pnpm`，把共享 volume 挂到那里即可。
- Go 镜像的 `GOMODCACHE`、`GOCACHE` 指向 `/go/pkg/mod`、`/go/cache`。
- 版本标签指向这组版本的最新一次构建，每周重建会把 Debian 安全补丁更新到它上面。要钉死就在标签后面加 `@sha256:` digest，模板里就是这样写的。没有 `latest`。
- 不装项目工具。air、sqlc 这类用 `go.mod` 的 `tool` 指令放项目里。

## 维护镜像

- 每个版本号只写在一处：Node 和 Go 版本在 Dockerfile 的 `FROM` 行，pnpm 版本在 `images/node/package.json` 的 `dependencies.pnpm`。CI 从这几处算出标签。
- `images.yml` 在三种情况下跑：`images/` 下有改动推到 main、每周一定时、手动触发。每次都不用缓存从头构建，跑 `images/test.sh` 和 Trivy，通过后构建双架构推到 ghcr.io，更新版本标签。PR 上只到扫描为止，不推送。每周重建是为了把 Debian 的安全补丁带上，`apt-get upgrade` 只在构建时跑。
- 推送成功后，`images.yml` 查出版本标签指向的多架构 digest，把 `templates/*/compose.yaml` 里的 `FROM` 改成「标签@digest」，有变化就直接提交到 main。
- 镜像包第一次推送到个人账号下时默认是私有的，要在 GitHub 的包设置里改成公开，模板才能匿名拉取。
- `scan.yml` 在推送和 PR 时跑 gitleaks。
- Dependabot（GitHub 内置，配置在 `.github/dependabot.yml`）每周盯 Dockerfile 的 `FROM`、`images/node/package.json` 里的 pnpm、服务 compose 的镜像、工作流里的 action，新版本发布满 3 天才开 PR，CI 绿了人工合并。Node 只跟当前长期支持版的大版本，pnpm 只跟当前大版本。已建好的项目里的镜像标签在各自仓库，手动改。

## 新建一个项目

```bash
./new-project.sh node ~/Projects/my-site --astro          # Node，并在容器里生成 Astro 项目
./new-project.sh node ~/Projects/my-site --astro blog --access port --port 4400   # 指定 Astro 模板名，用 localhost:4400 访问
./new-project.sh go   ~/Projects/my-svc --module example.com/my-svc
./new-project.sh                                          # 不带参数就逐项问
```

脚本做的事：复制模板、按目录名写 `.env`、Linux 上 uid 或 gid 不是 1000 时自动填 `PUID`、`PGID`、建 `app/`、`docker compose up -d`。访问方式默认按 Docker 判断：OrbStack 用域名 `https://<项目名>.orb.local`，其他用 `localhost` 加端口，`--access domain|port` 可以指定。加 `--astro` 时在容器里跑 Astro 脚手架、放好 `pnpm-workspace.yaml`、写 `packageManager`、`pnpm install`。目标目录已存在且非空时脚本会退出，已有项目的迁法见模板 README。

之后命令都通过 `docker compose exec app ...` 在容器里跑。手动一步步做的方法见各模板目录的 README。

## 数据库

每种服务一个目录，各自 `cp .env.example .env` 填密码后 `docker compose up -d --wait`，PostgreSQL、MariaDB、MySQL 再用目录里的 `create-db.sh` 给每个项目建库建用户，Valkey 只有一个密码。数据在 named volume `<服务>-data` 里，标了 `external`，第一次 `up` 之前先 `docker volume create`，见各目录 README。所有 compose 都连外部网络 `docker-net`，本机第一次用前先 `docker network inspect docker-net >/dev/null 2>&1 || docker network create docker-net`，项目容器里用服务名（`postgres`、`mariadb`、`mysql`、`valkey`）加服务默认端口连，连接串写在项目的 `app/.env`，写法见模板 README。

`services/backup-all.sh` 依次调用各目录的 `backup.sh` 做整库备份，没在运行的实例临时启动、备份完再停掉。备份后清理旧文件：`all_databases_*` 每个实例留最新 5 份，名字带 `before-` 的手动快照留 30 天，其他文件不动。导出文件只在本机，清理容器、升级或迁移数据库前跑一次。

## 本机验证镜像

```bash
docker build -f images/node/Dockerfile -t local/node:test images/
docker build -f images/go/Dockerfile -t local/golang:test images/
images/test.sh local/node:test local/golang:test
```

## 不入库的东西

`.env`（真实密码）、`backups/`（数据库导出文件）。仓库里只有 `.env.example`。
