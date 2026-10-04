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

## 组成

| 目录 | 是什么 | 怎么用 |
|---|---|---|
| `images/node`、`images/go` | 基础镜像的 Dockerfile，由 GitHub Actions 构建推送到 ghcr.io | 项目 compose 里 `FROM` 它 |
| `templates/node`、`templates/go` | 新项目的起步文件：`compose.yaml`、`.env.example`、README | 复制到新项目目录 |
| `services/postgres`、`services/mariadb`、`services/mysql`、`services/valkey` | 一台机器一套的共享数据库，各自独立，按需起 | `cd services/postgres && docker compose up -d` |
| `docs/` | 方案文档，记录每条决定和依据 | |

## 镜像

```
ghcr.io/zhaojiannet/dev-node:<Node 版本>-pnpm<pnpm 版本>   例 24.21.0-pnpm12.8.1
ghcr.io/zhaojiannet/dev-go:<Go 版本>                        例 1.27.1
```

- Debian 稳定版（trixie）底，`linux/amd64` 和 `linux/arm64`。
- 预装 `ca-certificates`、`tzdata`、`git`，时区 `Asia/Tokyo`，普通用户 uid 1000。
- Node 镜像装一个确定版本的 pnpm，不带 npm 和 corepack：`npx` 用 `pnpm dlx`，`npm create` 用 `pnpm create`。pnpm store 和缓存的路径已指向 `/home/node/.local/share/pnpm`，把共享 volume 挂到那里即可。
- Go 镜像的 `GOMODCACHE`、`GOCACHE` 指向 `/go/pkg/mod`、`/go/cache`。
- 标签只有完整版本号，没有 `latest`。推出去的标签不覆写，项目里写的标签就是实际用的环境。
- 不装项目工具。air、sqlc 这类用 `go.mod` 的 `tool` 指令放项目里。

版本由 Renovate 盯着，有新的稳定版就开 PR，CI 构建并跑 `images/test.sh` 通过后合并。镜像每次构建用 Trivy 扫一次，每周再扫一次最新标签。

## 新建一个项目

```bash
./new-project.sh node ~/Projects/my-site --astro          # Node，并在容器里生成 Astro 项目
./new-project.sh go   ~/Projects/my-svc --module example.com/my-svc
./new-project.sh                                          # 不带参数就逐项问
```

脚本做的事：复制模板、按目录名写 `.env`、Linux 上 uid 不是 1000 时自动填 `PUID`、`PGID`、建 `app/`、`docker compose up -d`；加 `--astro` 时在容器里跑 Astro 脚手架、放好 `pnpm-workspace.yaml`、写 `packageManager`、`pnpm install`。宿主机只需要 bash 和 Docker。

之后命令都通过 `docker compose exec app ...` 在容器里跑。手动一步步做的方法见各模板目录的 README。

## 数据库

每种服务一个目录，各自 `cp .env.example .env` 填密码后 `docker compose up -d`。数据在 named volume 里。所有 compose 都声明同名网络 `dev-net`，先起的建、后起的加入，项目容器里用服务名（`postgres`、`mariadb`、`mysql`、`valkey`）连。

## 本机验证镜像

```bash
docker build -f images/node/Dockerfile -t dev-node:test images/
docker build -f images/go/Dockerfile -t dev-go:test images/
images/test.sh dev-node:test dev-go:test
```

## 不入库的东西

`.env`（真实密码）、`backups/`（数据库导出文件）。仓库里只有 `.env.example`。
