# PostgreSQL

PostgreSQL 18.6 开发环境。数据存在本目录的 `data/postgres/18/docker/`，容器删了数据还在。

## 启动

```bash
cp .env.example .env
# 改 .env 里的密码，可以用 openssl rand -base64 24 生成
mkdir -p data/postgres          # 必须先建，否则 Docker 会以 root 建出来
docker compose up -d --wait
```

## 连接

- 主机 `localhost`，端口 `5432`（在 `.env` 里改 `POSTGRES_PORT`）
- 用户名密码见 `.env`
- 其他容器从 `docker-net` 网络连过来时，主机名用 `postgres-server`，端口 `5432`

## 脚本

```bash
./create-db.sh 库名 用户名 [密码]   # 建库建用户，收紧 public schema 权限，不给密码就随机生成
./delete-db.sh 库名 [用户名]        # 删库删用户，删之前自动备份到 backups/
./check-user.sh [用户名]            # 查角色属性和各库权限，不给用户名就列全部
./backup.sh [库名]                  # 备份到 backups/，不给库名就 pg_dumpall 全部
```

`create-db.sh` 建出来的用户只能连自己那个库，其他库连不上，也拿不到 public schema 的默认权限。

## 常用命令

```bash
docker compose up -d        # 启动
docker compose down         # 停止（数据保留）
docker compose logs -f      # 看日志
docker compose exec postgres bash
docker compose exec postgres psql -U postgres    # 进 psql
```

## 导入已有的 SQL

```bash
docker compose exec -T postgres psql -U postgres -d 库名 < 某个文件.sql
```

大文件放进 `backups/` 目录，容器里挂在 `/backups`：

```bash
docker compose exec postgres psql -U postgres -d 库名 -f /backups/某个文件.sql
```

自定义格式的备份（`.dump` / `.bak`）用 `pg_restore`：

```bash
docker compose exec postgres pg_restore -U postgres -d 库名 --no-owner /backups/某个文件.dump
```

## 扩展

`init-scripts/01-init-extensions.sql` 只在**首次初始化**时对默认库执行一次，装了 uuid-ossp、pgcrypto、pg_trgm、btree_gin、btree_gist。

后来新建的库不会自动带这些扩展，要自己装：

```bash
docker compose exec postgres psql -U postgres -d 库名 -c 'CREATE EXTENSION IF NOT EXISTS "pgcrypto";'
```

## 说明

- PG18 的数据目录层级跟 17 及以前不一样，挂载点是 `/var/lib/postgresql`，实际数据在里面的 `18/docker/`，由 compose 里的 `PGDATA` 指定。
- `conf/postgresql.conf` 通过 `command` 里的 `config_file` 参数生效，改完要 `docker compose restart`。改之前先确认改动无误，配置写错会导致起不来，用 `docker compose logs` 看原因。
- 日志写在 `data/postgres/18/docker/log/` 下，超过 1 天或 100MB 换一个文件。执行超过 1 秒的语句会被记下来。
- 容器以 `1000:1000` 运行，OrbStack 会把文件属主映射成当前 Mac 用户。
