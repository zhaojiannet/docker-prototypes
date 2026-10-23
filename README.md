# docker-prototypes

Node、Go 项目和数据库的 Docker 模板，加一个管理它们的命令 `dp`。项目从这里复制出去后各自独立运行，仓库本身不被任何项目引用，服务器上也不用有它。

## 目录

```
dp                 命令入口，./dp help 看全部用法
cli/               dp 的子命令：project.sh、db.sh、remote.sh
templates/
  node/            Node 项目：Dockerfile（开发、构建、产物、Caddy 运行四段）、compose、Dependabot 配置
  go/              Go 项目：Dockerfile（开发、构建、distroless 运行三段）、compose、Dependabot 配置
  deploy/          部署到自建服务器的两种做法：pull/、push/，见其中的 README
databases/
  postgres/ mariadb/ mysql/ valkey/   每种一个 compose；三种 SQL 数据库加建库、删库、查用户、备份、恢复脚本
server/setup.sh    新服务器初始化
tests/             端到端测试：e2e.sh 是入口，cases.sh 是用例
docs/design.md     每条决定和依据
```

## 前提

Mac 加 OrbStack，bash 用系统自带的 3.2 就行。项目都放在 `~/Cores/Projects` 下一层（`DP_ROOT` 可改）：

```bash
git clone https://github.com/zhaojiannet/docker-prototypes.git ~/Cores/Projects/docker-prototypes
```

`dp` 不装到系统里，从仓库运行：仓库里 `./dp ...`，项目目录里 `../docker-prototypes/dp ...`，在项目目录里运行时项目名可以省略。

## 项目

```bash
dp new node my-site --astro                     # 复制模板、生成 Astro 站点、启动
dp new go my-svc --module example.com/my-svc
dp copy my-site my-site2                        # 以已有项目为底，只拷进了 git 的文件
dp clone git@github.com:me/my-site.git          # 换开发机时拉起已有项目
dp up|down|restart|status|update [<项目>|all]
dp logs [<项目>]
```

容器启动就跑开发服务器，访问 `https://<项目名>.orb.local`。`update` 拉最新的基础镜像并重建。基础镜像跟官方浮动（`node:lts-trixie-slim`、`golang:trixie`），不钉 digest：Node 跟官方当前的长期支持版，Go 跟官方最新版，大版本也跟着换。时区在项目 `.env` 的 `TZ` 里设，默认 `Asia/Tokyo`。

项目各自的依赖由各自仓库的 Dependabot 更新，见模板 README。

## 数据库

```bash
dp db new postgres                    # 复制到 ~/Cores/Projects/PostgreSQL、生成随机密码、建数据卷、启动
dp db create postgres my_site my_site # 建库建用户，打印密码
dp db users postgres
dp db drop postgres my_site
dp db backup postgres|all [库名]
dp db restore postgres <备份文件> [库名]
```

类型有 `postgres`、`mariadb`、`mysql`、`valkey`。每台机器每种一个实例，项目容器经网络 `docker-net` 用服务名连。镜像标签写到大版本线（如 `postgres:18-trixie`），`dp update PostgreSQL` 拿补丁；换大版本要导出导入，步骤见各目录 README 的「升级」。

## 服务器

新服务器以有 sudo 的用户登录后跑一次，可重复运行：

```bash
curl -fsSL https://raw.githubusercontent.com/zhaojiannet/docker-prototypes/main/server/setup.sh | sudo bash   # 运行中会问 SSH 的新端口
```

做的事：ufw 只放行 SSH，SSH 只用密钥、加一个新端口，fail2ban，没有 swap 时建一个，journald 持久化，时区，官方源装 Docker 并建 `docker-net`，系统安全更新和 Docker 自动安装、需要时凌晨自动重启。脚本最后会打印确认新端口能登录后关掉 22 的命令。

部署、回滚、只更新镜像补丁、备份拉回本机：

```bash
dp deploy [<项目>|all] [版本] [--host <别名>]
dp rollback <项目> <版本>
dp patch [<项目>|all] [--host <别名>]
dp remote-status [--host <别名>]
dp backup [<项目>] [备份项]
```

部署设置写在项目根的 `.env`，见 `templates/deploy/README.md`。

## 测试

`tests/e2e.sh` 在真的 Docker 上把 `dp` 的命令跑一遍：新建、复制、克隆项目并访问开发服务器，构建生产镜像，三种数据库的建库、备份、恢复、删库，拉取和推送两种部署的发布、回滚、补丁、备份拉回。`dp` 在 bash 3.2 下运行，和 macOS 自带的一样；部署的服务器由一个 ssh 容器扮演。

数据库模板的容器名、数据卷名和共用缓存卷是固定的，所以不在日常用的 Docker 上跑，脚本发现这些名字已存在就退出。本机测试用一台一次性的 OrbStack 虚拟机，第一次先建好：

```bash
orb create ubuntu:noble dp-e2e
orb -m dp-e2e -u root bash -c 'curl -fsSL https://get.docker.com | sh'
orb -m dp-e2e sudo usermod -aG docker "$USER"    # 虚拟机里的默认用户和 Mac 用户同名，Mac 上的跑法用它连 Docker
```

两种跑法，在仓库目录里运行：

```bash
E2E_MACHINE=dp-e2e tests/e2e.sh                         # dp 在 Mac 上运行，用的是 Mac 自带的 bash 和 BSD 工具；Docker 用虚拟机里的
orb -m dp-e2e -u root bash -c "cd '$PWD' && tests/e2e.sh"  # 全在虚拟机里，和 CI 一样
tests/e2e.sh postgres remote                            # 只跑几组，两种跑法都能这样加
```

修了一个错，就在 `tests/cases.sh` 里加一条能复现它的用例。

## 仓库的 CI

- `test.yml`：推送、PR、每周一跑 shellcheck、actionlint 和端到端测试。基础镜像跟官方浮动，每周跑一次能在项目更新之前发现新版本带来的问题。
- `db-eol.yml`：每周一查 `databases/` 里各数据库版本线的停止支持日期（endoflife.date），不到半年就开 issue。
- `scan.yml`：推送和 PR 时跑 gitleaks。

## 不入库的东西

`.env`（真实密码、部署地址）、`backups/`（数据库导出）。仓库里只有 `.env.example`。
