# 3x-ui Selfhost Kit

自用的一键部署仓库：默认部署 `3X-UI + VLESS REALITY`，并保留 `Hysteria2`、`Trojan TLS`、`Shadowsocks 2022`、链式出口的自动化入口。

仓库只保存部署脚本、Compose 和配置模板，不保存 3x-ui / Xray / Caddy 的上游代码。安装和更新时会实时拉取官方镜像：

- `ghcr.io/mhsanaei/3x-ui:latest`
- `caddy:2-alpine`，仅当你启用静态伪装站点时使用

## 一条命令部署

```bash
curl -fsSL https://raw.githubusercontent.com/musicbin/3xui-selfhost-kit/main/install.sh | sudo bash
```

带域名或指定地址：

```bash
curl -fsSL https://raw.githubusercontent.com/musicbin/3xui-selfhost-kit/main/install.sh \
  | sudo SERVER_ADDR=your.domain.com REALITY_TARGET=www.cloudflare.com:443 REALITY_SERVER_NAMES=www.cloudflare.com,cloudflare.com bash
```

安装完成后查看：

```bash
sudo cat /opt/3xui-selfhost-kit/runtime/install-summary.txt
sudo cat /opt/3xui-selfhost-kit/runtime/client-links.txt
```

## 打开面板

默认面板只监听服务器本机 `127.0.0.1:2053`，公网扫不到。用 SSH 隧道打开：

```bash
ssh -L 2053:127.0.0.1:2053 root@your.server.ip
```

然后浏览器打开安装摘要里的地址，形如：

```text
http://127.0.0.1:2053/随机路径/
```

## 默认协议

默认会自动创建：

- `VLESS + TCP/Raw + XTLS Vision + REALITY`
- 端口：`443`
- REALITY target：默认 `www.cloudflare.com:443`
- 面板：随机路径、随机用户名、随机密码、随机 API token

客户端链接在：

```bash
sudo cat /opt/3xui-selfhost-kit/runtime/client-links.txt
```

## 可选协议

Hysteria2、Trojan、Shadowsocks 默认不启用。原因很简单：Trojan/Hysteria2 需要可信 TLS 证书才算稳妥；没有证书时脚本不会假装它们比 REALITY 更安全。

启用 Hysteria2，使用真实证书：

```bash
cd /opt/3xui-selfhost-kit
sudo TLS_CERT_FILE=/root/cert/fullchain.pem TLS_KEY_FILE=/root/cert/privkey.pem ENABLE_HYSTERIA=1 ./scripts/apply-presets.sh
```

启用 Trojan WS TLS，使用真实证书：

```bash
cd /opt/3xui-selfhost-kit
sudo TLS_CERT_FILE=/root/cert/fullchain.pem TLS_KEY_FILE=/root/cert/privkey.pem ENABLE_TROJAN=1 ./scripts/apply-presets.sh
```

启用 Shadowsocks 2022：

```bash
cd /opt/3xui-selfhost-kit
sudo ENABLE_SHADOWSOCKS=1 ./scripts/apply-presets.sh
```

## 链式代理

把 3x-ui 的 Xray 出口接到上游 SOCKS/HTTP 代理：

```bash
cd /opt/3xui-selfhost-kit
sudo CHAIN_ENABLED=1 CHAIN_MODE=all CHAIN_TYPE=socks CHAIN_ADDRESS=1.2.3.4 CHAIN_PORT=1080 ./scripts/apply-presets.sh
```

带账号密码：

```bash
sudo CHAIN_ENABLED=1 CHAIN_MODE=all CHAIN_TYPE=socks CHAIN_ADDRESS=1.2.3.4 CHAIN_PORT=1080 CHAIN_USER=user CHAIN_PASS=pass ./scripts/apply-presets.sh
```

`CHAIN_MODE=all` 会把默认流量路由到链式出口。只想先把出口加进面板、不改变路由，就用 `CHAIN_MODE=manual`。

## 伪装站点

REALITY 的主要伪装是握手目标站点，不需要本机 443 再跑一个假网站。仓库仍带了一个普通静态页，可用于 80 端口：

```bash
cd /opt/3xui-selfhost-kit
sudo docker compose --profile site up -d caddy-site
```

替换 `site/index.html` 即可变成你的正常页面。

## 更新

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh update
```

这会先备份本地数据库，再执行：

```bash
docker compose pull 3xui
docker compose up -d 3xui
```

## 常用命令

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh status
sudo ./scripts/manage.sh logs
sudo ./scripts/manage.sh backup
sudo ./scripts/manage.sh links
sudo ./scripts/manage.sh apply-presets
```

## 端口建议

- `443/tcp`：VLESS REALITY 主线路
- `2053/tcp`：面板端口，默认只绑定本机，不要公网开放
- `8443/udp`：Hysteria2，可选
- `9443/tcp`：Trojan WS TLS，可选
- `8388/tcp,udp`：Shadowsocks 2022，可选

请只在合法授权的网络和用途下使用。

