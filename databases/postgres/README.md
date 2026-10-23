# PostgreSQL

PostgreSQL 18 开发环境，镜像标签 `postgres:18-trixie`。数据在 named volume `postgres-data` 里，标了 `external`，compose 的任何命令（包括 `down -v`）都不会删它，`docker system prune` 加不加 `--volumes` 也删不到。会删数据的只有 `docker volume rm postgres-data`，以及容器已被删掉时的 `docker volume prune -a`，这两条不要用。

## 启动

`dp db new postgres` 一条命令做完下面这些，密码随机生成。手动做是这样：

```bash
cp .env.example .env
# 改 .env 里的密码，可以用 openssl rand -hex 24 生成
docker network inspect docker-net >/dev/null 2>&1 || docker network create docker-net   # 只在本机第一次需要
docker volume create postgres-data     # 只在第一次需要，卷已存在时什么也不做
docker compose up -d --wait
```

## 连接

- 主机 `localhost`，端口 `5432`（在 `.env` 里改 `POSTGRES_PORT`）
- 用户名密码见 `.env`
- 其他容器从 `docker-net` 网络连过来时，主机名用 `postgres`，端口 `5432`

## 脚本

```bash
./create-db.sh 库名 用户名 [密码]   # 建库建用户，收紧 public schema 权限，不给密码就随机生成
./delete-db.sh 库名 [用户名]        # 删库删用户，删之前自动备份到 backups/
./check-user.sh [用户名]            # 查角色属性和各库权限，不给用户名就列全部
./backup.sh [库名]                  # 备份到 backups/，不给库名就 pg_dumpall 全部
./restore.sh 备份文件 [库名]        # 从备份恢复，覆盖前先备份当前的库，规则见脚本开头
```

`create-db.sh` 建出来的用户只能连自己那个库，其他库连不上，也拿不到 public schema 的默认权限。

## 排序规则

`create-db.sh` 建库时用 `TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'PG_UNICODE_FAST' LOCALE 'C.UTF-8'`。建库语句里写明了这些，所以在已经初始化过的实例上新建的库也是这套；已经存在的库不受影响，同名库再跑 `create-db.sh` 也不会改它的排序规则。compose 里的 `POSTGRES_INITDB_ARGS` 用同一套参数，只对新初始化的数据卷生效，让 `postgres` 库和 `template1` 也一样。

`PG_UNICODE_FAST` 是 PostgreSQL 自带的 locale，按码位排序：大写排在小写前，平假名整块排在片假名前，全角字母排在最后。大小写转换用 Unicode 的完整映射，`casefold('Straße')` 得 `strasse`。

选它是因为只依赖 PostgreSQL 本身，比较也最快。libc 的 locale 依赖系统 glibc，ICU 的依赖 ICU 库版本，这两样升级后排序都可能变化，文本索引要重建。builtin 的排序就是按码位比较，升级也不会变，`datcollversion` 固定是 `1`，普通文本索引不用因为升级重建。会变的是大小写转换和字符分类，它们跟着 PostgreSQL 自带的 Unicode 数据走，大版本升级时可能变化，而且没有版本警告。所以升级大版本时要看发布说明，有相关变化就重建用到 `lower`、`upper`、`casefold` 的表达式索引和生成列，以及 pg_trgm 的索引。

查某个库现在的排序设置：

```sql
SELECT datlocprovider, datlocale, datcollversion FROM pg_database WHERE datname = '库名';
```

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

实例不预装扩展，哪个库要用就在那个库里装，最好写进项目自己的迁移脚本，换机器、重建库时会跟着走：

```bash
docker compose exec postgres psql -U postgres -d 库名 -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'
```

生成 UUID 用自带的 `gen_random_uuid()`、`uuidv7()`，不用装 uuid-ossp、pgcrypto。

## 升级

标签只写到版本线（18），`dp update PostgreSQL` 拉这条线上的最新补丁并重建容器，数据不动。换大版本不能只改标签，要先 `dp db backup postgres` 导出、换标签建新数据卷、再 `./restore.sh` 导入；版本线离停止支持不到半年时，仓库的 CI 会开 issue 提醒。

## 说明

- PG18 的数据目录层级跟 17 及以前不一样，挂载点是 `/var/lib/postgresql`，实际数据在里面的 `18/docker/`，由 compose 里的 `PGDATA` 指定。
- `conf/postgresql.conf` 通过 `command` 里的 `config_file` 参数生效，改完要 `docker compose restart`。改之前先确认改动无误，配置写错会导致起不来，用 `docker compose logs` 看原因。
- 日志写在数据目录的 `log/` 下（容器内 `/var/lib/postgresql/18/docker/log/`），超过 1 天或 100MB 换一个文件。执行超过 1 秒的语句会被记下来。
