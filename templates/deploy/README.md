# 部署到自建服务器

两种做法，按项目选一种，把对应目录的内容复制到项目根。两种都是服务器上一个 `compose.yaml` 加一个 `.env`，镜像都从镜像仓库拉，服务器上不构建。

| | 拉取（pull） | 推送（push） |
|---|---|---|
| 服务器上有项目仓库吗 | 有，`git pull` 拿新的 compose | 没有，本机把 `deploy/` 传过去 |
| 镜像谁构建 | 项目的 GitHub Actions，按提交号推到 ghcr | 别处已发布的镜像（开源软件的官方镜像这类），compose 里写死标签 |
| 版本是什么 | 提交号，记在服务器 `.env` 的 `IMAGE_TAG` | 提交号，记在服务器 `DEPLOY_DIR/REVISION` |
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

复制进项目的文件：

```
deploy/compose.yaml           把 PROJECT 换成项目名，IMAGE:TAG 换成镜像和标签
deploy/.env.example
deploy/backup.sh
scripts/deploy.sh
```

服务器上第一次只要在 `DEPLOY_DIR` 建好 `.env`（照 `deploy/.env.example`），目录不存在时 `scripts/deploy.sh` 会用 sudo 建。

`scripts/deploy.sh` 把 `deploy/` 在某个提交时的内容用 `git archive` 传过去，只覆盖不删除，`deploy/` 里删掉的文件要到服务器上手动删。`deploy/` 下有未提交的改动时拒绝部署。

## 本机的部署设置

写在项目根的 `.env`（不进 git），`dp` 读这三项：

```
DEPLOY_MODE=pull              # 或 push
DEPLOY_HOST=myserver          # ~/.ssh/config 里的别名
DEPLOY_DIR=/opt/<项目>/deploy  # 推送模式写服务器上放 compose 的目录
```

一台开发机可以对着多台服务器，各项目写各自的 `DEPLOY_HOST`。

## dp 命令

```bash
dp deploy [<项目>|all] [版本] [--host <别名>]   # 不写版本发布最新提交
dp rollback <项目> <版本>                       # 拉取模式写完整提交号，推送模式写 git 认的提交（HEAD~1 也行）
dp patch [<项目>|all] [--host <别名>]           # 代码不变，只重拉当前标签的镜像并重启
dp remote-status [--host <别名>]
dp backup [<项目>] [备份项]
```

`all` 指写了 `DEPLOY_MODE` 的全部项目，`--host` 再按服务器筛。一个失败不影响其他，最后汇总。

`patch` 的用处：拉取模式下 CI 每周一会用同一个提交号重建一次镜像，把基础镜像的补丁带进来，`patch` 让服务器拉到它；推送模式下标签只写到版本线时，`patch` 拉到这条线上的新版本。

## 备份

`dp backup` 把本机项目里的 `deploy/backup.sh` 经 ssh 送到服务器的 `DEPLOY_DIR` 里执行，再把生成的文件拉回本机 `~/Cores/Projects/backup/<项目>/`。服务器上每种备份留最近 5 份。

`backup.sh` 的约定：参数是备份项（不写就是 `all`），每生成一个文件就把它的路径（相对 `DEPLOY_DIR` 或绝对路径）打到标准输出，其他信息打到标准错误。模板里的 `env`、`db` 两项是示例，按项目实际改：库在共享实例或云数据库时改 `backup_db`，有上传文件的再加一项。

## 服务器初始化

新服务器先跑一次仓库里的 `server/setup.sh`，见仓库根 README。
