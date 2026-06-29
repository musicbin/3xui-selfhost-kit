#!/usr/bin/env python3
import hmac
import os
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse
import base64
import json
import re


CONFIG_PATH = Path(os.environ.get("SUB_CONFIG_PATH", "/config/3.5.yaml"))
ADMIN_TOKEN = os.environ.get("SUB_CONFIG_ADMIN_TOKEN", "")
SUBSCRIPTION_TOKEN = os.environ.get("SUBSCRIPTION_TOKEN", "")
SUBSCRIPTION_DIR = Path(os.environ.get("SUBSCRIPTION_DIR", "/subscriptions"))
MAX_BYTES = int(os.environ.get("SUB_CONFIG_MAX_BYTES", "2097152"))


class Handler(BaseHTTPRequestHandler):
    server_version = "3xui-subconfig/1.0"

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def send_text(self, status, body, content_type="text/plain; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def token_from_request(self):
        header = self.headers.get("X-Admin-Token", "")
        if header:
            return header
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return ""

    def authorized(self):
        if not ADMIN_TOKEN:
            return False
        return hmac.compare_digest(self.token_from_request(), ADMIN_TOKEN)

    def require_auth(self):
        if self.authorized():
            return True
        self.send_text(401, "Unauthorized.")
        return False

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Allow", "GET, PUT, POST, OPTIONS")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/health":
            self.send_text(200, "ok")
            return
        if path == "/render/clash":
            self.render_clash(parsed)
            return
        if path != "/config":
            self.send_text(404, "Not found.")
            return
        if not self.require_auth():
            return
        if not CONFIG_PATH.exists():
            self.send_text(404, "Config file not found.")
            return
        self.send_text(200, CONFIG_PATH.read_text(encoding="utf-8"), "text/yaml; charset=utf-8")

    def do_POST(self):
        self.do_PUT()

    def do_PUT(self):
        path = urlparse(self.path).path
        if path != "/config":
            self.send_text(404, "Not found.")
            return
        if not self.require_auth():
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_text(400, "Bad Content-Length.")
            return
        if length <= 0 or length > MAX_BYTES:
            self.send_text(413, "Config is empty or too large.")
            return

        raw = self.rfile.read(length)
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            self.send_text(400, "Config must be UTF-8.")
            return

        required = ("proxies:", "proxy-groups:", "rules:")
        missing = [key for key in required if key not in text]
        if missing:
            self.send_text(400, "Config missing required sections: " + ", ".join(missing))
            return

        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(prefix=".3.5.", suffix=".tmp", dir=str(CONFIG_PATH.parent))
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            if not text.endswith("\n"):
                fh.write("\n")
        os.replace(tmp_name, CONFIG_PATH)
        os.chmod(CONFIG_PATH, 0o644)
        self.send_text(200, "Saved.")

    def render_clash(self, parsed):
        params = parse_qs(parsed.query)
        token = params.get("token", [""])[0]
        if not token or not SUBSCRIPTION_TOKEN or not hmac.compare_digest(token, SUBSCRIPTION_TOKEN):
            self.send_text(401, "Unauthorized.")
            return
        if not CONFIG_PATH.exists():
            self.send_text(404, "Config file not found.")
            return
        sub_path = SUBSCRIPTION_DIR / f"{SUBSCRIPTION_TOKEN}.txt"
        if not sub_path.exists():
            self.send_text(404, "Subscription file not found.")
            return
        try:
            config_text = CONFIG_PATH.read_text(encoding="utf-8")
            links = [line.strip() for line in sub_path.read_text(encoding="utf-8").splitlines()]
            links = [line for line in links if re.match(r"^(vless|trojan|ss)://", line)]
            rendered = render_clash_config(config_text, links)
        except Exception as exc:
            self.send_text(500, f"Render failed: {exc}")
            return
        self.send_text(200, rendered, "text/yaml; charset=utf-8")


def q(value):
    return json.dumps(str(value), ensure_ascii=False)


def parse_port(parsed):
    if parsed.port is None:
        return 443
    return parsed.port


def link_name(parsed, fallback):
    if parsed.fragment:
        return unquote(parsed.fragment)
    return fallback


def parse_node(link):
    parsed = urlparse(link)
    scheme = parsed.scheme.lower()
    query = parse_qs(parsed.query)
    name = link_name(parsed, f"{scheme}-{parsed.hostname or 'node'}")
    host = parsed.hostname or ""
    port = parse_port(parsed)

    if scheme == "vless":
        uuid = unquote(parsed.username or "")
        sni = query.get("sni", [""])[0]
        pbk = query.get("pbk", [""])[0]
        sid = query.get("sid", [""])[0]
        fp = query.get("fp", ["chrome"])[0]
        flow = query.get("flow", [""])[0]
        parts = [
            f"name: {q(name)}",
            f"server: {q(host)}",
            f"port: {port}",
            "type: vless",
            f"uuid: {q(uuid)}",
            "tls: true",
            "network: tcp",
            "udp: true",
        ]
        if flow:
            parts.append(f"flow: {q(flow)}")
        if sni:
            parts.append(f"servername: {q(sni)}")
        if fp:
            parts.append(f"client-fingerprint: {q(fp)}")
        if pbk:
            reality = f"public-key: {q(pbk)}"
            if sid:
                reality += f", short-id: {q(sid)}"
            parts.append(f"reality-opts: {{{reality}}}")
        return parts

    if scheme == "trojan":
        password = unquote(parsed.username or "")
        sni = query.get("sni", [host])[0]
        path = query.get("path", ["/"])[0]
        network = query.get("type", query.get("network", ["tcp"]))[0]
        parts = [
            f"name: {q(name)}",
            f"server: {q(host)}",
            f"port: {port}",
            "type: trojan",
            f"password: {q(password)}",
            "tls: true",
            "udp: true",
        ]
        if sni:
            parts.append(f"sni: {q(sni)}")
        if network == "ws":
            parts.append("network: ws")
            parts.append(f"ws-opts: {{path: {q(path)}, headers: {{Host: {q(sni or host)}}}}}")
        return parts

    if scheme == "ss":
        if "@" in parsed.netloc:
            userinfo = unquote(parsed.netloc.rsplit("@", 1)[0])
        else:
            userinfo = unquote(parsed.username or "")
        if ":" in userinfo:
            decoded = userinfo
        else:
            padding = "=" * (-len(userinfo) % 4)
            decoded = base64.urlsafe_b64decode((userinfo + padding).encode()).decode("utf-8")
        method, *password_parts = decoded.split(":")
        password = ":".join(password_parts)
        return [
            f"name: {q(name)}",
            f"server: {q(host)}",
            f"port: {port}",
            "type: ss",
            f"cipher: {q(method)}",
            f"password: {q(password)}",
            "udp: true",
        ]

    return None


def placeholder_names(config_text):
    names = []
    in_proxies = False
    for line in config_text.splitlines():
        if re.match(r"^proxies:\s*$", line):
            in_proxies = True
            continue
        if in_proxies and re.match(r"^[A-Za-z0-9_-][^:]*:\s*", line):
            break
        if in_proxies:
            match = re.search(r"name:\s*([^,}]+)", line)
            if match:
                names.append(match.group(1).strip().strip("\"'"))
    return names


def replace_proxies_block(config_text, proxy_lines):
    lines = config_text.splitlines()
    start = None
    end = None
    for idx, line in enumerate(lines):
        if re.match(r"^proxies:\s*$", line):
            start = idx
            break
    if start is None:
        return "proxies:\n" + "\n".join(proxy_lines) + "\n" + config_text
    end = len(lines)
    for idx in range(start + 1, len(lines)):
        if re.match(r"^[A-Za-z0-9_-][^:]*:\s*", lines[idx]):
            end = idx
            break
    new_lines = lines[:start + 1] + proxy_lines + lines[end:]
    return "\n".join(new_lines) + "\n"


def render_clash_config(config_text, links):
    nodes = []
    for link in links:
        node = parse_node(link)
        if node:
            nodes.append(node)
    if not nodes:
        raise ValueError("No supported nodes were found.")

    names = placeholder_names(config_text)
    proxy_lines = []
    if names:
        for idx, name in enumerate(names):
            node = list(nodes[idx % len(nodes)])
            node[0] = f"name: {q(name)}"
            proxy_lines.append("  - {" + ", ".join(node) + "}")
    else:
        proxy_lines = ["  - {" + ", ".join(node) + "}" for node in nodes]
    return replace_proxies_block(config_text, proxy_lines)


def main():
    host = os.environ.get("SUB_CONFIG_HOST", "0.0.0.0")
    port = int(os.environ.get("SUB_CONFIG_PORT", "27880"))
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
