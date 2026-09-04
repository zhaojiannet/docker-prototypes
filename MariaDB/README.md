# MariaDB

MariaDB 12.3.3（官方 latest / lts 标签）开发环境。数据存在本目录的 `data/mysql/`，容器删了数据还在。

跟 MySQL 是两套独立的东西，端口用 3307 错开，两个可以同时跑。

## 启动

```bash
cp .env.example .env
# 改 .env 里的两个密码，可以用 openssl rand -base64 24 生成
mkdir -p data/mysql              # 必须先建，否则 Docker 会以 root 建出来
docker compose up -d --wait
```

## 连接

- 主机 `localhost`，端口 `3307`（在 `.env` 里改 `MARIADB_PORT`）
- 用户名密码见 `.env`
- 其他容器从 `docker-net` 网络连过来时，主机名用 `mariadb-server`，端口 `3306`

## 脚本

```bash
./create-db.sh 库名 用户名 [密码]   # 建库建用户并授权，不给密码就随机生成
./delete-db.sh 库名 [用户名]        # 删库删用户，删之前自动备份到 backups/
./check-user.sh [用户名]            # 查用户和权限，不给用户名就列全部
./backup.sh [库名]                  # 备份到 backups/，不给库名就备份全部
```

## 常用命令

```bash
docker compose up -d        # 启动
docker compose down         # 停止（数据保留）
docker compose logs -f      # 看日志
docker compose exec mariadb bash
docker compose exec mariadb mariadb -uroot -p    # 进命令行
```

## 导入旧版本的 dump

从 11.4 或更老的服务器导出的 SQL，导进 12.3 之后要跑一次升级，把系统表结构对齐：

```bash
# 1. 导入
docker compose exec -T mariadb mariadb -uroot -p'密码' 库名 < 某个文件.sql

# 2. 升级系统表
docker compose exec mariadb mariadb-upgrade -uroot -p'密码'
```

不跑第 2 步，平时能用，但涉及权限表、存储过程、时区表的操作可能报错。

大文件放进 `backups/` 目录，容器里挂在 `/backups`：

```bash
docker compose exec mariadb sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" 库名 < /backups/某个文件.sql'
```

## 说明

- 客户端命令是 `mariadb` / `mariadb-dump` / `mariadb-admin`，旧的 `mysql` 名字在 12.x 里还留着但已经不推荐用。
- 默认认证插件是 `mysql_native_password`，跟 MySQL 9.x 的 `caching_sha2_password` 不同。老客户端连 MariaDB 反而更省事。
- `conf/custom.cnf` 用的是 `[mariadbd]` 配置节，`lower_case_table_names=1` 只在首次初始化时生效。
- 健康检查用的是镜像自带的 `healthcheck.sh --connect --innodb_initialized`，会确认 InnoDB 真的初始化完成，比单纯 ping 可靠。
