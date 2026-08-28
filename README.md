# VPS First Initializer

适用于 Debian、Ubuntu、Alpine VPS 的首次初始化。请以 `root` 执行。脚本默认创建 `nini` 用户、写入 GitHub 公钥、将 SSH 改到 `22222`，并关闭 root 和密码 SSH 登录；同时默认启用 Swap、UFW、SSHGuard。

## 一键执行

Debian/Ubuntu（默认不安装 Caddy）：

```sh
curl -fsSL https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/init-vps.sh | bash -s -- --yes --no-caddy
```

需要安装 Caddy：

```sh
curl -fsSL https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/init-vps.sh | bash -s -- --yes --install-caddy
```

Alpine：

```sh
apk add --no-cache bash curl && curl -fsSL https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/init-vps.sh | bash -s -- --yes --no-caddy
```

执行完成后保留当前 SSH 会话，另开终端测试新连接：

```sh
ssh -p 22222 nini@YOUR_SERVER_IP
```

## 参数

参数放在命令最后，例如：

```sh
curl -fsSL https://raw.githubusercontent.com/telly3e/vps-first-initializer/main/init-vps.sh | bash -s -- --yes --no-caddy --user alice --ssh-port 22022 --github-user YOUR_GITHUB_USER
```

常用参数：

| 参数 | 示例 | 说明 |
| --- | --- | --- |
| `--user USER` | `--user alice` | 创建的 Linux 用户，默认 `nini` |
| `--ssh-port PORT` | `--ssh-port 22022` | SSH 新端口，范围 `1-65535` |
| `--github-user USER` | `--github-user telly3e` | 从 `https://github.com/USER.keys` 获取公钥 |
| `--pubkey-url URL` | `--pubkey-url https://example.com/keys` | 从自定义地址获取公钥 |
| `--pubkey 'KEY'` | `--pubkey 'ssh-ed25519 AAAA...'` | 直接填写完整 SSH 公钥，可重复填写 |
| `--swap-size SIZE` | `--swap-size 4G` | Swap 大小，默认 `2G` |
| `--no-swap` |  | 不创建 Swap |
| `--no-ufw` |  | 不安装或配置 UFW |
| `--no-sshguard` |  | 不安装或启用 SSHGuard |
| `--install-caddy` |  | 安装 Caddy 和 Cloudflare DNS 插件 |
| `--no-caddy` |  | 不安装 Caddy |
| `--cdn-ip-file FILE` | `--cdn-ip-file /root/cdn-ip.txt` | Caddy 使用本地 CDN IP/CIDR 列表 |
| `--cdn-ip-url URL` | `--cdn-ip-url https://example.com/cdn-ips.txt` | Caddy 下载远程 CDN IP/CIDR 列表 |
| `--yes` |  | 非交互执行 |

`--pubkey-url`、`--pubkey` 和 `--github-user` 选择一种公钥来源即可。`--cdn-ip-file` 和 `--cdn-ip-url` 也只能二选一；列表按每行一个 IP 或 CIDR 填写，使用 Caddy 时才需要设置。

如果使用 `--install-caddy` 但不指定 CDN 列表，脚本会自动获取 Dooki 和 Cloudflare 官方网段。
