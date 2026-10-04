# Node 项目模板

一个空转的开发容器，源码在宿主机，依赖和缓存在容器里。宿主机只要有 Docker。

## 新建项目

仓库根目录的 `new-project.sh node <目录> --astro` 会把下面两节的步骤一次做完。手动做是这样：

```bash
mkdir my-site && cd my-site
cp -r /path/to/docker-prototypes/templates/node/. .
cp .env.example .env            # 改 COMPOSE_PROJECT_NAME 和端口
mkdir app
docker compose up -d
```

Linux 上如果 `id -u` 不是 1000，在 `.env` 里填上 `PUID`、`PGID` 再 `up`。Mac 上不用。已经 `up` 过之后再改这两个值，要 `docker compose up -d --build`，`up` 只在本地没有镜像时才构建。

## 在容器里初始化项目

`/app/node_modules` 已经是挂载好的 volume 目录，脚手架会把 `/app` 当成非空目录拒绝，所以先生成到临时目录再拷进来：

```bash
docker compose exec app sh -c 'pnpm create astro@latest /tmp/site --template minimal --no-install --no-git && cp -a /tmp/site/. /app/'
cp pnpm-workspace.yaml app/
docker compose exec app sh -c 'pnpm pkg set packageManager="pnpm@$(pnpm --version)"'
docker compose exec app pnpm install
```

`pnpm-workspace.yaml` 要放在 `app/` 下和 `package.json` 一起，里面是装包限制和允许运行安装脚本的包白名单。`packageManager` 写镜像自带的 pnpm 版本，版本一致就不会在运行时另外下载。

## 日常

```bash
docker compose exec app pnpm install
docker compose exec app pnpm dev --host     # 开发服务器要监听 0.0.0.0，宿主机才访问得到
docker compose exec app pnpm build
docker compose exec app sh                  # 进 shell
```

浏览器打开 `http://localhost:4321`（端口在 `.env` 里改）。

## 放哪

| 内容 | 位置 |
|---|---|
| 源码 | `./app`，挂到容器 `/app` |
| `node_modules` | 本项目的 named volume，不出现在宿主机 |
| pnpm store、元数据缓存、按 `packageManager` 下载的其他版本 | 所有 Node 项目共用的 volume `pnpm`，包只下载一次 |
| `dist`、`.astro` 等构建产物 | `./app` 下，由项目的 `.gitignore` 忽略 |

## 删除项目

`docker compose down` 只停容器，依赖和缓存都保留。`docker compose down -v` 会把本项目的 volume 连同所有项目共用的 `pnpm` 一起删掉，共用的只是缓存，下次安装会重新下载。

## 连数据库

起 `services/` 下对应的服务，容器之间用服务名连：`postgres`、`mariadb`、`mysql`、`valkey`，端口用服务自己的默认端口。网络 `dev-net` 由先起的那个 compose 创建，后起的自动加入。

## 换镜像版本

改 `compose.yaml` 里 `FROM` 那行的标签，然后 `docker compose up -d --build`。可用标签见仓库根 README。

## 要额外系统库时

在项目里加一个 `Dockerfile`，`FROM` 同一个基础镜像，`USER root` 装完再 `USER node`，把 compose 里的 `dockerfile_inline` 换成 `dockerfile: Dockerfile`，并保留 `ARG` 到 `USER node` 那五行。
