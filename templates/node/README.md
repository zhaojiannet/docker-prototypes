# Node 项目

源码在 `app/`，Node、pnpm、依赖都在容器里，宿主机只要有 Docker（OrbStack）。容器一启动就先 `pnpm install` 再 `pnpm dev --host`。

## 新建

```bash
~/Cores/Projects/docker-prototypes/dp new node my-site --astro    # Astro 站点，--astro blog 指定 Astro 模板
~/Cores/Projects/docker-prototypes/dp new node my-lib             # 只有 package.json，加好 dev 脚本后 dp up
```

`dp new` 复制本模板到 `~/Cores/Projects/<名字>`，写 `.env`，生成项目，写 `packageManager`，然后启动。本文件不复制，项目的 `README.md` 只有项目名和指向这里的一句，项目自己的说明写在那里。

脚手架常带刚发布几天的版本，会被 `app/pnpm-workspace.yaml` 的 `minimumReleaseAge`（满 3 天才装）拦下。`dp new --astro` 会在终端里先装一次，被拦时 pnpm 会问放不放行，放行的包记进 `minimumReleaseAgeExclude`。容器启动时的安装没有终端，被拦就启动失败，`dp logs` 能看到。

## 日常

在项目目录下运行时可以不写项目名，`dp` 指 `~/Cores/Projects/docker-prototypes/dp`：

```bash
dp up | down | restart | status
dp logs
dp update                          # 拉官方当前的 Node 长期支持版，重建并重启
docker compose exec app pnpm add <包>
docker compose exec app sh
```

浏览器打开 `https://<COMPOSE_PROJECT_NAME>.orb.local`。

- 端口：容器内 4321（Astro 默认）。别的框架要么监听 4321，要么把 `compose.yaml` 的 `dev.orbstack.http-port` 和 `healthcheck` 里的 `4321` 改成它的端口。
- Vite 默认对 `.orb.local` 返回 403，`compose.yaml` 里的 `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` 放行了它，项目配置里不用写 `allowedHosts`。

## 东西放哪

| 内容 | 位置 |
|---|---|
| 源码、`pnpm-workspace.yaml` | `./app`，挂到容器 `/app` |
| `node_modules` | 本项目的 volume，不出现在宿主机 |
| pnpm store 和缓存 | 所有 Node 项目共用的 volume `pnpm` |
| `dist`、`.astro` 等构建产物 | `./app` 下，由项目的 `.gitignore` 忽略 |

`pnpm` 卷标了 `external`，`docker compose down -v` 只删本项目的 `node_modules`，不删它。

`pnpm` 卷和 `docker-net` 网络由 `dp` 在启动前建好。不用 `dp`、直接 `docker compose up` 时，第一次先运行 `docker volume create pnpm` 和 `docker network create docker-net`。

## 连数据库

`dp db new postgres` 起实例，`dp db create postgres my_site my_site` 建库建用户并打印密码。连接串写进 `app/.env`（项目根的 `.env` 只给 compose 用，进不了容器）：

```
DATABASE_URL=postgresql://my_site:密码@postgres:5432/my_site
```

主机名是服务名，端口是容器内端口。MariaDB、MySQL 用 `mariadb:3306`、`mysql:3306`，Valkey 用 `redis://:密码@valkey:6379`。

## 生产构建

`Dockerfile` 有四段：`dev` 是开发容器，`build` 装依赖并 `pnpm build`，`files` 只有构建产物（推送模式部署时导出到本机），`runtime` 用 Caddy 托管静态文件。产物目录不是 `dist` 时加构建参数 `OUTPUT_DIR`。部署到 Cloudflare 这类平台的站点用不到后三段。

部署到自建服务器见 docker-prototypes 仓库的 `templates/deploy/README.md`。

## 依赖更新

`.github/dependabot.yml` 每周查 `app/` 的 npm 依赖和工作流里的 action，发布满 3 天才开 PR，小版本和补丁合成一个 PR。`.github/workflows/dependabot-automerge.yml` 给非大版本的 PR 打开自动合并，分支保护要求的检查都通过后自动合进去。要生效，GitHub 仓库设置里要：

1. General 里勾选 Allow auto-merge。
2. 给 main 加分支保护，把 CI 设为必须通过的检查，自动合并才会等 CI 跑完。

大版本的 PR 留给人看。

## 迁移已有项目

1. 项目根复制本模板，本文件除外：`rsync -a --exclude /README.md ~/Cores/Projects/docker-prototypes/templates/node/ .`，删掉原来的 `Dockerfile`、`docker-compose.yml`。项目的 `README.md` 只写项目自己的内容，开发环境指向本文件。
2. 源码 `git mv` 进 `app/`，原来的 `pnpm-workspace.yaml` 设置合进 `app/pnpm-workspace.yaml`。
3. `cp .env.example .env`，填 `COMPOSE_PROJECT_NAME`。
4. `app/package.json` 的 `packageManager` 写 `pnpm@<版本>`，版本用 `docker compose run --rm --no-deps app pnpm --version` 查。
5. `dp up`。
