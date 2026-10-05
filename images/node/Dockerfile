FROM node:24.21.0-trixie-slim@sha256:8ec5d7557396cfe32d21c3f9c13072355ceab22b584578ca4bb28af31120cffe

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

# 装完 pnpm 就删掉 npm 和 corepack：pnpm 覆盖它们的全部用途（pkg、create、dlx），
# 而官方镜像自带的 npm 随 Node 发布节奏更新，其依赖里的已知漏洞修得慢。
# pnpm 版本写在 node/package.json 的依赖里，是为了让 Dependabot 按 npm 包盯它的新版本
RUN --mount=type=bind,source=node/package.json,target=/tmp/pnpm-version.json \
    apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends ca-certificates tzdata git \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "pnpm@$(node -p 'require("/tmp/pnpm-version.json").dependencies.pnpm')" \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
       /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /root/.npm

COPY --chmod=755 common/fix-user.sh /usr/local/bin/fix-user

# 这两个目录会被 volume 覆盖；空 volume 首次挂载继承镜像里同路径的属主，不预建就是 root 的
RUN mkdir -p /app/node_modules /home/node/.local/share/pnpm \
    && chown -R node:node /app /home/node/.local

USER node
WORKDIR /app

CMD ["sleep", "infinity"]
