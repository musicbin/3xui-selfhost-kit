# Security Notes

This repository is a deployment wrapper for personal 3x-ui use. It does not vendor 3x-ui, Xray, or Caddy source code. The deployment pulls official upstream Docker images at install and update time.

Defaults:

- The 3x-ui panel is bound to `127.0.0.1`.
- Use an SSH tunnel to open the panel.
- The panel gets a random username, password, API token, and base path.
- The main public inbound is `VLESS + TCP + XTLS Vision + REALITY`.
- Trojan and Hysteria2 presets are optional because they need proper TLS certificates to be a good security choice.

Recommended firewall surface:

- Keep `22/tcp` restricted to your own IP if your provider firewall supports it.
- Open `443/tcp` for VLESS REALITY.
- Open optional protocol ports only when you actually enable them.
- Do not expose `2053/tcp` publicly unless you add a trusted reverse proxy or VPN access layer.

Update regularly:

```bash
cd /opt/3xui-selfhost-kit
./scripts/manage.sh update
```

