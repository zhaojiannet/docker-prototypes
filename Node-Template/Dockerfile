# Node.js 开发容器
# 先起一个空容器，再进容器里初始化项目，宿主机上不装任何东西

FROM node:24-trixie-slim

# node 用户在官方镜像里本来就是 1000:1000，这里显式对齐一次，
# 换基础镜像时如果 uid 变了也不会踩坑
RUN usermod -u 1000 node 2>/dev/null || true; \
    groupmod -g 1000 node 2>/dev/null || true

# node_modules 和 .pnpm-store 这两个目录必须在镜像里先建好并改属主。
# docker-compose 把 named volume 挂到这两个位置，Docker 会拿镜像里同路径的
# 属主去初始化 volume；镜像里没有这个目录，volume 就会是 root 的，
# 容器内的 node 用户写不进去
RUN mkdir -p /app/node_modules /app/.pnpm-store && \
    chown -R 1000:1000 /app

RUN corepack enable

USER node
WORKDIR /app

# 必须以 node 用户身份装，corepack 的缓存才落在 /home/node/.cache。
# 以 root 装会落到 /root/.cache，node 用户读不到，每次跑 pnpm 都要重新下载
RUN corepack prepare pnpm@latest --activate

# 容器空转，命令都用 docker compose exec 进来执行
CMD ["tail", "-f", "/dev/null"]
