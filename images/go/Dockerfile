FROM golang:1.27.1-trixie@sha256:8f58fd67ea075142d947a60e0caa4317746a55118d312f027793d382c7741734

ENV TZ=Asia/Tokyo \
    LANG=C.UTF-8 \
    DEV_USER=go \
    DEV_DIRS="/app /go" \
    GOMODCACHE=/go/pkg/mod \
    GOCACHE=/go/cache

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends ca-certificates tzdata git \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 common/fix-user.sh /usr/local/bin/fix-user

# 官方镜像只有 root；建一个普通用户，并预建会被 volume 覆盖的两个缓存目录
RUN groupadd -g 1000 go \
    && useradd -m -u 1000 -g go -s /bin/bash go \
    && mkdir -p /app /go/pkg/mod /go/cache /go/bin \
    && chown -R go:go /app /go

USER go
WORKDIR /app

CMD ["sleep", "infinity"]
