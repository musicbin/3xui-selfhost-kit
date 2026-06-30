#!/usr/bin/env python3
import hmac
import os
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, parse_qsl, quote, urlencode, unquote, urlparse, urlunparse
from urllib.request import Request, urlopen
import base64
import json
import re


CONFIG_PATH = Path(os.environ.get("SUB_CONFIG_PATH", "/config/3.5.yaml"))
ADMIN_TOKEN = os.environ.get("SUB_CONFIG_ADMIN_TOKEN", "")
SUBSCRIPTION_TOKEN = os.environ.get("SUBSCRIPTION_TOKEN", "")
SUBSCRIPTION_DIR = Path(os.environ.get("SUBSCRIPTION_DIR", "/subscriptions"))
MAX_BYTES = int(os.environ.get("SUB_CONFIG_MAX_BYTES", "2097152"))
XUI_API_BASE = os.environ.get("XUI_API_BASE", "").rstrip("/")
XUI_API_TOKEN = os.environ.get("XUI_API_TOKEN", "")
SERVER_ALIASES = os.environ.get("SERVER_ALIASES", "")
EXPAND_ALIASES = os.environ.get("SUBSCRIPTION_EXPAND_ALIASES", "1") == "1"
ALL_NODES_SUB_ID = os.environ.get("ALL_NODES_SUB_ID", "")
DOMAIN_NODE_MODE = os.environ.get("DOMAIN_NODE_MODE", "1") in ("1", "true", "TRUE", "yes", "YES", "on", "ON")


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

    def send_json(self, status, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
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
        if path == "/forwards":
            self.get_forwards()
            return
        if path == "/render/clash":
            self.render_clash(parsed)
            return
        if path == "/links":
            self.get_links()
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
        path = urlparse(self.path).path
        if path == "/refresh-links":
            self.refresh_links()
            return
        if path == "/forwards":
            self.save_forward()
            return
        if path == "/forwards/delete":
            self.delete_forward()
            return
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

    def get_links(self):
        if not self.require_auth():
            return
        links = read_subscription_links()
        self.send_json(200, {"success": True, "links": links, "count": len(links)})

    def get_forwards(self):
        if not self.require_auth():
            return
        try:
            forwards = list_forwards()
        except Exception as exc:
            self.send_json(500, {"success": False, "error": str(exc)})
            return
        self.send_json(200, {"success": True, "forwards": forwards, "count": len(forwards)})

    def save_forward(self):
        if not self.require_auth():
            return
        try:
            payload = self.read_json_body()
            forward = save_forward(payload)
        except Exception as exc:
            self.send_json(400, {"success": False, "error": str(exc)})
            return
        self.send_json(200, {"success": True, "forward": forward})

    def delete_forward(self):
        if not self.require_auth():
            return
        try:
            payload = self.read_json_body()
            inbound_id = int(payload.get("id", 0))
            if inbound_id <= 0:
                raise ValueError("id is required.")
            data = xui_request_json(f"/panel/api/inbounds/del/{inbound_id}", method="POST", form={})
            restart_xray_service()
        except Exception as exc:
            self.send_json(400, {"success": False, "error": str(exc)})
            return
        self.send_json(200, {"success": True, "response": data})

    def read_json_body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("Bad Content-Length.") from exc
        if length <= 0 or length > 65536:
            raise ValueError("Request body is empty or too large.")
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError("Request body must be JSON.") from exc

    def refresh_links(self):
        if not self.require_auth():
            return
        try:
            links = refresh_subscription_links()
        except Exception as exc:
            self.send_json(500, {"success": False, "error": str(exc)})
            return
        self.send_json(200, {"success": True, "count": len(links), "links": links})

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


def subscription_txt_path():
    return SUBSCRIPTION_DIR / f"{SUBSCRIPTION_TOKEN}.txt"


def subscription_b64_path():
    return SUBSCRIPTION_DIR / f"{SUBSCRIPTION_TOKEN}.b64"


def read_subscription_links():
    path = subscription_txt_path()
    if not path.exists():
        return []
    links = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if re.match(r"^(vless|vmess|trojan|ss|hysteria2)://", line):
            links.append(line)
    return links


def xui_json(path):
    return xui_request_json(path)


def xui_request_json(path, method="GET", data=None, form=None):
    if not XUI_API_BASE or not XUI_API_TOKEN:
        raise RuntimeError("XUI_API_BASE or XUI_API_TOKEN is not configured.")
    body = None
    headers = {"Authorization": "Bearer " + XUI_API_TOKEN, "Accept": "application/json"}
    if data is not None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    elif form is not None:
        body = urlencode(form).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = Request(
        XUI_API_BASE + path,
        data=body,
        headers=headers,
        method=method,
    )
    try:
        with urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"3X-UI API {path} failed: HTTP {exc.code} {body}") from exc
    except URLError as exc:
        raise RuntimeError(f"3X-UI API {path} failed: {exc}") from exc


def validate_port(value, label):
    try:
        port = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be a number.") from exc
    if port < 1 or port > 65535:
        raise ValueError(f"{label} must be between 1 and 65535.")
    return port


def validate_text(value, label, default=""):
    value = str(value if value is not None else default).strip()
    if not value:
        raise ValueError(f"{label} is required.")
    if "\n" in value or "\r" in value:
        raise ValueError(f"{label} cannot contain newlines.")
    return value


def validate_network(value):
    value = str(value or "tcp").strip().lower()
    if value not in ("tcp", "udp", "tcp,udp"):
        raise ValueError("network must be tcp, udp, or tcp,udp.")
    return value


def truthy_value(value):
    return str(value).strip().lower() in ("1", "true", "yes", "y", "on")


def forward_payload(raw):
    listen_port = validate_port(raw.get("listenPort") or raw.get("port"), "listenPort")
    target_address = validate_text(raw.get("targetAddress") or raw.get("targetHost"), "targetAddress")
    target_port = validate_port(raw.get("targetPort"), "targetPort")
    network = validate_network(raw.get("network"))
    listen = validate_text(raw.get("listen"), "listen", "0.0.0.0")
    remark = str(raw.get("remark") or f"auto-dokodemo-door-{listen_port}").strip()
    if not remark:
        remark = f"auto-dokodemo-door-{listen_port}"
    tproxy = str(raw.get("tproxy") or "off").strip()
    follow = truthy_value(raw.get("followRedirect", False))
    payload = {
        "enable": True,
        "remark": remark,
        "listen": listen,
        "port": listen_port,
        "shareAddr": "",
        "shareAddrStrategy": "listen",
        "protocol": "tunnel",
        "expiryTime": 0,
        "total": 0,
        "trafficReset": "never",
        "settings": {
            "rewriteAddress": target_address,
            "rewritePort": target_port,
            "allowedNetwork": network,
            "followRedirect": follow,
            "portMap": {},
        },
        "streamSettings": {"security": "none"},
        "sniffing": {"enabled": False},
    }
    if tproxy and tproxy != "off":
        payload["streamSettings"]["sockopt"] = {"tproxy": tproxy}
    return payload


def inbound_to_forward(inbound):
    if inbound.get("protocol") != "tunnel":
        return None
    settings = parse_settings(inbound.get("settings"))
    stream_settings = parse_settings(inbound.get("streamSettings"))
    target_address = settings.get("rewriteAddress") or settings.get("address") or ""
    target_port = settings.get("rewritePort") or settings.get("port") or 0
    network = settings.get("allowedNetwork") or "tcp"
    return {
        "id": inbound.get("id"),
        "enable": inbound.get("enable", True),
        "remark": inbound.get("remark", ""),
        "listen": inbound.get("listen") or "",
        "listenPort": inbound.get("port") or 0,
        "targetAddress": target_address,
        "targetPort": target_port,
        "network": network,
        "followRedirect": bool(settings.get("followRedirect", False)),
        "tproxy": (stream_settings.get("sockopt") or {}).get("tproxy", "off"),
    }


def list_forwards():
    data = xui_json("/panel/api/inbounds/list")
    forwards = []
    for inbound in data.get("obj", []) or []:
        forward = inbound_to_forward(inbound)
        if forward:
            forwards.append(forward)
    return forwards


def save_forward(raw):
    payload = forward_payload(raw)
    inbounds = xui_json("/panel/api/inbounds/list").get("obj", []) or []
    existing_id = None
    for inbound in inbounds:
        if inbound.get("protocol") == "tunnel" and int(inbound.get("port") or 0) == payload["port"]:
            existing_id = inbound.get("id")
            break
    if existing_id:
        payload["id"] = existing_id
        data = xui_request_json(f"/panel/api/inbounds/update/{existing_id}", method="POST", data=payload)
    else:
        data = xui_request_json("/panel/api/inbounds/add", method="POST", data=payload)
    if not data.get("success", False):
        raise RuntimeError(data.get("msg") or "3X-UI did not accept the forward.")
    route_warning = ""
    try:
        ensure_forward_direct_route(payload["port"], payload["settings"]["allowedNetwork"])
    except Exception as exc:
        route_warning = str(exc)
    restart_xray_service()
    forward = inbound_to_forward(payload) or {}
    forward["id"] = existing_id
    forward["routeWarning"] = route_warning
    return forward


def ensure_forward_direct_route(port, network):
    tag = f"in-{port}-{network}"
    data = xui_request_json("/panel/api/xray/", method="POST", form={})
    obj = data.get("obj", {})
    if isinstance(obj, str):
        obj = json.loads(obj)
    template = obj.get("xraySetting", {})
    if isinstance(template, str):
        template = json.loads(template)
    routing = template.setdefault("routing", {})
    rules = routing.get("rules") or []
    filtered = []
    for rule in rules:
        inbound_tags = rule.get("inboundTag") or []
        if isinstance(inbound_tags, str):
            inbound_tags = [inbound_tags]
        if tag in inbound_tags:
            continue
        filtered.append(rule)
    routing["rules"] = [{"type": "field", "inboundTag": [tag], "outboundTag": "direct"}] + filtered
    xui_request_json(
        "/panel/api/xray/update",
        method="POST",
        form={
            "xraySetting": json.dumps(template, ensure_ascii=False),
            "outboundTestUrl": "https://www.google.com/generate_204",
        },
    )


def restart_xray_service():
    try:
        xui_request_json("/panel/api/server/restartXrayService", method="POST", form={})
    except Exception:
        pass


def fetch_xui_links():
    links = []
    if ALL_NODES_SUB_ID:
        try:
            links = fetch_xui_links_for_sub_id(ALL_NODES_SUB_ID)
        except Exception:
            links = []
        if links:
            return unique_links(links)

    try:
        data = xui_json("/panel/api/inbounds/allLinks")
        if data.get("success") and isinstance(data.get("obj"), list):
            links.extend(str(v) for v in data["obj"] if isinstance(v, str))
    except Exception:
        links = []
    if links:
        return unique_links(links)

    inbounds = xui_json("/panel/api/inbounds/list")
    emails = []
    for inbound in inbounds.get("obj", []) or []:
        settings = inbound.get("settings") or {}
        for client in settings.get("clients") or []:
            email = client.get("email")
            if email and email not in emails:
                emails.append(email)
    for email in emails:
        data = xui_json("/panel/api/clients/links/" + quote(email, safe=""))
        if data.get("success") and isinstance(data.get("obj"), list):
            links.extend(str(v) for v in data["obj"] if isinstance(v, str))
    return unique_links(links)


def parse_settings(value):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return {}
    if isinstance(value, dict):
        return value
    return {}


def fetch_xui_links_for_sub_id(sub_id):
    links = []
    inbounds = xui_json("/panel/api/inbounds/list")
    emails = []
    for inbound in inbounds.get("obj", []) or []:
        settings = parse_settings(inbound.get("settings"))
        for client in settings.get("clients") or []:
            if not isinstance(client, dict):
                continue
            if client.get("subId") != sub_id:
                continue
            email = client.get("email")
            if email and email not in emails:
                emails.append(email)
    for email in emails:
        data = xui_json("/panel/api/clients/links/" + quote(email, safe=""))
        if data.get("success") and isinstance(data.get("obj"), list):
            links.extend(str(v) for v in data["obj"] if isinstance(v, str))
    return unique_links(links)


def aliases():
    values = []
    for raw in re.split(r"[,，;；\s]+", SERVER_ALIASES or ""):
        raw = raw.strip()
        if raw and raw not in values:
            values.append(raw)
    return values


def split_netloc(netloc):
    userinfo = ""
    hostport = netloc
    if "@" in netloc:
        userinfo, hostport = netloc.rsplit("@", 1)
    if hostport.startswith("["):
        end = hostport.find("]")
        host = hostport[1:end]
        port = hostport[end + 2:] if end >= 0 and hostport[end + 1:end + 2] == ":" else ""
    else:
        if ":" in hostport:
            host, port = hostport.rsplit(":", 1)
        else:
            host, port = hostport, ""
    return userinfo, host, port


def format_host(host):
    if ":" in host and not (host.startswith("[") and host.endswith("]")):
        return "[" + host + "]"
    return host


def replace_link_host(link, host):
    parsed = urlparse(link)
    if not parsed.scheme or not parsed.netloc:
      return link
    userinfo, _, port = split_netloc(parsed.netloc)
    netloc = ""
    if userinfo:
        netloc += userinfo + "@"
    netloc += format_host(host)
    if port:
        netloc += ":" + port
    fragment = unquote(parsed.fragment or "")
    suffix = "@" + host
    if fragment and not fragment.endswith(suffix):
        fragment += suffix
    elif not fragment:
        fragment = host
    query = parsed.query
    if parsed.scheme.lower() == "trojan":
        query_items = []
        for key, value in parse_qsl(parsed.query, keep_blank_values=True):
            if key in ("sni", "host"):
                value = host
            query_items.append((key, value))
        query = urlencode(query_items)
    return urlunparse((parsed.scheme, netloc, parsed.path, parsed.params, query, quote(fragment, safe="")))


def unique_links(links):
    out = []
    seen = set()
    for link in links:
        if link and link not in seen:
            seen.add(link)
            out.append(link)
    return out


def expand_links_for_aliases(links):
    host_aliases = aliases()
    if not EXPAND_ALIASES or not host_aliases:
        return unique_links(links)
    expanded = []
    for link in links:
        for host in host_aliases:
            expanded.append(replace_link_host(link, host))
    return unique_links(expanded)


def align_links_to_aliases(links):
    host_aliases = aliases()
    if not DOMAIN_NODE_MODE or not host_aliases or len(links) != len(host_aliases):
        return None
    return unique_links(replace_link_host(link, host_aliases[idx]) for idx, link in enumerate(links))


def write_subscription_links(links):
    SUBSCRIPTION_DIR.mkdir(parents=True, exist_ok=True)
    text = "\n".join(links) + ("\n" if links else "")
    subscription_txt_path().write_text(text, encoding="utf-8")
    subscription_b64_path().write_text(
        base64.b64encode(text.encode("utf-8")).decode("ascii") + "\n",
        encoding="utf-8",
    )


def refresh_subscription_links():
    links = fetch_xui_links()
    links = align_links_to_aliases(links) or expand_links_for_aliases(links)
    write_subscription_links(links)
    return links


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


def link_alias(link):
    parsed = urlparse(link)
    fragment = unquote(parsed.fragment or "")
    if "@" in fragment:
        alias = fragment.rsplit("@", 1)[1].strip()
        if alias:
            return alias
    return parsed.hostname or ""


def unique_name(name, used):
    base = str(name).strip() or "node"
    candidate = base
    counter = 2
    while candidate in used:
        candidate = f"{base}-{counter}"
        counter += 1
    used.add(candidate)
    return candidate


def rendered_node_names(links, names):
    rendered = []
    used = set()
    target_count = max(len(links), len(names)) if names else len(links)
    for idx in range(target_count):
        link = links[idx % len(links)]
        if names:
            base = names[idx % len(names)]
            if idx < len(names):
                candidate = base
            else:
                alias = link_alias(link)
                candidate = f"{base}@{alias}" if alias else f"{base}-{idx + 1}"
        else:
            parsed = urlparse(link)
            candidate = link_name(parsed, f"{parsed.scheme or 'node'}-{idx + 1}")
        rendered.append(unique_name(candidate, used))
    return rendered


def proxy_group_expansions(base_names, rendered_names):
    expansions = {name: [] for name in base_names}
    if not base_names:
        return expansions
    for idx, name in enumerate(rendered_names):
        base = base_names[idx % len(base_names)]
        expansions.setdefault(base, []).append(name)
    return expansions


def strip_yaml_scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def expand_proxy_group_references(config_text, expansions):
    if not expansions:
        return config_text

    out = []
    in_groups = False
    in_group = False
    group_seen = set()

    for line in config_text.splitlines():
        if re.match(r"^proxy-groups:\s*$", line):
            in_groups = True
            in_group = False
            group_seen = set()
            out.append(line)
            continue

        if in_groups and re.match(r"^[A-Za-z0-9_-][^:]*:\s*", line):
            in_groups = False
            in_group = False
            group_seen = set()

        if in_groups and re.match(r"^\s{2}-\s+name:\s*", line):
            in_group = True
            group_seen = set()
            out.append(line)
            continue

        if in_groups and in_group:
            match = re.match(r"^(\s+-\s+)(.+?)\s*$", line)
            if match:
                prefix, value = match.groups()
                key = strip_yaml_scalar(value)
                if key in expansions:
                    for expanded in expansions[key]:
                        if expanded in group_seen:
                            continue
                        group_seen.add(expanded)
                        out.append(prefix + expanded)
                    continue

        out.append(line)

    return "\n".join(out) + "\n"


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
    parsed_links = []
    for link in links:
        node = parse_node(link)
        if node:
            parsed_links.append((link, node))
    if not parsed_links:
        raise ValueError("No supported nodes were found.")

    names = placeholder_names(config_text)
    rendered_names = rendered_node_names([link for link, _ in parsed_links], names)
    proxy_lines = []
    for idx, name in enumerate(rendered_names):
        _, node = parsed_links[idx % len(parsed_links)]
        node = list(node)
        node[0] = f"name: {q(name)}"
        proxy_lines.append("  - {" + ", ".join(node) + "}")

    rendered = replace_proxies_block(config_text, proxy_lines)
    return expand_proxy_group_references(rendered, proxy_group_expansions(names, rendered_names))


def main():
    host = os.environ.get("SUB_CONFIG_HOST", "0.0.0.0")
    port = int(os.environ.get("SUB_CONFIG_PORT", "27880"))
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
