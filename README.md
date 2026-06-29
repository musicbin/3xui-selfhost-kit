# 3x-ui Selfhost Kit

自用一键部署项目：安装最新官方 `3x-ui`，默认生成 `VLESS + REALITY` 和 `Shadowsocks 2022` 节点，并把域名证书、Trojan TLS、链式代理、伪装站点、订阅转换 Web UI 都放进一个 `x-ui` 命令行菜单里。

仓库只保存部署脚本、Compose 和配置模板，不保存 3x-ui / Xray / acme.sh / subconverter 的上游代码。安装和更新时实时拉取：

- `ghcr.io/mhsanaei/3x-ui:latest`
- `caddy:2-alpine`
- `tindy2013/subconverter:latest`
- `python:3-alpine`，用于受 token 保护的 3.5.yaml 规则编辑 API
- `https://get.acme.sh`

## 一键安装

默认交互式安装：

```bash
curl -fsSL https://raw.githubusercontent.com/musicbin/3xui-selfhost-kit/main/install.sh \
  | sudo env CONFIG_WIZARD=1 MENU_AFTER_INSTALL=1 ENABLE_SYSTEMD_AUTOSTART=1 bash
```

如果 DNS 已经解析好，可以一条命令直接切到域名 + HTTPS 状态：

```bash
curl -fsSL https://raw.githubusercontent.com/musicbin/3xui-selfhost-kit/main/install.sh \
  | sudo env CONFIG_WIZARD=0 DOMAIN_NAMES=heubhkldhuu.shop,www.heubhkldhuu.shop MENU_AFTER_INSTALL=1 ENABLE_SYSTEMD_AUTOSTART=1 bash
```

多个域名、多个前缀都写进 `DOMAIN_NAMES`，例如：

```bash
DOMAIN_NAMES=example.com,www.example.com,a.example.com,b.example.com
```

脚本会把这些域名写入证书、Caddy HTTPS 站点和 `SERVER_ALIASES`。订阅 Web 刷新时会为每个域名/前缀生成对应的安全协议链接，不为每个域名重复占用端口，避免端口冲突。

只要提供了 `DOMAIN_NAMES`，安装脚本会自动：

- 用第一个域名作为面板、节点和订阅显示地址
- 申请 Let's Encrypt 证书并启用自动续期
- 启用 443 HTTPS 伪装站点
- 将 HTTP 80 自动 308 跳转到 HTTPS
- 将面板和 3X-UI 内置订阅服务改为本机监听，再由 Caddy 通过 HTTPS 随机路径反代

安装时会进入交互向导。直接回车即可使用安全默认值；也可以输入一个或多个域名，例如：

```text
heubhkldhuu.shop,www.heubhkldhuu.shop
```

安装完成会在命令行直接显示：

- 面板公网显示地址、监听 IP、端口和随机路径
- 面板用户名和密码
- SSH 隧道命令
- VLESS REALITY、Shadowsocks、Trojan 等节点链接文件
- 域名、证书、HTTPS/HTTP 模式
- 订阅转换 Web UI 地址
- 开机自启动状态

之后 SSH 登录服务器，直接输入：

```bash
sudo x-ui
```

也可以用：

```bash
sudo 3xui-kit
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh status
sudo ./scripts/manage.sh links
```

## 默认功能

默认自动部署：

- 最新官方 3x-ui Docker 镜像
- 随机面板用户名、密码、API token、根路径
- `VLESS + TCP/Raw + XTLS Vision + REALITY`
- `Shadowsocks 2022`
- 80 端口普通伪装页面
- 订阅转换 Web UI：`/sub/`
- 3X-UI 内置订阅服务的 HTTPS 反代 URI，避免面板导出 `http://:2096` 链接
- 安全协议守护：默认禁用 `vmess/http/mixed/mtproto/tun` 入站，保留 `vless/trojan/shadowsocks/wireguard/hysteria/tunnel`
- `dokodemo-door` 转发预设；在 3X-UI 官方面板中协议名显示为 `tunnel`
- `3.5.yaml` 规则配置 Web 编辑器，使用安装时生成的编辑 token
- Web 一键刷新全部 3X-UI 入站链接，并用本地 `3.5.yaml` 渲染 Clash 订阅
- Docker `restart: unless-stopped`
- systemd 自启动服务：`3xui-kit.service`

默认会开放/提示这些基础端口：

- `22/tcp`
- `80/tcp`
- `443/tcp`
- `8388/tcp,udp`，默认 Shadowsocks 2022 使用

如果启用 Trojan、Hysteria2 或 HTTPS 站点，脚本会继续放行对应端口。

## 面板访问

默认更安全：面板绑定 `127.0.0.1:随机端口`，公网扫不到。安装摘要会显示公网 IP/域名、端口和路径；如果没有启用 HTTPS 域名站点，建议先建 SSH 隧道：

```bash
ssh -L 面板端口:127.0.0.1:面板端口 root@your.server.ip
```

然后浏览器打开：

```text
http://127.0.0.1:面板端口/随机路径/
```

如果你在安装向导选择公网面板，脚本会把监听改成 `0.0.0.0` 并在菜单里直接显示：

```text
http://your.server.ip:面板端口/随机路径/
```

## 域名与 HTTPS

在 `sudo x-ui` 菜单里选择：

```text
10. 管理 Acme 申请域名证书
```

每一个要访问的前缀都必须有 DNS 记录并写进 `DOMAIN_NAMES`，例如 `www.example.com`、`a.example.com`。如果只写 `example.com`，证书不会自动覆盖 `www` 或其他前缀。除非你自行配置 DNS API 申请通配符证书，否则本项目默认使用 HTTP-01，按域名逐个申请证书。

IPv6 也支持，但 VPS 必须真的有公网 IPv6，并且每个域名/前缀都要添加 AAAA 记录。检查命令：

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh network-check
```

如果域名套了 Cloudflare 橙云代理，网页可能能打开，但 VLESS/Trojan/Shadowsocks 这类非 HTTP 代理协议通常会失败。节点域名建议保持 DNS-only。

输入一个或多个域名后，脚本会：

- 用官方 acme.sh 申请 Let's Encrypt 证书
- 写入 3x-ui 容器可读证书路径
- 自动续期
- 自动把 `SERVER_ADDR`、面板显示地址、节点分享地址和订阅地址切到第一个域名
- 可选自动启用 Trojan TLS 节点
- 可选启用 443 HTTPS 伪装站点
- 自动显示域名、IP、证书路径、面板路径和订阅转换入口
- 自动刷新 Caddy 反代，让 3X-UI 面板导出的订阅链接变成 `https://域名/随机路径/<subId>`

安全策略：

- 如果启用 443 HTTPS 伪装站点，HTTP 80 只做 308 跳转到 HTTPS。
- 如果只申请证书、不启用 HTTPS 站点，证书成功后 HTTP 80 默认返回 403，不继续提供明文页面。
- 如果 443 被 HTTPS 站点占用，脚本会把自动生成的 VLESS REALITY 从 `443/tcp` 移到 `8443/tcp`，并重建脚本生成的 `auto-*` 入站。
- 3X-UI 内置订阅端口默认绑定 `127.0.0.1:2096`，公网不能直接访问；公网只走 HTTPS 反代随机路径。

## 订阅转换

安装脚本默认启用本机 subconverter，并生成 Web UI：

```text
http://your.server/sub/
```

启用 HTTPS 站点后变成：

```text
https://your.domain/sub/
```

Web UI 会默认读取本机 token 化订阅：

```text
/subscriptions/<token>.txt
```

同时会生成给 subconverter 使用的 Base64 订阅：

```text
/subscriptions/<token>.b64
```

支持转换为 Clash、sing-box、V2Ray、Surge、Quantumult X 等格式，默认规则配置使用本机内置的 `3.5.yaml`：

```text
https://your.domain/sub/config/3.5.yaml
```

仓库内置的 `site/sub/config/3.5.yaml` 来自你的默认分流模板，但已经去掉真实服务器、UUID、密码等敏感值。节点名称保持原样，例如 `测试3ip`、`测试4域名`、`测试5V6`、`测试6域名`、`测试10域名`，这样下面的分流组引用不会断。你可以在 `/sub/` 页面把“规则配置”改成其他 URL，并点“保存为默认”保存在浏览器里。

如果要直接修改服务器上的规则，在 `/sub/` 页面下方的 `3.5.yaml 规则` 区域输入安装摘要里显示的 `Rules editor token`，然后读取、编辑、保存。保存后转换链接仍然使用：

```text
https://your.domain/sub/config/3.5.yaml
```

也就是你的订阅转换会继续按这份 `3.5.yaml` 的分流规则生成配置。

最推荐给 Clash 使用的是这个渲染后的订阅链接，它会读取当前节点，再把节点参数填入 `3.5.yaml` 的 `proxies:`，并保留原来的节点名称和下面所有分流规则：

```text
https://your.domain/subconfig-api/render/clash?token=<token>
```

重新生成订阅页：

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh subscription
```

## 协议和链式代理

重新套用默认节点：

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh apply-presets
```

启用 Trojan TLS：

```bash
sudo ENABLE_TROJAN=1 TLS_CERT_FILE=/root/cert/domains/fullchain.pem TLS_KEY_FILE=/root/cert/domains/privkey.pem ./scripts/apply-presets.sh
```

添加 SOCKS 链式出口：

```bash
sudo CHAIN_ENABLED=1 CHAIN_MODE=all CHAIN_TYPE=socks CHAIN_ADDRESS=1.2.3.4 CHAIN_PORT=1080 ./scripts/apply-presets.sh
```

添加 Trojan 链式出口：

```bash
sudo CHAIN_ENABLED=1 CHAIN_MODE=all CHAIN_TYPE=trojan CHAIN_ADDRESS=upstream.example.com CHAIN_PORT=443 CHAIN_PASS=trojan-password CHAIN_SERVER_NAME=upstream.example.com ./scripts/apply-presets.sh
```

`CHAIN_MODE=all` 会把流量路由到链式出口；`CHAIN_MODE=manual` 只添加出口，不自动改默认路由。

添加 dokodemo-door 转发入站：

```bash
sudo ENABLE_DOKODEMO=1 \
  DOKODEMO_LISTEN=127.0.0.1 \
  DOKODEMO_PORT=18080 \
  DOKODEMO_TARGET_ADDRESS=127.0.0.1 \
  DOKODEMO_TARGET_PORT=80 \
  DOKODEMO_NETWORK=tcp \
  ./scripts/apply-presets.sh
```

说明：3X-UI 官方面板里这个协议显示为 `tunnel`，它对应 Xray 的 dokodemo-door 风格转发器。为了安全，默认监听 `127.0.0.1`；如果确实要公网转发，再把 `DOKODEMO_LISTEN` 改成 `0.0.0.0` 并确认 VPS 防火墙只开放必要端口。

禁用不安全入站协议：

```bash
sudo ./scripts/manage.sh protocol-guard
```

默认允许列表是 `vless,trojan,shadowsocks,wireguard,hysteria,tunnel`。默认动作是禁用，不删除；如果要删除不安全入站：

```bash
sudo PROTOCOL_GUARD_ACTION=delete ./scripts/protocol-guard.sh
```

## 更新

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh update
```

这会先备份本地数据库和 `.env`，然后在后台拉取最新官方 3x-ui 镜像，并自动运行：

- 面板端口/路径/监听 IP 恢复
- 域名 HTTPS/Caddy 恢复
- VLESS/Trojan/Shadowsocks/dokodemo 预设幂等检查
- 不安全协议守护
- `/sub/` 订阅和 `3.5.yaml` 渲染刷新
- 3X-UI 内置订阅 HTTPS URI 修复

如果官方版本升级导致 API 暂时不兼容，脚本不会覆盖你的数据库备份；查看日志：

```bash
tail -f /opt/3xui-selfhost-kit/runtime/safe-update.log
sudo ./scripts/manage.sh reconcile
```

严格来说，任何第三方官方项目的未来破坏性更新都无法“数学保证永不失效”，但本项目把所有自定义配置放在 `.env`、脚本、Caddy、订阅 API 里，更新后会自动重放配置，并保留更新前备份用于回滚。

## 全部入站订阅

Web 入口：

```text
https://your.domain/sub/
```

在页面输入“规则编辑 Token”，点击“刷新全部入站链接”，会从 3X-UI 读取所有可订阅入站，并使用 `SERVER_ALIASES` 为多个域名/前缀生成链接。`dokodemo-door/tunnel` 是转发入站，没有客户端订阅 URL。

命令行刷新：

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh refresh-links
```

## 常用命令

```bash
sudo x-ui
sudo 3xui-kit
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh status
sudo ./scripts/manage.sh links
sudo ./scripts/manage.sh logs
sudo ./scripts/manage.sh backup
sudo ./scripts/manage.sh autostart
sudo ./scripts/manage.sh domain
sudo ./scripts/manage.sh subscription
sudo ./scripts/manage.sh xui-subscription
sudo ./scripts/manage.sh refresh-links
sudo ./scripts/manage.sh reconcile
sudo ./scripts/manage.sh network-check
sudo ./scripts/manage.sh mask-site
sudo ./scripts/manage.sh protocol-guard
```

请只在你有合法授权的服务器和网络环境里使用。
