# MySQL

MySQL 9.7.2（官方 lts 标签）开发环境。数据在 named volume 里，`docker compose down` 不会删，`down -v` 才会。

## 启动

```bash
cp .env.example .env
# 改 .env 里的两个密码，可以用 openssl rand -base64 24 生成
docker compose up -d --wait
```

`--wait` 会等到健康检查通过才返回，首次启动初始化要几十秒。

## 连接

- 主机 `localhost`，端口 `3306`（在 `.env` 里改 `MYSQL_PORT`）
- 用户名密码见 `.env`
- 其他容器从 `dev-net` 网络连过来时，主机名用 `mysql`，端口 `3306`。网络由先起的 compose 创建，不用手动建

## 脚本

```bash
./create-db.sh 库名 用户名 [密码]   # 建库建用户并授权，不给密码就随机生成
./delete-db.sh 库名 [用户名]        # 删库删用户，删之前自动备份到 backups/
./check-user.sh [用户名]            # 查用户和权限，不给用户名就列全部
./backup.sh [库名]                  # 备份到 backups/，不给库名就备份全部
../backup-all.sh                    # 同级几个数据库一起整库备份，并清理旧备份，规则见脚本
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

## 说明

- `conf/custom.cnf` 里的 `lower_case_table_names=1` 只在数据库首次初始化时生效。已经建过库之后再改这个值，MySQL 会拒绝启动。
- 备份用的是 `--set-gtid-purged=OFF`，导出的 SQL 不带 GTID 信息，恢复到别的实例不会冲突。
