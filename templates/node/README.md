# Node 项目模板

一个空转的开发容器，源码在宿主机，依赖和缓存在容器里。宿主机只要有 Docker。

## 新建项目

仓库根目录的 `new-project.sh node <目录> --astro` 会把下面两节的步骤一次做完。手动做是这样：

```bash
mkdir my-site && cd my-site
cp -r /path/to/docker-prototypes/templates/node/. .
cp .env.example .env            # 改 COMPOSE_PROJECT_NAME
mkdir app
docker compose up -d
```

Linux 上如果 `id -u` 不是 1000，在 `.env` 里填上 `PUID`、`PGID` 再 `up`。Mac 上不用。已经 `up` 过之后再改这两个值，要 `docker compose up -d --build`，`up` 只在本地没有镜像时才构建。

## 在容器里初始化项目

`/app/node_modules` 已经是挂载好的 volume 目录，脚手架会把 `/app` 当成非空目录拒绝，所以先生成到临时目录再拷进来：

```bash
docker compose exec app sh -c 'pnpm create astro@latest /tmp/site --template minimal --no-install --no-git --yes && cp -a /tmp/site/. /app/ && rm -rf /tmp/site'
mv pnpm-workspace.yaml app/
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

浏览器打开 `https://<COMPOSE_PROJECT_NAME>.orb.local`，见下一节。

## 访问方式

默认用 OrbStack 的域名访问，不映射宿主机端口，多个项目同时开也不会抢端口：

- `https://<项目名>.orb.local`，由 compose 的标签 `dev.orbstack.domains` 指定；OrbStack 自带的 `https://app.<项目名>.orb.local` 也能用。证书 OrbStack 自动签发和安装。容器里的 Node 会信任系统证书库，OrbStack 的根证书也在里面，Node 程序访问 `https://*.orb.local` 不用另外配置。
- Vite 默认只响应 localhost 和 IP，其他主机名一律返回 403。compose 里的环境变量 `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` 放行 `.orb.local`，Astro 等基于 Vite 的框架都认，项目配置里不用再写 `allowedHosts`。
- 热重载不用开文件轮询（`usePolling`），OrbStack 会把 Mac 上的文件改动通知到容器里。

不用 OrbStack（Linux、Docker Desktop），或者就要 `localhost` 加端口时，在 `.env` 里加：

```
COMPOSE_FILE=compose.yaml:compose.ports.yaml
APP_PORT=4321
```

compose 会合并 `compose.ports.yaml`，把 `127.0.0.1:APP_PORT` 映射到容器内的 4321。改完 `docker compose up -d`。`new-project.sh` 用 `--access port` 时就是写这两行；不指定时，Docker 是 OrbStack 就用域名，否则用端口。

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

1. 起服务：`cd services/postgres && cp .env.example .env && docker compose up -d --wait`。
2. 建库建用户：`./create-db.sh my_site my_site`，它会打印随机生成的密码。
3. 把连接串写进 `app/.env`（Astro 从项目根也就是 `app/` 读 `.env`）。项目根目录那个 `.env` 只给 compose 用，进不了容器。

```
DATABASE_URL=postgresql://my_site:密码@postgres:5432/my_site
```

主机名是服务名 `postgres`，端口是容器内的 5432，不是宿主机映射的端口。MariaDB、MySQL 用 `mariadb:3306`、`mysql:3306`，Valkey 用 `redis://:密码@valkey:6379`。网络 `dev-net` 由先起的那个 compose 创建，后起的自动加入。

## 容器内端口

容器内用 4321，这是 Astro 开发服务器的默认端口。用别的框架时，要么让它监听 4321，要么把 `compose.yaml` 里标签 `dev.orbstack.http-port` 和 `compose.ports.yaml` 里冒号右边都改成它的端口。

## 迁移已有项目

目标目录非空时 `new-project.sh` 会退出，手动做：

1. 在项目根复制模板：`cp -r /path/to/docker-prototypes/templates/node/. .`，删掉项目原有的 `Dockerfile`、`docker-compose.yml`。
2. 源码放进 `app/`（原来就在根目录的话 `git mv` 进去）。
3. `cp .env.example .env`，填 `COMPOSE_PROJECT_NAME`。
4. `mv pnpm-workspace.yaml app/`，把 `app/package.json` 的 `packageManager` 改成镜像标签里的 pnpm 版本。
5. `docker compose up -d --build`，然后 `docker compose exec app pnpm install`。旧的 `node_modules` volume 不用管，新 volume 名字不同，装一遍就好。

## 更新镜像

拿同版本的安全补丁：`docker compose build --pull && docker compose up -d`。版本标签每周重建一次，`--pull` 才会去拉新的，不加就用本机缓存的。

换 Node 或 pnpm 版本：改 `compose.yaml` 里 `FROM` 那行的标签，再 `docker compose up -d --build`。可用标签见仓库根 README，本模板里的标签总是最新一次构建成功的那个。

## 要额外系统库时

在项目里加一个 `Dockerfile`，`FROM` 同一个基础镜像，`USER root` 装完再 `USER node`，把 compose 里的 `dockerfile_inline` 换成 `dockerfile: Dockerfile`，并保留 `ARG` 到 `USER node` 那五行。
