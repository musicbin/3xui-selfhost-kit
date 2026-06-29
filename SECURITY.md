# Security Notes

This repository is a deployment wrapper for personal 3x-ui use. It does not vendor 3x-ui, Xray, Caddy, acme.sh, or subconverter source code. The deployment pulls upstream images and installers at install/update time.

Defaults:

- The 3x-ui panel is bound to `127.0.0.1`.
- Use an SSH tunnel to open the panel.
- The panel gets a random username, password, API token, and base path.
- The main public inbound is `VLESS + TCP + XTLS Vision + REALITY`.
- Shadowsocks 2022 is enabled by default for convenience.
- Trojan and Hysteria2 presets should use proper TLS certificates.
- Domain certificate setup defaults to HTTP rejection after certificate issuance unless you explicitly enable the HTTPS masquerade site. When the HTTPS site is enabled, HTTP redirects to HTTPS.

Recommended firewall surface:

- Keep `22/tcp` restricted to your own IP if your provider firewall supports it.
- Open `443/tcp` for VLESS REALITY.
- Open optional protocol ports only when you actually enable them.
- Do not expose `2053/tcp` publicly unless you add a trusted reverse proxy or VPN access layer.
- Treat `runtime/install-summary.txt`, `.env`, node links, subscription URLs, and the rules editor token as secrets.
- If you enable the subscription converter, keep the generated tokenized subscription URL private.
- If you enable the `3.5.yaml` Web editor, only use it over HTTPS on untrusted networks.

Update regularly:

```bash
cd /opt/3xui-selfhost-kit
./scripts/manage.sh update
```
