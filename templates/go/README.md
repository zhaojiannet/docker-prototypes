# Go 项目

源码在 `app/`，Go 和缓存都在容器里，宿主机只要有 Docker（OrbStack）。容器一启动就跑 `go tool air`，改代码自动重编重启。

## 新建

```bash
~/Cores/Projects/docker-prototypes/dp new go my-svc --module example.com/my-svc
```

`dp new` 复制本模板到 `~/Cores/Projects/<名字>`，写 `.env`，`go mod init`，把 air 登记成 `go.mod` 里的工具，然后启动。本文件不复制，项目的 `README.md` 只有项目名和指向这里的一句，项目自己的说明写在那里。不写 `--module` 时模块路径就是名字。

## 目录约定

生产构建编 `./cmd/...` 下的每个 main 包，所以程序入口放 `app/cmd/<名字>/main.go`。air 默认编项目根，要在 `app/.air.toml` 里指过去：

```toml
[build]
  cmd = "go build -o ./tmp/main ./cmd/<名字>"
```

`tmp/` 是 air 的输出目录，加进 `app/.gitignore`。

## 日常

在项目目录下运行时可以不写项目名，`dp` 指 `~/Cores/Projects/docker-prototypes/dp`：

```bash
dp up | down | restart | status
dp logs
dp update                          # 拉官方当前的 Go 最新版，重建并重启
docker compose exec app go test ./...
docker compose exec app go get -tool <工具>@latest   # sqlc 这类工具登记进 go.mod，用 go tool <名字> 运行
docker compose exec app bash
```

服务监听 `0.0.0.0:8080`，浏览器打开 `https://<COMPOSE_PROJECT_NAME>.orb.local`。用别的端口就改 `compose.yaml` 的 `dev.orbstack.http-port` 和 `healthcheck` 里的 `8080`。

## 东西放哪

| 内容 | 位置 |
|---|---|
| 源码 | `./app`，挂到容器 `/app` |
| 模块缓存、编译缓存 | 所有 Go 项目共用的 volume `go-mod`、`go-build` |

这两个卷标了 `external`，`docker compose down -v` 不删它们。

这两个卷和 `docker-net` 网络由 `dp` 在启动前建好。不用 `dp`、直接 `docker compose up` 时，第一次先运行 `docker volume create go-mod`、`docker volume create go-build` 和 `docker network create docker-net`。

## 连数据库

`dp db new postgres` 起实例，`dp db create postgres my_svc my_svc` 建库建用户并打印密码。连接串写进 `app/.env` 由程序读（项目根的 `.env` 只给 compose 用，进不了容器）：

```
DATABASE_URL=postgresql://my_svc:密码@postgres:5432/my_svc
```

主机名是服务名，端口是容器内端口。MariaDB、MySQL 用 `mariadb:3306`、`mysql:3306`，Valkey 用 `redis://:密码@valkey:6379`。

## 生产构建

`Dockerfile` 有三段：`dev` 是开发容器，`build` 静态编译 `./cmd/...`，`runtime` 是 distroless，二进制在 `/usr/local/bin/`。distroless 里没有 shell，健康检查要由程序自己提供子命令。

部署到自建服务器见 docker-prototypes 仓库的 `templates/deploy/README.md`。

## 依赖更新

`.github/dependabot.yml` 每周查 `app/` 的 Go 模块和工作流里的 action，发布满 3 天才开 PR，小版本和补丁合成一个 PR。`.github/workflows/dependabot-automerge.yml` 给非大版本的 PR 打开自动合并，CI 通过后自动合进去。要生效，GitHub 仓库设置里要：

1. General 里勾选 Allow auto-merge。
2. 给 main 加分支保护，把 CI 设为必须通过的检查，自动合并才会等 CI 跑完。

大版本的 PR 留给人看。

## 迁移已有项目

1. 项目根复制本模板，本文件除外：`rsync -a --exclude /README.md ~/Cores/Projects/docker-prototypes/templates/go/ .`，删掉原来的 `Dockerfile`、`docker-compose.yml`。项目的 `README.md` 只写项目自己的内容，开发环境指向本文件。
2. 源码（含 `go.mod`）`git mv` 进 `app/`，入口按上面的约定放到 `cmd/` 下。
3. `cp .env.example .env`，填 `COMPOSE_PROJECT_NAME`。
4. 原来 `go install` 的工具改成 `go get -tool`，至少要有 air。
5. `dp up`。
