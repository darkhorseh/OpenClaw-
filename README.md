# OpenClaw-
采用Esxi虚拟机环境裸机部署OpenClaw
# OpenClaw 中文版 Debian 局域网部署与运维手册

## 1. 部署目标

- 服务器 IP: `10.28.100.107`
- 系统: Debian（无图形界面）
- 部署方式: 裸机部署（非 Docker）
- OpenClaw 安装源: `@qingchencloud/openclaw-zh@latest`
- OpenClaw 网关端口: `18789`（默认端口）
- 对外入口: Caddy `443/80`
- 访问范围: 仅局域网
- 服务用户: `openclaw`

## 2. 前置条件

- 已安装 Node.js（建议 `22+`）
- 已有用户 `openclaw`
- 服务器可联网安装 npm 包与 Caddy

检查：

```bash
node -v
npm -v
id openclaw
```

## 3. 安装 OpenClaw 中文版

```bash
sudo npm uninstall -g openclaw || true
sudo npm install -g @qingchencloud/openclaw-zh@latest
openclaw --version
```

首次初始化：

```bash
sudo -u openclaw -H openclaw onboard
```

## 4. systemd 配置（openclaw）

`/etc/systemd/system/openclaw.service`：

```ini
[Unit]
Description=OpenClaw Gateway (ZH)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
Environment=HOME=/home/openclaw
ExecStart=/usr/local/bin/openclaw-gateway-start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`/usr/local/bin/openclaw-gateway-start`：

```bash
#!/usr/bin/env bash
set -euo pipefail
if openclaw gateway run --help >/dev/null 2>&1; then
  exec openclaw gateway run
fi
exec openclaw gateway --port "${OPENCLAW_PORT:-18789}"
```

启用：

```bash
sudo chmod +x /usr/local/bin/openclaw-gateway-start
sudo systemctl daemon-reload
sudo systemctl enable --now openclaw
```

## 5. Caddy 配置（无域名，内网证书）

安装 Caddy：

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo chmod o+r /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

`/etc/caddy/Caddyfile`：

```caddyfile
https://10.28.100.107 {
    tls internal
    reverse_proxy 127.0.0.1:18789
}

http://10.28.100.107 {
    redir https://10.28.100.107{uri} 308
}
```

启用：

```bash
sudo systemctl enable --now caddy
sudo systemctl reload caddy
```

说明：无域名时不能用公网 CA 自动证书，`tls internal` 为正确方案。
根证书路径：

```bash
/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
```

## 6. 防火墙（仅局域网）

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow from 10.28.100.0/24 to any port 80 proto tcp
sudo ufw allow from 10.28.100.0/24 to any port 443 proto tcp
sudo ufw deny 18789/tcp
sudo ufw --force enable
sudo ufw status verbose
```

## 7. 新终端接入授权流程（Pairing）

适用场景：同一局域网新电脑/新浏览器访问时，页面出现 `disconnected (1008): pairing required`。

处理步骤：

1. 在新终端浏览器打开：`https://10.28.100.107`。
2. 在控制台页面点击一次“连接”，触发配对请求。
3. 在服务器执行：

```bash
sudo -u openclaw -H openclaw devices list
```

4. 找到新请求对应的 `requestId`，执行批准：

```bash
sudo -u openclaw -H openclaw devices approve <requestId>
```

5. 新终端刷新页面并再次点击“连接”。

成功判定（日志）：

```bash
sudo journalctl -u openclaw -n 50 --no-pager
```

出现以下关键日志即可：

- `device pairing approved ...`
- `webchat connected ...`

常见误区：

- 已填 `gateway token` 但仍报错：通常是“未批准设备”，不是网络故障。
- 另一台终端能打开网页但显示离线：通常也是“未配对”。

可选安全运维：

```bash
sudo -u openclaw -H openclaw devices list --json
```

定期清理不再使用的设备授权（按需执行）。

## 8. 反代信任配置（推荐）

```bash
sudo -u openclaw -H openclaw config set gateway.trustedProxies '["127.0.0.1","::1"]' --json
sudo systemctl restart openclaw
```

作用：避免 `Proxy headers detected from untrusted address` 告警。

## 9. 验收标准

```bash
sudo systemctl is-enabled openclaw caddy
sudo systemctl is-active openclaw caddy
curl -kI https://10.28.100.107
```

通过条件：

- `enabled enabled`
- `active active`
- `HTTP/2 200`（或跳转后到 `200`）

## 10. 固定脚本（freeze）

脚本：`freeze-openclaw.sh`（仓库根目录）

作用：

- 固定开机自启
- 备份关键文件与数据到 `/var/backups/openclaw-freeze-*`
- 记录版本与服务状态
- 锁定关键包：`caddy`、`nodejs`
- 重启后等待后端就绪并做 HTTPS 健康检查（避免瞬时 502 误报）

执行：

```bash
chmod +x freeze-openclaw.sh
sudo ./freeze-openclaw.sh
```

可选参数：

```bash
sudo SERVER_IP=10.28.100.107 MAX_WAIT=60 ./freeze-openclaw.sh
```

## 11. 回滚脚本（restore）

脚本：`restore-openclaw.sh`（仓库根目录）

作用：

- 回滚前先做当前状态快照 `/var/backups/openclaw-prerestore-*`
- 恢复 `openclaw.service`、`openclaw-gateway-start`、`Caddyfile`
- 恢复 `/home/openclaw/.openclaw` 和 Caddy PKI
- 重启服务并执行健康检查

执行（默认最新备份）：

```bash
chmod +x restore-openclaw.sh
sudo SERVER_IP=10.28.100.107 ./restore-openclaw.sh
```

指定备份目录：

```bash
sudo SERVER_IP=10.28.100.107 ./restore-openclaw.sh /var/backups/openclaw-freeze-YYYY-MM-DD-HHMMSS
```

## 12. 常用排查命令

```bash
sudo systemctl status openclaw caddy --no-pager
sudo journalctl -u openclaw -n 80 --no-pager
sudo journalctl -u caddy -n 80 --no-pager -l
ss -lntp | egrep ':443|:80|:18789'
curl -kI https://10.28.100.107
sudo ufw status verbose
```
