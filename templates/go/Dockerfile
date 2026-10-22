# 各项目保持同一份，项目之间的差别放 compose.yaml 和 .env。
# 标签跟官方浮动，不钉 digest：构建时加 --pull 就拿到官方当前的版本，大版本也跟着换
FROM golang:trixie AS dev

WORKDIR /app

# air 用 go.mod 的 tool 指令登记在项目里，版本跟着项目走
CMD ["go", "tool", "air"]


FROM dev AS build

# 先只拷 go.mod、go.sum，源码改了也能复用下载模块那一层；没有依赖时没有 go.sum，所以用通配
COPY app/go.* ./
RUN go mod download
COPY app/ ./
# cmd/ 下每个目录编出一个同名程序；静态链接，distroless 里没有 libc 也能跑
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/ ./cmd/...


FROM gcr.io/distroless/static:nonroot AS runtime

# 不设 ENTRYPOINT：一个项目可能有多个程序，用哪个由 compose 的 command 指定，如 ["api"]
COPY --from=build /out/ /usr/local/bin/
