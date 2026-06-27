# 3x-ui Selfhost Kit

自用的一键部署仓库：默认部署 `3X-UI + VLESS REALITY`，并保留 `Hysteria2`、`Trojan TLS`、`Shadowsocks 2022`、链式出口的自动化入口。

仓库只保存部署脚本、Compose 和配置模板，不保存 3x-ui / Xray / Caddy 的上游代码。安装和更新时会实时拉取官方镜像：

- `ghcr.io/mhsanaei/3x-ui:latest`
- `caddy:2-alpine`，仅当你启用静态伪装站点时使用

## 一条命令部署

```bash
curl -fsSL https://raw.githubusercontent.com/musicbin/3xui-selfhost-kit/main/install.sh | sudo bash
```

默认会进入命令行配置向导，让你选择面板是否公网开放、面板端口、随机路径、REALITY 目标、是否启用 Hysteria2/Trojan/Shadowsocks、是否配置链式代理。向导通过 `/dev/tty` 读取输入，所以 `curl | sudo bash` 也能正常选择。

如果想完全无交互，使用安全默认值：

```bash
curl -fsSL https://raw.githubusercontent.com/musicbin/3xui-selfhost-kit/main/install.sh | sudo env CONFIG_WIZARD=0 bash
```

带域名或指定地址：

```bash
curl -fsSL https://raw.githubusercontent.com/musicbin/3xui-selfhost-kit/main/install.sh \
  | sudo env SERVER_ADDR=your.domain.com REALITY_TARGET=www.cloudflare.com:443 REALITY_SERVER_NAMES=www.cloudflare.com,cloudflare.com bash
```

安装完成后查看：

```bash
sudo cat /opt/3xui-selfhost-kit/runtime/install-summary.txt
sudo cat /opt/3xui-selfhost-kit/runtime/client-links.txt
```

安装脚本结束时会直接在命令行打印这些信息：

- 可视化面板监听地址、随机路径、用户名、密码
- SSH 隧道打开面板的命令
- 浏览器访问地址
- VLESS REALITY 默认配置方式和端口
- 客户端链接文件位置
- Hysteria2、Trojan、Shadowsocks、链式代理的启用命令
- 类似 x-ui-yg 的终端菜单面板，并创建快捷命令 `3xui-kit`
- 开机自启动状态：Docker `restart: unless-stopped` + `3xui-kit.service`

之后想重新显示这些信息：

```bash
sudo 3xui-kit
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh menu
sudo ./scripts/manage.sh status
sudo ./scripts/manage.sh links
```

## 开机自启动

安装脚本会自动设置自启动：

- Docker 服务会执行 `systemctl enable --now docker`
- 3x-ui 容器使用 Compose 的 `restart: unless-stopped`
- 额外创建并启用 systemd 服务 `3xui-kit.service`

查看状态：

```bash
systemctl status 3xui-kit.service --no-pager
sudo 3xui-kit
```

如果你只想跳过 systemd 服务创建，安装时加：

```bash
curl -fsSL https://raw.githubusercontent.com/musicbin/3xui-selfhost-kit/main/install.sh \
  | sudo env ENABLE_SYSTEMD_AUTOSTART=0 bash
```

## 打开面板

菜单和安装摘要里的“面板公网地址”会显示你的服务器公网 IP 或域名，例如：

```text
http://your.server.ip:2053/随机路径/
```

默认面板只监听服务器本机 `127.0.0.1:2053`，公网扫不到；这种安全模式下，公网地址用于识别服务器和路径，实际打开需要先建 SSH 隧道：

```bash
ssh -L 2053:127.0.0.1:2053 root@your.server.ip
```

然后浏览器打开隧道地址，形如：

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
sudo cat /opt/3xui-selfhost-kit/runtime/panel-all-links.txt
```

`client-links.txt` 是脚本生成的主线路链接；`panel-all-links.txt` 是 3x-ui 面板自己的 `allLinks` 接口导出的全部协议链接。

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
sudo ./scripts/manage.sh menu
sudo ./scripts/manage.sh logs
sudo ./scripts/manage.sh backup
sudo ./scripts/manage.sh links
sudo ./scripts/manage.sh apply-presets
sudo ./scripts/manage.sh autostart
```

## 端口建议

- `443/tcp`：VLESS REALITY 主线路
- `2053/tcp`：面板端口，默认只绑定本机，不要公网开放
- `8443/udp`：Hysteria2，可选
- `9443/tcp`：Trojan WS TLS，可选
- `8388/tcp,udp`：Shadowsocks 2022，可选

请只在合法授权的网络和用途下使用。
