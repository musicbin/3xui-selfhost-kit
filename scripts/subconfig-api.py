#!/usr/bin/env python3
import hmac
import os
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


CONFIG_PATH = Path(os.environ.get("SUB_CONFIG_PATH", "/config/3.5.yaml"))
ADMIN_TOKEN = os.environ.get("SUB_CONFIG_ADMIN_TOKEN", "")
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
        path = urlparse(self.path).path
        if path == "/health":
            self.send_text(200, "ok")
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


def main():
    host = os.environ.get("SUB_CONFIG_HOST", "0.0.0.0")
    port = int(os.environ.get("SUB_CONFIG_PORT", "27880"))
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
