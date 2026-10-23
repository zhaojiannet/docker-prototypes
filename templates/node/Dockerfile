# 各项目保持同一份，项目之间的差别放 compose.yaml 和 .env。
# 标签跟官方浮动，不钉 digest：构建时加 --pull 就拿到官方当前的版本，大版本也跟着换
FROM node:lts-trixie-slim AS dev

# NODE_USE_SYSTEM_CA：OrbStack 把它的根证书装进容器的系统证书库，Node 默认不读系统库，
# 访问 https://*.orb.local 会报 SELF_SIGNED_CERT_IN_CHAIN；slim 镜像又不带系统证书库，所以要装 ca-certificates。
# store 必须显式指定：不指定时 pnpm 发现默认位置和 node_modules 不在同一文件系统，
# 会把 store 建到 node_modules/.pnpm-store 里，共享 volume 就没用上。
# confirm_modules_purge：容器里没有终端，pnpm 要重建 node_modules 时没法问，会直接报错退出
ENV NODE_USE_SYSTEM_CA=1 \
    PNPM_HOME=/home/node/.local/share/pnpm \
    pnpm_config_store_dir=/home/node/.local/share/pnpm/store \
    pnpm_config_cache_dir=/home/node/.local/share/pnpm/cache \
    pnpm_config_confirm_modules_purge=false \
    PATH=/home/node/.local/share/pnpm/bin:$PATH

# 这里装的 pnpm 只负责启动，项目实际用 package.json 里 packageManager 写的版本，pnpm 会自己下载切换。
# --before 和 pnpm-workspace.yaml 的 minimumReleaseAge 一样只取发布满 3 天的版本：
# dp new 把这个版本写进 packageManager，取到刚发布的就绕过了考察期
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g pnpm --before="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
    && npm cache clean --force

# 这两个目录会被 volume 覆盖；空 volume 首次挂载继承镜像里同路径的属主，不预建就是 root 的
RUN mkdir -p /app/node_modules /home/node/.local/share/pnpm \
    && chown -R node:node /app /home/node/.local

USER node
WORKDIR /app

# 开发服务器要监听 0.0.0.0，宿主机才访问得到。
# CUSTOM: Astro 的 .astro/dev.json 记着上次的进程号，容器停掉时不删；新容器的进程号从头分配，
# 撞上就以为服务器还在、拒绝启动。容器刚起来时不可能已有服务器，留下的一定是旧的
CMD ["sh", "-c", "rm -f .astro/dev.json && pnpm install && exec pnpm dev --host"]


FROM dev AS build

# 先只拷依赖清单，源码改了也能复用装依赖那一层
COPY --chown=node:node app/package.json app/pnpm-lock.yaml app/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY --chown=node:node app/ ./
RUN pnpm build


# 只有构建产物，推送模式部署（docker-prototypes 的 templates/deploy/push）用 --output 导出到本机再 rsync 到服务器
FROM scratch AS files
ARG OUTPUT_DIR=dist
COPY --from=build /app/${OUTPUT_DIR} /


FROM caddy:alpine AS runtime

# 构建产物目录，Astro、Vite 是 dist，Nuxt generate 是 .output/public
ARG OUTPUT_DIR=dist
# 镜像自带的 Caddyfile 在 :80 上把 /usr/share/caddy 当静态站点；要改路由、缓存头就在项目里放 Caddyfile 拷到 /etc/caddy/
COPY --from=build /app/${OUTPUT_DIR} /usr/share/caddy
