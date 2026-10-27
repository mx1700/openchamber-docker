# OpenChamber Docker + GitHub Actions

用 GitHub Actions 构建 OpenChamber 镜像并推送到 GHCR，家里服务器只负责拉取镜像和运行。这样不需要在服务器上构建，也不需要让容器自己改自己。

```
GitHub Actions
  └─ 每天检查 OpenChamber 最新版
       └─ 自动选择匹配的 OpenCode 版本
            └─ build linux/amd64 + linux/arm64
                 └─ push ghcr.io/<owner>/openchamber:latest

家里服务器
  └─ systemd timer 定时 docker compose pull
       └─ 有新镜像就重建 openchamber 容器
            └─ cloudflared 继续提供 Cloudflare Tunnel
```

## 目录

```text
.
├─ .github/workflows/build.yml     # GitHub Actions：构建并推送 GHCR
├─ Dockerfile                      # Node 24 + 官方 npm 包，无前端构建
├─ docker-compose.yml              # 服务器运行配置
├─ .env.example                    # 环境变量模板
├─ scripts/update-image.sh         # 服务器拉取镜像并等待健康
├─ deploy/openchamber-update.service
├─ deploy/openchamber-update.timer
└─ README.md
```

## 1. 创建 GitHub 仓库

把整个项目推到 GitHub，例如仓库名 `openchamber-docker`：

```bash
cd /f/openchamber-docker
git init -b main
git add .
git commit -m "Initial OpenChamber Docker deployment"
git remote add origin git@github.com:mx1700/openchamber-docker.git
git push -u origin main
```

也可以在 GitHub 网页新建仓库后按页面提示推送。

## 2. 打开 Actions 写权限

GitHub 仓库：

```text
Settings → Actions → General → Workflow permissions
→ 选择 Read and write permissions
→ Save
```

否则 `GITHUB_TOKEN` 没有 `packages: write`，推送 GHCR 会失败。

## 3. GitHub Actions 会做什么

`.github/workflows/build.yml` 会在以下时机运行：

- push 到 `main`
- 每天 `18:17 UTC`（北京时间 02:17）
- 手动 `workflow_dispatch`

每次运行：

1. `npm view @openchamber/web version` 取最新 OpenChamber 版本
2. 从它的依赖里取匹配的 `@opencode/client` 版本
3. 用这个版本安装对应的 `@opencode/cli`
4. 构建 `linux/amd64` 和 `linux/arm64`
5. 推送 GHCR：
   - `ghcr.io/<owner>/openchamber:latest`
   - `ghcr.io/<owner>/openchamber:<openchamber版本>`，例如 `2.5.2`
   - `ghcr.io/<owner>/openchamber:sha-<短commit>`

如果你只需要 x86，可以把 workflow 里的：

```yaml
platforms: linux/amd64,linux/arm64
```

改成：

```yaml
platforms: linux/amd64
```

ARM 构建会走 QEMU，时间会更长。

## 4. 设置 GHCR 包可见性

第一次 Actions 成功后，打开：

```text
GitHub 个人主页 → Packages → openchamber
```

如果服务器不想登录 GHCR，把包设为 **Public**。

如果保持 Private，服务器需要登录：

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u mx1700 --password-stdin
```

`GHCR_TOKEN` 使用 Classic PAT，至少勾选：

```text
read:packages
```

注意：自动更新服务以 root 运行，所以如果包是 Private，需要让 root 也能读到 Docker 登录凭据：

```bash
sudo docker login ghcr.io -u mx1700
```

或者直接把包设为 Public，最省事。

## 5. 部署到服务器

假设部署目录是 `/opt/openchamber`：

```bash
sudo mkdir -p /opt/openchamber
sudo chown "$USER":"$USER" /opt/openchamber
git clone https://github.com/mx1700/openchamber-docker.git /opt/openchamber
cd /opt/openchamber
```

创建 `.env`：

```bash
cp .env.example .env
chmod 600 .env
nano .env
```

至少要改：

```env
OPENCHAMBER_IMAGE=ghcr.io/mx1700/openchamber:latest

OPENCHAMBER_UI_PASSWORD=一段足够长的随机密码
OPENCODE_JWT_SECRET=openssl rand -hex 32 的输出
CLOUDFLARE_TUNNEL_TOKEN=Cloudflare 后台 Add a replica 里的 eyJ...

LAN_BIND=192.168.1.50
LAN_PORT=8080
OPENCHAMBER_LAN_URL=http://192.168.1.50:8080
```

准备数据目录：

```bash
mkdir -p data/openchamber \
  data/opencode/share \
  data/opencode/state \
  data/opencode/config \
  data/ssh \
  workspaces

sudo chown -R 1000:1000 data workspaces
```

启动：

```bash
docker compose up -d
docker compose logs -f openchamber cloudflared
```

检查：

```bash
docker compose exec openchamber openchamber --version
docker compose exec openchamber opencode --version
curl -fsS http://127.0.0.1:8080/health | head
```

> `OPENCHAMBER_IMAGE` 里的 owner 必须是小写。GitHub 用户名有大写时，GHCR 路径也要用小写；workflow 已经自动转小写。

## 6. Cloudflare Tunnel

Cloudflare Zero Trust：

```text
Networks → Tunnels
→ 选中你的 tunnel
→ Public Hostname
```

| 字段 | 值 |
|---|---|
| Subdomain | `oc` |
| Domain | `example.com` |
| Path | 留空 |
| Service | `HTTP` |
| URL | `openchamber:3000` |

保存后访问：

```text
https://oc.example.com
```

Token 来自 tunnel 的 **Add a replica** 页面，不是 Cloudflare API Token。

## 7. 自动更新服务器镜像

安装 systemd timer：

```bash
sudo cp deploy/openchamber-update.service /etc/systemd/system/
sudo cp deploy/openchamber-update.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now openchamber-update.timer
```

查看状态：

```bash
systemctl list-timers openchamber-update.timer
journalctl -u openchamber-update -f
```

手动触发一次：

```bash
sudo systemctl start openchamber-update.service
```

或者直接：

```bash
./scripts/update-image.sh
```

脚本做的事：

```bash
docker compose pull openchamber
docker compose up -d openchamber
# 等待 Dockerfile 里的 HEALTHCHECK 变成 healthy
```

如果镜像没有变化，`docker compose up -d` 不会无意义重启容器。

## 8. 回滚

workflow 会给每个版本打 tag，例如：

```text
ghcr.io/mx1700/openchamber:2.5.2
ghcr.io/mx1700/openchamber:sha-abc1234
```

回滚时改 `.env`：

```env
OPENCHAMBER_IMAGE=ghcr.io/mx1700/openchamber:2.5.2
```

然后：

```bash
docker compose pull openchamber
docker compose up -d openchamber
```

回滚镜像不会回滚 `data/`；大版本升级前建议备份数据。

## 9. 局域网访问

Compose 默认发布：

```text
0.0.0.0:8080 -> 容器 3000
```

局域网访问：

```text
http://192.168.1.50:8080
```

建议把 `LAN_BIND` 固定为服务器局域网 IP：

```env
LAN_BIND=192.168.1.50
```

这样不会监听公网接口。注意 Docker 发布的端口会绕过普通 UFW 规则；要限制来源，绑定 LAN IP 最直接，或者用 `DOCKER-USER` 链。

局域网 HTTP 下：

- Passkey 不可用（需要 HTTPS）
- PWA 不能安装（Service Worker 需要安全上下文）
- 只能使用 OpenChamber 密码登录

Cloudflare 域名仍然是 HTTPS，不受影响。

## 10. 安全建议

- `.env` 权限设为 `600`，不要提交到 Git
- Cloudflare Tunnel Token 泄露后，在 tunnel 详情里 **Rotate token**
- 公网入口建议加 Cloudflare Access，只允许你的邮箱
- 不要把 `/var/run/docker.sock` 挂给 OpenChamber
- 不要用 `user: root` 运行 OpenChamber
- 定期备份 `data/`，里面包含设置、会话、认证 token 和 SSH key
- 容器内不需要自更新；更新由 GitHub Actions + 服务器拉镜像完成

## 11. 常见问题

### Actions 推送 GHCR 报 permission denied

检查：

```text
Settings → Actions → General → Workflow permissions
```

必须是 **Read and write permissions**。

### 服务器 pull 报 denied

- 包是 Private，但服务器没登录 GHCR
- 或自动更新服务以 root 运行，root 没有登录

最省事：把 GHCR 包设为 Public。

### cloudflared 报 `Provided Tunnel token is not valid`

- 复制错成了 Cloudflare API Token
- 复制不完整
- `.env` 有 CRLF，执行 `sed -i 's/\r$//' .env`
- 修改 `.env` 后没有重建容器：

```bash
docker compose up -d --force-recreate cloudflared
```

### 容器一直 unhealthy

```bash
docker compose logs --tail 200 openchamber
docker compose exec openchamber opencode --version
```

健康检查要求 OpenChamber 和它管理的 OpenCode 都 ready。第一次启动或 provider 配置有问题时，可能一直不健康。

### 更新后想立刻回滚

把 `.env` 的 `OPENCHAMBER_IMAGE` 改成旧版本 tag，然后：

```bash
docker compose pull openchamber
docker compose up -d --force-recreate openchamber
```

## 12. 为什么不用容器内自更新

OpenChamber 的 npm 包可以自更新，但在容器里：

- 需要给运行用户写 `/usr/local` 或自定义 npm prefix
- 更新只写入容器层，重建容器会丢
- 容器模式下 OpenChamber 只安装新包，不会自动重启自己
- 镜像版本和容器内版本容易漂移

这个项目采用“镜像不可变 + CI 构建 + 服务器拉取”的方式，更新频率再高也只需要定时任务跟着跑。
