# VPS First Initializer

这是一个面向 Debian/Ubuntu/Alpine VPS 首次登录的初始化脚本。默认你用 `root` 登录执行，脚本会创建 `nini` 用户、拉取 GitHub 公钥、把 SSH 改到 `22222`，然后禁用 root 登录和密码登录。

默认配置：

- 用户：`nini`
- SSH 端口：`22222`
- 公钥来源：`https://github.com/telly3e.keys`
- sudo：`nini` 可免密码 sudo
- 时间同步：Debian/Ubuntu 使用 `systemd-timesyncd`；Alpine 使用 `chrony` 和 OpenRC
- TCP 调优：写入固定 Proxy VPS sysctl 配置，启用 BBR、IPv4/IPv6 转发和大缓冲区参数
- Swap：默认创建 `/swapfile`，大小 `2G`，自动兼容 btrfs
- UFW：默认安装并启用，入站默认拒绝，出站默认允许；Alpine 从 `community` 仓库安装
- SSHGuard：默认安装并启用；Alpine 使用 OpenRC 服务
- Caddy：可选安装，并注入 `github.com/caddy-dns/cloudflare`；Alpine 使用 `caddy-openrc`
- Caddy 端口规则：如果安装 Caddy，脚本会读取同目录 `cdn-ip.txt`，按里面的 IP/CIDR 列表开放 `80/tcp` 和 `443/tcp`

## Alpine

Alpine 最小系统通常没有 Bash。先以 `root` 安装 Bash 和 curl，再执行脚本：

```sh
apk add --no-cache bash curl
curl -fsSL https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/init-vps.sh | bash -s -- --yes --no-caddy
```

如果要安装 Caddy：

```sh
curl -fsSL https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/init-vps.sh | bash -s -- --yes --install-caddy
```

Alpine 路径会自动使用 `apk`、OpenRC、`chronyd`、`wheel` 和 `sysctl -p`。脚本需要 Alpine 的 `community` 仓库来安装 `sudo`，如果没有该仓库会尝试自动启用它；UFW 和 Caddy 也来自这个仓库。脚本仍然使用 `sudo` 作为管理员工具；Alpine 官方更推荐 `doas`，但这里保留原脚本的无密码 sudo 行为。

如果是 diskless/data 模式，用户目录、SSH 配置、UFW 和其他修改还需要按你的存储布局用 `lbu` 持久化；普通磁盘安装则按 `/etc/fstab` 和系统磁盘的持久性处理。

脚本依然要求在真实 VPS/完整 Alpine 系统上运行。不要直接在没有 SSH 服务、启动系统或内核权限的普通 Docker 容器里执行。

## 推荐执行

先在本地检查脚本内容，再传到 VPS 执行：

```bash
sudo bash init-vps.sh
```

非交互执行，并安装 Caddy：

```bash
sudo bash init-vps.sh --yes --install-caddy
```

不安装 Caddy：

```bash
sudo bash init-vps.sh --yes --no-caddy
```

跳过 UFW 或 SSHGuard：

```bash
sudo bash init-vps.sh --yes --no-ufw
sudo bash init-vps.sh --yes --no-sshguard
```

指定公钥来源：

```bash
sudo bash init-vps.sh --github-user telly3e
sudo bash init-vps.sh --pubkey-url https://github.com/telly3e.keys
sudo bash init-vps.sh --pubkey 'ssh-ed25519 AAAA...'
```

指定 Caddy CDN IP 规则文件：

```bash
sudo bash init-vps.sh --install-caddy --cdn-ip-file /root/cdn-ip.txt
```

从 GitHub raw 下载脚本和 CDN IP 列表：

```bash
curl -fsSL https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/init-vps.sh | sudo bash -s -- --install-caddy --cdn-ip-url https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/cdn-ip.txt
```

如果不安装 Caddy，可以直接运行：

```bash
curl -fsSL https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/init-vps.sh | sudo bash
```

管道执行时没有交互输入，脚本会自动使用默认选择并继续执行；默认不安装 Caddy。需要安装 Caddy 时显式加 `--install-caddy`：

```bash
curl -fsSL https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/init-vps.sh | sudo bash -s -- --install-caddy
```

如果不想在命令里写两遍 raw 地址，也可以用 `VPS_INIT_BASE_URL`：

```bash
export VPS_INIT_BASE_URL="https://raw.githubusercontent.com/telly3e/vps-first-initializer/main"
curl -fsSL "$VPS_INIT_BASE_URL/init-vps.sh" | sudo env VPS_INIT_BASE_URL="$VPS_INIT_BASE_URL" bash -s -- --install-caddy
```

脚本内置的默认 `VPS_INIT_BASE_URL` 已经指向本仓库，所以通常也可以简化为：

```bash
curl -fsSL https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/init-vps.sh | sudo bash -s -- --install-caddy
```

## SSH 安全顺序

脚本会先创建用户并写入 `authorized_keys`，确认 key 不为空后才会修改 SSH 配置。修改后会执行 `sshd -t`，通过后才重启 SSH 服务。

执行完成后不要立刻关闭当前 root 会话。先开第二个终端测试：

```bash
ssh -p 22222 nini@YOUR_SERVER_IP
```

确认新连接可用后，再关闭旧的 root 会话。

## Caddy Cloudflare DNS 插件

在 Debian/Ubuntu 上选择安装 Caddy 时，脚本会：

```bash
apt install caddy
caddy add-package github.com/caddy-dns/cloudflare
systemctl restart caddy
```

在 Alpine 上，脚本会从 `community` 仓库安装 `caddy` 和 `caddy-openrc`，然后执行：

```sh
apk add caddy caddy-openrc
caddy add-package github.com/caddy-dns/cloudflare
rc-update add caddy
rc-service caddy restart
```

`caddy add-package` 会替换 Caddy 二进制以加入插件；这是 Caddy 的实验性升级路径，后续 `apk upgrade` 后如果插件消失，需要重新执行插件安装。

随后脚本会配置 UFW。`22222/tcp` 会始终放行；如果安装了 Caddy，则不会直接对全网开放 `80/443`，而是读取 `cdn-ip.txt` 里的纯 IP/CIDR 列表，例如只允许 Cloudflare 和你列出的 CDN 源 IP 访问 `80/tcp`、`443/tcp`。

如果 VPS 上没有 `cdn-ip.txt`，脚本会保守处理：不开放 `80/443`，并提示你把文件放到 `init-vps.sh` 同目录，或者用 `--cdn-ip-file` / `--cdn-ip-url` 指定。

`cdn-ip.txt` 是纯数据文件，不再是 shell 脚本。格式是每行一个 IP 或 CIDR，支持空行和 `#` 注释：

```text
# Cloudflare IPv4
103.21.244.0/22

# CDN origin IPv4
160.16.141.30
```
