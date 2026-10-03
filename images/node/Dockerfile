FROM node:24.21.0-trixie-slim@sha256:8ec5d7557396cfe32d21c3f9c13072355ceab22b584578ca4bb28af31120cffe

ARG PNPM_VERSION=12.8.1

# store 必须显式指定：不指定时 pnpm 发现默认位置和 node_modules 不在同一文件系统，
# 会把 store 建到 node_modules/.pnpm-store 里，共享 volume 就没用上
ENV TZ=Asia/Tokyo \
    LANG=C.UTF-8 \
    DEV_USER=node \
    DEV_DIRS="/app /home/node/.local/share/pnpm" \
    PNPM_HOME=/home/node/.local/share/pnpm \
    pnpm_config_cache_dir=/home/node/.local/share/pnpm/cache \
    pnpm_config_store_dir=/home/node/.local/share/pnpm/store \
    PATH=/home/node/.local/share/pnpm/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata git \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "pnpm@${PNPM_VERSION}" \
    && npm cache clean --force

COPY --chmod=755 common/fix-user.sh /usr/local/bin/fix-user

# 这两个目录会被 volume 覆盖；空 volume 首次挂载继承镜像里同路径的属主，不预建就是 root 的
RUN mkdir -p /app/node_modules /home/node/.local/share/pnpm \
    && chown -R node:node /app /home/node/.local

USER node
WORKDIR /app

CMD ["sleep", "infinity"]
