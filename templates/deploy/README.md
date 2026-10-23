# 部署到自建服务器

两种做法，按项目选一种，把对应目录的内容复制到项目根。

| | 拉取（pull） | 推送（push） |
|---|---|---|
| 适合 | 在服务器上以容器运行：Go 服务，或用 Node 模板 `runtime` 段（Caddy）打包的静态站点 | 静态站点（Astro、Vite、Nuxt generate 这类）的文件直接交给服务器上已有的反向代理 |
| 谁构建 | 项目的 GitHub Actions，按提交号推镜像到 ghcr | 本机，用 `Dockerfile` 的 `files` 段构建 |
| 服务器上有什么 | 项目仓库、`deploy/compose.yaml` 和 `.env`，容器从 ghcr 拉镜像运行 | `DEPLOY_DIR/releases/<提交号>/` 下的产物文件，`current` 指向正在用的那版 |
| 版本记在哪 | 服务器 `deploy/.env` 的 `IMAGE_TAG` | `DEPLOY_DIR/current` 指向的目录名 |
| 发布脚本在哪运行 | 服务器上的 `deploy/deploy.sh` | 本机的 `scripts/deploy.sh` |

## 拉取模式

复制进项目的文件：

```
.github/workflows/image.yml   推到 main、每周一、手动触发时构建 Dockerfile 的 runtime 段，推 ghcr.io/<仓库>:<提交号>
deploy/compose.yaml           把 PROJECT、OWNER/REPO 换成项目名和仓库名（全小写，ghcr 只认小写）
deploy/.env.example
deploy/deploy.sh
deploy/backup.sh
```

服务器上第一次：

```bash
sudo git clone <仓库地址> /opt/<项目>
sudo chown -R "$(id -un):" /opt/<项目>
cd /opt/<项目>/deploy && cp .env.example .env    # 填生产的变量
./deploy.sh
```

仓库是私有的话，服务器要先配好拉代码的 deploy key，以及 `docker login ghcr.io`。

`deploy.sh` 先 `git pull`，再按提交号拉镜像、`up --wait`，成功后才把提交号写进 `.env`。镜像拉不下来时旧版本不受影响；新版本起不来时自动换回原来的版本。服务器上只留当前和上一版的镜像。

## 推送模式

复制进项目的文件只有 `scripts/deploy.sh`，项目要用 Node 模板的 `Dockerfile`（有 `files` 段）。

`scripts/deploy.sh` 在本机构建，把产物 rsync 到服务器的 `DEPLOY_DIR/releases/<提交号>/`，再把 `DEPLOY_DIR/current` 这个软链接指过去。没变的文件和上一版共用硬链接，不重传也不多占空间；软链接是改名换上去的，访问不会看到传了一半的文件。服务器上留最近 5 版，回滚就是把 `current` 指回其中一版，不重新构建。`app/`、`Dockerfile` 有未提交的改动时拒绝部署。产物目录不是 `dist` 时在 `.env` 里写 `OUTPUT_DIR`（Nuxt generate 是 `.output/public`）。

服务器上要有 `rsync`（`server/setup.sh` 会装），目录不存在时 `scripts/deploy.sh` 会用 sudo 建。

网站由服务器上已有的反向代理托管，把站点根目录设成 `DEPLOY_DIR/current`。代理跑在容器里时，挂载整个 `DEPLOY_DIR`，不要只挂 `current`：挂载软链接时 Docker 在容器启动那一刻就解析成目标目录，之后切换版本容器里看不到。例如 Caddy：

```
# compose：- /srv/my-site:/srv/my-site:ro
my-site.example.com {
	root * /srv/my-site/current
	file_server
}
```

## 本机的部署设置

写在项目根的 `.env`（不进 git），`dp` 读这三项：

```
DEPLOY_MODE=pull              # 或 push
DEPLOY_HOST=myserver          # ~/.ssh/config 里的别名
DEPLOY_DIR=/opt/<项目>/deploy  # 推送模式写放产物的目录，比如 /srv/<站点>
```

一台开发机可以对着多台服务器，各项目写各自的 `DEPLOY_HOST`。

## dp 命令

```bash
dp deploy [<项目>|all] [版本] [--host <别名>]   # 不写版本发布最新提交
dp rollback <项目> <版本>                       # 拉取模式写完整提交号，推送模式写 git 认的提交（HEAD~1 也行），只能回到服务器上还留着的版本
dp patch [<项目>|all] [--host <别名>]           # 拉取模式：代码不变，只重拉当前标签的镜像并重启
dp remote-status [--host <别名>]
dp backup [<项目>] [备份项]
```

`all` 指写了 `DEPLOY_MODE` 的全部项目，`--host` 再按服务器筛。一个失败不影响其他，最后汇总。

`patch` 的用处：CI 每周一会用同一个提交号重建一次镜像，把基础镜像的补丁带进来，`patch` 让服务器拉到它。推送模式没有镜像，`patch all` 跳过它们。

## 备份

`dp backup` 把本机项目里的 `deploy/backup.sh` 经 ssh 送到服务器的 `DEPLOY_DIR` 里执行，再把生成的文件拉回本机 `~/Cores/Projects/backup/<项目>/`。服务器上每种备份留最近 5 份。推送模式的产物随时能从提交重新构建，不用备份。

`backup.sh` 的约定：参数是备份项（不写就是 `all`），每生成一个文件就把它的路径（相对 `DEPLOY_DIR` 或绝对路径）打到标准输出，其他信息打到标准错误。模板里的 `env`、`db` 两项是示例，按项目实际改：库在共享实例或云数据库时改 `backup_db`，有上传文件的再加一项。

## 服务器初始化

新服务器先跑一次仓库里的 `server/setup.sh`，见仓库根 README。
