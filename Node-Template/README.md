# Node 项目模板

拿来开新的 Node 项目。宿主机上不装 Node、不装 pnpm、不装任何依赖，全部在容器里。

基础镜像 `node:24-trixie-slim`（当前 LTS 24.20.0），pnpm 用 corepack 装在镜像里。

## 开一个新项目

```bash
# 1. 复制这个模板（在仓库根目录下执行）
cp -r Node-Template /path/to/新项目
cd /path/to/新项目

# 2. 配置
cp .env.example .env
# 改 .env 里的 PROJECT_NAME 和 APP_PORT

# 3. 起容器
docker compose up -d --build

# 4. 进容器里初始化项目
docker compose exec app pnpm init
docker compose exec app pnpm add express      # 装你要的依赖

# 也可以直接用脚手架，比如 Astro：
# docker compose exec app pnpm create astro@latest .
```

容器起来之后是空转的（`tail -f /dev/null`），所有命令都用 `docker compose exec` 送进去。

## 常用命令

```bash
docker compose exec app pnpm install        # 装依赖
docker compose exec app pnpm add 包名        # 加一个包
docker compose exec app pnpm run dev        # 跑开发服务器
docker compose exec app sh                  # 进容器交互式操作

docker compose logs -f                      # 看日志
docker compose down                         # 停
docker compose down -v                      # 停并删掉 node_modules 和 pnpm 缓存
```

开发服务器要监听 `0.0.0.0` 而不是 `127.0.0.1`，否则宿主机访问不到。Vite 系的加 `--host`。

## 连数据库

数据库是 `docker-net` 网络上几个独立跑的服务，不在这个 compose 里。把 `docker-compose.yml` 里对应的注释打开，密码填进 `.env`：

| 服务 | 容器内主机名 | 端口 |
|---|---|---|
| MySQL | `mysql-server` | 3306 |
| MariaDB | `mariadb-server` | 3306 |
| PostgreSQL | `postgres-server` | 5432 |
| Valkey | `valkey-server` | 6379 |

注意端口用的是容器内端口，不是宿主机上那个映射后的端口。比如 MariaDB 在宿主机上是 3307，但从容器里连要用 `mariadb-server:3306`。

如果这个项目自己要一套独立的数据库，把同仓库 `PostgreSQL/docker-compose.yml` 里的服务段落抄进来，改个容器名和端口就行。

## 目录和挂载

```
项目/
├── Dockerfile
├── docker-compose.yml
├── .env                 自己创建，不进版本库
├── .env.example
└── app/                 代码放这里，挂到容器的 /app
```

`app/` 是 bind mount，改代码马上生效。`app/node_modules` 和 `app/.pnpm-store` 是 Docker named volume，宿主机上只看得到两个空目录，实际内容在 Docker 里，不会拖慢 IDE 也不会被误提交。

## 两个容易踩的坑

**1. named volume 的挂载点必须在镜像里先建好**

Docker 拿镜像里同路径的属主去初始化 volume。镜像里没有 `/app/node_modules` 这个目录，Docker 就以 root 建，容器内的 node 用户（uid 1000）写不进去，`pnpm install` 会报 `EACCES: permission denied, mkdir '/app/node_modules/.pnpm'`。所以 Dockerfile 里有这一句：

```dockerfile
RUN mkdir -p /app/node_modules /app/.pnpm-store && chown -R 1000:1000 /app
```

**2. corepack 必须以 node 用户身份装 pnpm**

以 root 装的话缓存落在 `/root/.cache`，切到 node 用户后读不到，每次跑 pnpm 都要重新从网上下一遍。所以 `corepack prepare` 那一行放在 `USER node` 之后。

## 关于 pnpm store

pnpm 要求 store 和 node_modules 在同一个文件系统才能用硬链接。`/app` 是 bind mount，pnpm 会自动把 store 放到 `/app/.pnpm-store`，用 `npm_config_store_dir` 环境变量或者 `.npmrc` 都改不动它（pnpm 10 之后的行为）。所以这里顺着它来，直接把 named volume 挂在 `/app/.pnpm-store` 上，效果一样：不落宿主机，删容器不丢缓存。

## 关于 pnpm 11 的 devEngines

`pnpm init` 生成的 `package.json` 会带一个 `devEngines.packageManager` 字段，导致 `pnpm add` 时把 pnpm 自己也装进 `node_modules`（多占几十 MB）。用不上的话把那个字段删掉就行，镜像里已经有 pnpm 了。
