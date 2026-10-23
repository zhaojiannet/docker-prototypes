# MySQL

MySQL 9.7 开发环境，镜像标签 `mysql:9.7`，9.7 是长期支持版。数据在 named volume `mysql-data` 里，标了 `external`，compose 的任何命令（包括 `down -v`）都不会删它，`docker system prune` 加不加 `--volumes` 也删不到。会删数据的只有 `docker volume rm mysql-data`，以及容器已被删掉时的 `docker volume prune -a`，这两条不要用。

## 启动

`dp db new mysql` 一条命令做完下面这些，密码随机生成。手动做是这样：

```bash
cp .env.example .env
# 改 .env 里的两个密码，可以用 openssl rand -hex 24 生成
docker network inspect docker-net >/dev/null 2>&1 || docker network create docker-net   # 只在本机第一次需要
docker volume create mysql-data     # 只在第一次需要，卷已存在时什么也不做
docker compose up -d --wait
```

`--wait` 会等到健康检查通过才返回，首次启动初始化要几十秒。

## 连接

- 主机 `localhost`，端口 `3306`（在 `.env` 里改 `MYSQL_PORT`）
- 用户名密码见 `.env`
- 其他容器从 `docker-net` 网络连过来时，主机名用 `mysql`，端口 `3306`

## 脚本

```bash
./create-db.sh 库名 用户名 [密码]   # 建库建用户并授权，不给密码就随机生成
./delete-db.sh 库名 [用户名]        # 删库删用户，删之前自动备份到 backups/
./check-user.sh [用户名]            # 查用户和权限，不给用户名就列全部
./backup.sh [库名]                  # 备份到 backups/，不给库名就备份全部
./restore.sh 备份文件 [库名]        # 从备份恢复，覆盖前先备份当前的库，规则见脚本开头
```

## 常用命令

```bash
docker compose up -d        # 启动
docker compose down         # 停止（数据保留）
docker compose logs -f      # 看日志
docker compose exec mysql bash   # 进容器
docker compose exec mysql mysql -uroot -p   # 进 MySQL 命令行
```

## 导入已有的 SQL

```bash
docker compose exec -T mysql mysql -uroot -p'密码' 库名 < 某个文件.sql
```

大文件放进 `backups/` 目录，容器里挂在 `/backups`，可以直接在容器内读：

```bash
docker compose exec mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" 库名 < /backups/某个文件.sql'
```

## 升级

标签只写到版本线（9.7），`dp update MySQL` 拉这条线上的最新补丁并重建容器，数据不动。换大版本不能只改标签，要先 `dp db backup mysql` 导出、换标签建新数据卷、再 `./restore.sh` 导入；版本线离停止支持不到半年时，仓库的 CI 会开 issue 提醒。

## 说明

- `conf/custom.cnf` 里的 `lower_case_table_names=1` 只在数据库首次初始化时生效。已经建过库之后再改这个值，MySQL 会拒绝启动。
- 备份用的是 `--set-gtid-purged=OFF`，导出的 SQL 不带 GTID 信息，恢复到别的实例不会冲突。
