# 运行 dp 的环境：bash 和 macOS 自带的一样是 3.2，只在 3.2 下才出的错这里能测出来
FROM bash:3.2
# 数据库脚本写的是 #!/bin/bash，镜像里的 bash 在 /usr/local/bin；
# busybox 的 tar 不认 dp copy 用的 --null，装 GNU tar（macOS 的 bsdtar 认）。
# ssh 按账号记录里的家目录找 ~/.ssh，不看 $HOME，所以要有 uid 1000 的账号
RUN apk add --no-cache curl docker-cli docker-cli-compose git gzip openssh-client openssl tar \
    && ln -sf /usr/local/bin/bash /bin/bash \
    && adduser -D -u 1000 -h /home/tester tester
