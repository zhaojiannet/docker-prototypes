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
| 编出来的二进制 | `./app` 下，由项目的 `.gitignore` 忽略 |

## 删除项目

`docker compose down` 只停容器，依赖和缓存都保留。`docker compose down -v` 会把所有项目共用的 `go-mod`、`go-build` 一起删掉，它们只是缓存，下次构建会重新下载。

## 连数据库

起 `services/` 下对应的服务，容器之间用服务名连：`postgres`、`mariadb`、`mysql`、`valkey`，端口用服务自己的默认端口。网络 `dev-net` 由先起的那个 compose 创建，后起的自动加入。

## 换镜像版本

改 `compose.yaml` 里 `FROM` 那行的标签，然后 `docker compose up -d --build`。可用标签见仓库根 README。

## 要额外系统库时

在项目里加一个 `Dockerfile`，`FROM` 同一个基础镜像，`USER root` 装完再 `USER go`，把 compose 里的 `dockerfile_inline` 换成 `dockerfile: Dockerfile`，并保留 `ARG` 到 `USER go` 那五行。
