# Valkey

Valkey 9.1.2 开发环境。Valkey 是 Redis 改协议之后从最后一个开源版本分出来的分支，命令和协议跟 Redis 兼容，现有的 Redis 客户端库直接就能连。

数据在 named volume 里，`docker compose down` 不会删，`down -v` 才会。

## 启动

```bash
cp .env.example .env
# 改 .env 里的密码，可以用 openssl rand -base64 24 生成
docker compose up -d --wait
```

## 连接

- 主机 `localhost`，端口 `6379`（在 `.env` 里改 `VALKEY_PORT`）
- 密码见 `.env` 里的 `VALKEY_PASSWORD`
- 其他容器从 `dev-net` 网络连过来时：`redis://:密码@valkey:6379`。网络由先起的 compose 创建，不用手动建

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
- **RDB**（`/data/dump.rdb`）是定时快照，作为第二份保险。900 秒内有 1 次写、300 秒内有 10 次、60 秒内有 10000 次，各存一次。

想立刻存一次快照：

```bash
docker compose exec valkey sh -c 'valkey-cli --no-auth-warning -a "$VALKEY_PASSWORD" BGSAVE'
```

备份：`docker compose cp valkey:/data ./backups/` 把数据目录整个拷出来，服务运行中拷也可以。`../backup-all.sh` 不处理 Valkey。

## 说明

- 密码不写在 `conf/valkey.conf` 里，而是 compose 启动时用 `--requirepass` 从 `.env` 传进去，配置文件才能安全地进版本库。
- 健康检查必须带密码。设了 `requirepass` 之后，不带密码的 `ping` 会返回 NOAUTH，健康检查会一直失败。
- 内存上限 512MB，满了按最近最少使用淘汰（`allkeys-lru`）。当缓存用没问题；如果要当数据库存不能丢的数据，把 `conf/valkey.conf` 里的 `maxmemory-policy` 改成 `noeviction`。
