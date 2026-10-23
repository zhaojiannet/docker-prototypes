# Valkey

Valkey 9.1 开发环境，镜像标签 `valkey/valkey:9.1-trixie`。Valkey 是 Redis 改协议之后从最后一个开源版本分出来的分支，命令和协议跟 Redis 兼容，现有的 Redis 客户端库直接就能连。

数据在 named volume `valkey-data` 里，标了 `external`，compose 的任何命令（包括 `down -v`）都不会删它，`docker system prune` 加不加 `--volumes` 也删不到。会删数据的只有 `docker volume rm valkey-data`，以及容器已被删掉时的 `docker volume prune -a`，这两条不要用。

## 启动

`dp db new valkey` 一条命令做完下面这些，密码随机生成。手动做是这样：

```bash
cp .env.example .env
# 改 .env 里的密码，可以用 openssl rand -hex 24 生成
docker network inspect docker-net >/dev/null 2>&1 || docker network create docker-net   # 只在本机第一次需要
docker volume create valkey-data     # 只在第一次需要，卷已存在时什么也不做
docker compose up -d --wait
```

## 连接

- 主机 `localhost`，端口 `6379`（在 `.env` 里改 `VALKEY_PORT`）
- 密码见 `.env` 里的 `VALKEY_PASSWORD`
- 其他容器从 `docker-net` 网络连过来时：`redis://:密码@valkey:6379`

## 常用命令

```bash
docker compose up -d        # 启动
docker compose down         # 停止（数据保留）
docker compose logs -f      # 看日志

# 进命令行（密码从 .env 读）
docker compose exec valkey sh -c 'valkey-cli --no-auth-warning -a "$VALKEY_PASSWORD"'

# 直接执行一条命令
docker compose exec valkey sh -c 'valkey-cli --no-auth-warning -a "$VALKEY_PASSWORD" INFO memory'
```

## 持久化

AOF 和 RDB 两个都开着：

- **AOF**（`/data/appendonlydir/`）记录每一条写命令，每秒刷一次盘，最多丢一秒的数据。恢复时优先用它。
- **RDB**（`/data/dump.rdb`）是定时快照，作为第二份保险，按 Valkey 默认的频率存：1 小时内有 1 次写、5 分钟内有 100 次、1 分钟内有 10000 次。

想立刻存一次快照：

```bash
docker compose exec valkey sh -c 'valkey-cli --no-auth-warning -a "$VALKEY_PASSWORD" BGSAVE'
```

备份：`docker compose cp valkey:/data ./backups/` 把数据目录整个拷出来，服务运行中拷也可以。`dp db backup all` 不处理 Valkey。

## 升级

标签只写到版本线（9.1），`dp update Valkey` 拉这条线上的最新补丁并重建容器，数据不动。版本线离停止支持不到半年时，仓库的 CI 会开 issue 提醒。

## 说明

- 密码不写在 `conf/valkey.conf` 里，而是 compose 启动时用 `--requirepass` 从 `.env` 传进去，配置文件才能安全地进版本库。
- 健康检查必须带密码。设了 `requirepass` 之后，不带密码的 `ping` 会返回 NOAUTH，健康检查会一直失败。
- 内存用 Valkey 的默认设置：不设上限，也不会自动删数据。只拿来做缓存、希望满了自动清旧数据的项目，在 `conf/valkey.conf` 里加 `maxmemory` 和 `maxmemory-policy allkeys-lru`。
