# 扮演部署用的服务器：dp 经 ssh 连进来，docker 命令经挂进来的 socket 交给宿主的 Docker
FROM alpine:3.24
# root 默认是锁定的，锁定的账号 sshd 连密钥登录也拒绝，改成无密码可用；
# 测试里的 git 仓库属于 uid 1000，git 默认不读别的用户的仓库
# rsync、coreutils（mv -T）和 Ubuntu 服务器上的一样
RUN apk add --no-cache bash coreutils docker-cli docker-cli-compose git openssh-server rsync tar \
    && ssh-keygen -A \
    && echo 'root:*' | chpasswd -e \
    && git config --system safe.directory "*" \
    && mkdir -p /root/.ssh && chmod 700 /root/.ssh
CMD ["/usr/sbin/sshd", "-D", "-e"]
