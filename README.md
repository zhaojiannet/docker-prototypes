# docker-prototypes

本机开发用的容器原型。每个目录是一套独立的 compose，起来就能用。

| 目录 | 镜像 | 容器名 |
|---|---|---|
| `MariaDB/` | mariadb:12.3.3 | mariadb-server |
| `MySQL/` | mysql:9.7.2 | mysql-server |
| `PostgreSQL/` | postgres:18.6 | postgres-server |
| `Valkey/` | valkey/valkey:9.1.2 | valkey-server |
| `Node-Template/` | 本地构建 | 按项目改名 |

## 起一个

```bash
cd MySQL
cp .env.example .env      # 填密码，可用 openssl rand -base64 24 生成
docker compose up -d
```

数据库那几个目录里还有几个脚本：`create-db.sh` 建库建用户、`check-user.sh` 查权限、`delete-db.sh` 删库、`backup.sh` 导出。

## 不入库的东西

`.env`（真实密码）、`data/`（数据库数据，400M 出头）、`backups/`（导出文件）。仓库里只有 `.env.example`。

所以在新机上 clone 下来之后，是一套干净的空壳：填好 `.env` 密码，`docker compose up -d` 起来的是全新数据库，旧数据不会跟过来。

## compose 用的是相对路径

挂载写的都是 `./data/mysql` 这种相对路径，所以整个目录搬到哪儿都行，搬完在新位置 `docker compose up -d` 即可，不用改配置。但要先 `docker compose down`：容器记的是绝对路径，不停就搬会指向旧位置。
