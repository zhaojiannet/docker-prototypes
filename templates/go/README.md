# Go 项目模板

一个空转的开发容器，源码在宿主机，模块缓存和编译缓存在容器里。宿主机只要有 Docker。

## 新建项目

仓库根目录的 `new-project.sh go <目录> --module <模块路径>` 会把下面两节的步骤一次做完。手动做是这样：

```bash
mkdir my-service && cd my-service
cp -r /path/to/docker-prototypes/templates/go/. .
cp .env.example .env            # 改 COMPOSE_PROJECT_NAME 和端口
mkdir app
docker compose up -d
```

Linux 上如果 `id -u` 不是 1000，在 `.env` 里填上 `PUID`、`PGID` 再 `up`。Mac 上不用。已经 `up` 过之后再改这两个值，要 `docker compose up -d --build`，`up` 只在本地没有镜像时才构建。

## 在容器里初始化项目

```bash
docker compose exec app go mod init example.com/my-service
```

## 项目工具

air、sqlc 这类工具不在镜像里，用 `go.mod` 的 `tool` 指令登记在项目里，版本跟着项目走：

```bash
docker compose exec app go get -tool github.com/air-verse/air@latest
docker compose exec app go tool air
```

## 日常

```bash
docker compose exec app go build ./...
docker compose exec app go test ./...
docker compose exec app go run .        # 服务要监听 0.0.0.0，宿主机才访问得到
docker compose exec app bash            # 进 shell
```

## 放哪

| 内容 | 位置 |
|---|---|
| 源码 | `./app`，挂到容器 `/app` |
| 模块缓存 | 所有 Go 项目共用的 volume `go-mod` |
| 编译缓存 | 所有 Go 项目共用的 volume `go-build` |
| 编出来的二进制 | `./app` 下，自己在 `app/.gitignore` 里忽略 |

## 删除项目

`docker compose down` 只停容器，依赖和缓存都保留。`docker compose down -v` 会把所有项目共用的 `go-mod`、`go-build` 一起删掉，它们只是缓存，下次构建会重新下载。

## 连数据库

1. 起服务：`cd services/postgres && cp .env.example .env && docker compose up -d --wait`。
2. 建库建用户：`./create-db.sh my_svc my_svc`，它会打印随机生成的密码。
3. 把连接串写进 `app/.env`，由程序自己读（或者加进 compose 的 `environment`）。项目根目录那个 `.env` 只给 compose 用，进不了容器。

```
DATABASE_URL=postgresql://my_svc:密码@postgres:5432/my_svc
```

主机名是服务名 `postgres`，端口是容器内的 5432，不是宿主机映射的端口。MariaDB、MySQL 用 `mariadb:3306`、`mysql:3306`，Valkey 用 `redis://:密码@valkey:6379`。网络 `dev-net` 由先起的那个 compose 创建，后起的自动加入。

## 容器内端口

compose 把宿主机的 `APP_PORT` 映射到容器内的 8080。服务要监听 `0.0.0.0:8080`；用别的端口就把 `compose.yaml` 里 `ports` 那行冒号右边改掉。

## 迁移已有项目

目标目录非空时 `new-project.sh` 会退出，手动做：

1. 在项目根复制模板：`cp -r /path/to/docker-prototypes/templates/go/. .`，删掉项目原有的 `Dockerfile`、`docker-compose.yml`。
2. 源码（含 `go.mod`）放进 `app/`（原来就在根目录的话 `git mv` 进去）。
3. `cp .env.example .env`，填 `COMPOSE_PROJECT_NAME`。
4. 原来在 Dockerfile 里 `go install` 的工具改成 `go get -tool`，登记进 `go.mod`。
5. `docker compose up -d --build`，然后 `docker compose exec app go build ./...`，模块会下进共享缓存。

## 更新镜像

拿同版本的安全补丁：`docker compose build --pull && docker compose up -d`。版本标签每周重建一次，`--pull` 才会去拉新的，不加就用本机缓存的。

换 Go 版本：改 `compose.yaml` 里 `FROM` 那行的标签，再 `docker compose up -d --build`。可用标签见仓库根 README，本模板里的标签总是最新一次构建成功的那个。

## 要额外系统库时

在项目里加一个 `Dockerfile`，`FROM` 同一个基础镜像，`USER root` 装完再 `USER go`，把 compose 里的 `dockerfile_inline` 换成 `dockerfile: Dockerfile`，并保留 `ARG` 到 `USER go` 那五行。
