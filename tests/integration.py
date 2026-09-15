#!/usr/bin/env python3

import errno
import fcntl
import hashlib
import json
import os
import pty
import re
import select
import signal
import ssl
import stat
import struct
import subprocess
import unicodedata
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "keenetic"
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
REALM = "integration-realm"
CHALLENGE = "integration-challenge"
USERNAME = "admin"
PASSWORD = "secret"


def local_mac():
    for path in sorted(Path("/sys/class/net").glob("*/address")):
        value = path.read_text().strip().lower()
        if value and value != "00:00:00:00:00:00":
            return value
    return "02:00:00:00:00:01"


class RouterState:
    def __init__(self):
        self.clients = [
            {"name": "Laptop", "ip": "192.0.2.10", "mac": "02:00:00:00:00:10", "link": "up"},
            {"name": "Phone", "ip": "192.0.2.20", "mac": "02:00:00:00:00:20", "link": "up"},
            {"name": "Phone", "ip": "192.0.2.21", "mac": "02:00:00:00:00:21", "link": "up"},
            {"name": "Workstation", "ip": "192.0.2.50", "mac": local_mac(), "link": "up"},
            {"name": "设备客户端", "ip": "192.0.2.60", "mac": "02:00:00:00:00:60", "link": "down"},
        ]
        self.clients[0]["ap"] = "WifiMaster1/AccessPoint0"
        self.clients[1]["ssid"] = "Home"
        self.system = {"hostname": "Router", "uptime": "90061", "cpuload": 7,
                       "memory": "128/1024", "memtotal": 1024, "memfree": 700,
                       "conntotal": 1000, "connfree": 900}
        self.version = {"model": "Giga", "title": "5.1.5", "secret": "must-not-be-output"}
        self.radio_load = {"data": [{"t": "300", "v": 20}, {"t": "297", "v": 40},
                                      {"t": "100", "v": 100}]}
        self.logs = {"log": {"1": {"id": 1, "timestamp": "Sep 15 12:00:00", "ident": "Wireguard0",
                                  "message": {"level": "Error", "message": "test failure"}},
                             "2": {"id": 2, "timestamp": "Sep 15 12:00:01", "ident": "system",
                                  "message": {"level": "Info", "message": "ready"}}}}
        self.log_posts = []
        self.diagnostic_posts = []
        self.diagnostic_cancelled = []
        self.diagnostic_continues = False
        self.diagnostic_invalid = False
        self.clients_status = 200
        self.assignments = {
            "02:00:00:00:00:10": {"policy": False, "deny": False},
            "02:00:00:00:00:20": {"policy": "Policy0", "deny": False},
            "02:00:00:00:00:21": {"policy": "Policy1", "deny": False},
            local_mac(): {"policy": "Policy1", "deny": False},
            "02:00:00:00:00:60": {"policy": "Policy0", "deny": False},
        }
        self.policies = {
            "Policy0": {"description": "Direct"},
            "Policy1": {"description": "VPN"},
        }
        self.interfaces = {
            "Bridge0": {"id": "Bridge0", "type": "Bridge", "description": "Home",
                        "state": "up", "link": "up", "connected": "yes",
                        "address": "192.0.2.1", "mask": "255.255.255.0",
                        "ipv6": {"addresses": [
                            {"address": "2001:db8::1", "prefix-length": 64},
                            {"address": "fe80::1", "prefix-length": 64}]}},
            "Wireguard0": {"type": "Wireguard", "description": "Work VPN",
                           "state": "up", "link": "up", "connected": "yes",
                           "address": "10.0.0.2", "mask": "255.255.255.255",
                           "wireguard": {"private-key": "must-not-be-output"}},
            "OpenVPN0": {"type": "OpenVPN", "description": "Backup",
                         "state": "up", "link": "down", "connected": "no"},
            "Proxy0": {"type": "Proxy", "state": "down", "connected": False},
            "0": {"id": "GigabitEthernet1/0", "type": "Port", "link": "up"},
            "Unknown0": {},
        }
        self.interface_status = 200
        self.interface_gets = 0
        self.interface_posts = []
        self.traffic_summary_status = 200
        self.traffic_summary_gets = 0
        self.traffic_summary_query = None
        self.traffic_periods = {}
        self.traffic_summary = {"t": 0, "host": [
            {"name": "Laptop", "mac": "02:00:00:00:00:10", "active": True,
             "sumbytes": 3072, "rxbytes": 1024, "txbytes": 2048},
            {"name": "Phone", "mac": "02:00:00:00:00:20", "active": True,
             "sumbytes": "4096", "rxbytes": "2048", "txbytes": "2048"},
            {"name": "Phone", "mac": "02:00:00:00:00:21", "active": True,
             "sumbytes": 512, "rxbytes": 0, "txbytes": 512},
            {"name": "Workstation", "mac": local_mac(), "active": True,
             "sumbytes": 5497558138880, "rxbytes": 5497558138880, "txbytes": 0},
            {"name": "设备客户端", "mac": "02:00:00:00:00:60", "active": False,
             "sumbytes": 8192, "rxbytes": 4096, "txbytes": 4096},
            {"name": "Missing from inventory", "mac": "02:00:00:00:AB:70", "active": False,
             "sumbytes": 2048, "rxbytes": 1024, "txbytes": 1024},
            {"type": "others", "sumbytes": 9000000000000, "rxbytes": 9000000000000, "txbytes": 0},
            {"type": "unregistered", "sumbytes": 8000000000000},
            {"type": "multicast", "sumbytes": 7000000000000},
        ]}
        self.interface_post_status = 200
        self.interface_reply = {"status": [{"status": "message", "message": "Interface updated."}]}
        self.interface_drop_updates = False
        self.interface_delay_reads = 0
        self.pending_interface_update = None
        self.remove_interface_on_get = None
        self.ndns = {"name": "home", "domain": "keenetic.link", "access": "direct"}
        self.ndns_status = 200
        self.stats = {
            "Bridge0": {"rxbytes": 1073741824, "txbytes": 2097152, "rxpackets": 1000,
                        "txpackets": 200, "rxerrors": 0, "txerrors": 1, "rxdropped": 2, "txdropped": 0},
            "Wireguard0": {"rxbytes": 5497558138880, "txbytes": 0, "rxpackets": 5000,
                           "txpackets": 0, "rxerrors": 0, "txerrors": 0, "rxdropped": 0, "txdropped": 0},
        }
        self.stats_status = 200
        self.stats_override = None
        self.stats_posts = []
        self.authenticated_requests = 0
        self.host_posts = []
        self.wake_posts = []
        self.pending_updates = {}
        self.delay_next_update_reads = 0
        self.drop_next_update = False
        self.fail_mac_once = None
        self.assignment_gets = 0

    def assignment_list(self):
        self.assignment_gets += 1
        for mac, pending in list(self.pending_updates.items()):
            state, remaining = pending
            if remaining <= 0:
                self.assignments[mac] = state
                del self.pending_updates[mac]
            else:
                self.pending_updates[mac] = (state, remaining - 1)
        return [{"mac": mac, **value} for mac, value in self.assignments.items()]

    def update_from_post(self, body):
        mac = body["mac"].lower()
        current = dict(self.assignments.get(mac, {"policy": False, "deny": False}))
        if "policy" in body:
            current["policy"] = body["policy"]
        if body.get("deny") is True:
            current["deny"] = True
        elif body.get("permit") is True:
            current["deny"] = False
        if self.drop_next_update:
            self.drop_next_update = False
        elif self.delay_next_update_reads:
            self.pending_updates[mac] = (current, self.delay_next_update_reads)
            self.delay_next_update_reads = 0
        else:
            self.assignments[mac] = current


STATE = RouterState()
class QuietHTTPServer(ThreadingHTTPServer):
    def handle_error(self, _request, _client_address):
        pass




class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass

    def reply(self, status, body, headers=None):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def authenticated(self):
        return "session=ok" in self.headers.get("Cookie", "")

    def do_GET(self):
        if self.path == "/auth":
            if self.authenticated():
                self.reply(200, {})
            else:
                self.reply(401, {}, {
                    "X-NDM-Realm": REALM,
                    "X-NDM-Challenge": CHALLENGE,
                })
            return
        if not self.authenticated():
            self.reply(401, {"message": "authentication required"})
        elif self.path == "/rci/show/ip/hotspot/host":
            self.reply(STATE.clients_status, STATE.clients)
        elif urlsplit(self.path).path == "/rci/show/ip/hotspot/summary":
            query = parse_qs(urlsplit(self.path).query)
            check(set(query) in ({"count", "detail", "attribute"}, {"detail", "attribute"}) and query["attribute"] == ["sumbytes"],
                  "traffic summary request is missing ranking parameters")
            STATE.traffic_summary_query = query
            STATE.traffic_summary_gets += 1
            self.reply(STATE.traffic_summary_status, STATE.traffic_periods.get(query["detail"][0], STATE.traffic_summary))
        elif self.path == "/rci/show/rc/ip/hotspot/host":
            self.reply(200, STATE.assignment_list())
        elif self.path == "/rci/show/rc/ip/policy":
            self.reply(200, STATE.policies)
        elif self.path == "/rci/show/interface":
            STATE.interface_gets += 1
            if STATE.remove_interface_on_get:
                count, ident = STATE.remove_interface_on_get
                if STATE.interface_gets == count:
                    STATE.interfaces.pop(ident, None)
                    STATE.remove_interface_on_get = None
            if STATE.pending_interface_update:
                ident, state, remaining = STATE.pending_interface_update
                if remaining == 0:
                    entry = next(value for key, value in STATE.interfaces.items() if value.get("id", key) == ident)
                    entry["state"] = state
                    if state == "down":
                        entry.update(link="down", connected="no")
                    STATE.pending_interface_update = None
                else:
                    STATE.pending_interface_update = (ident, state, remaining - 1)
            self.reply(STATE.interface_status, STATE.interfaces)
        elif self.path == "/rci/show/system":
            self.reply(200, STATE.system)
        elif self.path == "/rci/show/version":
            self.reply(200, STATE.version)
        elif urlsplit(self.path).path == "/rci/show/interface/channel-utilization/rrd":
            query = parse_qs(urlsplit(self.path).query)
            check(query["attribute"] == ["load"] and query["detail"] == ["0"], "radio query")
            self.reply(200, STATE.radio_load)
        elif self.path.startswith("/rci/tools/"):
            self.reply(200, {"message": ["reply"], "continued": STATE.diagnostic_continues})
        elif self.path == "/rci/show/ndns":
            self.reply(STATE.ndns_status, STATE.ndns)
        else:
            self.reply(404, {"message": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/auth":
            md5 = hashlib.md5(f"{USERNAME}:{REALM}:{PASSWORD}".encode()).hexdigest()
            expected = hashlib.sha256(f"{CHALLENGE}{md5}".encode()).hexdigest()
            if body == {"login": USERNAME, "password": expected}:
                STATE.authenticated_requests += 1
                self.reply(200, {}, {"Set-Cookie": "session=ok; Path=/"})
            else:
                self.reply(403, {"message": "bad credentials"})
            return
        if not self.authenticated():
            self.reply(401, {"message": "authentication required"})
        elif self.path == "/rci/show/log":
            STATE.log_posts.append(body)
            self.reply(200, STATE.logs)
        elif self.path.startswith("/rci/tools/"):
            STATE.diagnostic_posts.append((self.path, body))
            self.reply(200, {"message": 5 if STATE.diagnostic_invalid else ["started"], "continued": True})
        elif self.path == "/rci/":
            if isinstance(body, dict) and "interface" in body:
                STATE.interface_posts.append(body)
                check(list(body) == ["interface"] and len(body["interface"]) == 1,
                      "unexpected interface command")
                ident, command = next(iter(body["interface"].items()))
                check(command in ({"up": True}, {"up": {"no": True}}), "unexpected interface action")
                check(any(value.get("id", key) == ident for key, value in STATE.interfaces.items()),
                      "interface mutation would create an unknown interface")
                if not STATE.interface_drop_updates:
                    STATE.pending_interface_update = (ident, "up" if command["up"] is True else "down",
                                                      STATE.interface_delay_reads)
                self.reply(STATE.interface_post_status, STATE.interface_reply)
                return
            STATE.stats_posts.append(body)
            results = []
            for command in body:
                name = command["show"]["interface"]["name"]
                check(command == {"show": {"interface": {"name": name, "stat": {}}}},
                      "statistics request contains a non-show command")
                stat_data = STATE.stats.get(name, {"rxbytes": 0, "txbytes": 0})
                results.append({"show": {"interface": {"stat": stat_data}}})
            self.reply(STATE.stats_status, STATE.stats_override if STATE.stats_override is not None else results)
        elif self.path == "/rci/ip/hotspot/host":
            STATE.host_posts.append(body)
            if STATE.fail_mac_once == body.get("mac"):
                STATE.fail_mac_once = None
                self.reply(500, {"message": "injected batch failure"})
                return
            STATE.update_from_post(body)
            self.reply(200, {"status": "ok"})
        elif self.path == "/rci/ip/hotspot/wake":
            STATE.wake_posts.append(body)
            self.reply(200, {"message": "magic packet queued", "mac": body.get("mac")})
        else:
            self.reply(404, {"message": "not found"})

    def do_DELETE(self):
        if not self.authenticated():
            self.reply(401, {})
            return
        STATE.diagnostic_cancelled.append(self.path)
        self.reply(200, {})


def base_env(config=None, history=None):
    env = os.environ.copy()
    env.pop("CURL_CA_BUNDLE", None)
    env.pop("SSL_CERT_FILE", None)
    env["NO_COLOR"] = "1"
    if config is not None:
        env["KEENETIC_CONFIG"] = str(config)
        env["KEENETIC_STATE_FILE"] = str(history or config.parent / "history.json")
    return env


def run(config, *args, input_text=None, extra_env=None, timeout=12, subcommand="policy"):
    env = base_env(config)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [str(SCRIPT), *([subcommand] if subcommand else []), *args], cwd=ROOT, env=env, input=input_text,
        text=True, capture_output=True, timeout=timeout,
    )


def read_pty(master, marker=None, timeout=5):
    output = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(master, 4096)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        output.extend(chunk)
        if marker and marker.encode() in output:
            break
    return output.decode(errors="replace")


def start_pty(config, *args, columns=80, extra_env=None, subcommand="policy"):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, *termios_size(24, columns))
    env = base_env(config)
    if extra_env:
        env.update(extra_env)
    process = subprocess.Popen(
        [str(SCRIPT), subcommand, *args], cwd=ROOT, env=env,
        stdin=slave, stdout=slave, stderr=slave, close_fds=True,
    )
    os.close(slave)
    return process, master


def termios_size(rows, columns):
    return 0x5414, struct.pack("HHHH", rows, columns, 0, 0)


def finish_pty(process, master):
    output = read_pty(master, timeout=2)
    process.wait(timeout=8)
    os.close(master)
    return output


def display_width(value):
    return sum(
        0 if unicodedata.combining(character) else
        2 if unicodedata.east_asian_width(character) in {"W", "F"} else 1
        for character in value
    )


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def report(index, name):
    print(f"ok {index} - {name}")


def make_tls_server(temp):
    ca_key = temp / "ca.key"
    ca_cert = temp / "ca.crt"
    server_key = temp / "server.key"
    request = temp / "server.csr"
    server_cert = temp / "server.crt"
    extension = temp / "server.ext"
    quiet = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL, "check": True}
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=Keenetic Test CA", "-keyout", str(ca_key), "-out", str(ca_cert)], **quiet)
    subprocess.run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1",
                    "-keyout", str(server_key), "-out", str(request)], **quiet)
    extension.write_text("subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n")
    subprocess.run(["openssl", "x509", "-req", "-days", "1", "-in", str(request),
                    "-CA", str(ca_cert), "-CAkey", str(ca_key), "-CAcreateserial",
                    "-extfile", str(extension), "-out", str(server_cert)], **quiet)
    server = QuietHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(server_cert, server_key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, ca_cert


def main():
    server = QuietHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}"
    tls_server = tls_thread = None

    try:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            config = temp / "config"
            config.write_text(f"ROUTER_URL={url}\nROUTER_USERNAME={USERNAME}\nROUTER_PASSWORD={PASSWORD}\n")
            config.chmod(0o600)
            index = 1

            result = subprocess.run([str(SCRIPT), "--version"], cwd=ROOT, text=True, capture_output=True)
            check(result.returncode == 0 and result.stdout.strip().endswith("1.2.0"), "version output")
            report(index, "version output"); index += 1

            root_env = base_env(temp / "missing-config")
            for args, status, expected in (
                ([], 1, "--init"),
                (["--help"], 0, "Commands:"),
                (["policy", "--help"], 0, "keenetic policy --interactive"),
                (["interfaces", "--help"], 0, "keenetic interfaces --interactive"),
                (["traffic", "--help"], 0, "keenetic traffic [--top N]"),
                (["wifi", "--help"], 0, "keenetic wifi [--all] [--json]"),
                (["wifi", "--interactive"], 2, "unknown option for wifi"),
                (["wifi", "--offline"], 2, "unknown option for wifi"),
                (["wifi", "--top", "3"], 2, "unknown option for wifi"),
                (["wifi", "Guest"], 2, "unknown option for wifi"),
                (["traffic", "--top", "0"], 2, "--top requires a positive integer"),
                (["traffic", "--top=-1"], 2, "--top requires a positive integer"),
                (["traffic", "--top=1.5"], 2, "--top requires a positive integer"),
                (["traffic", "--top=2147483648"], 2, "--top requires a positive integer"),
                (["traffic", "--top=99999999999999999999999999"], 2, "--top requires a positive integer"),
                (["traffic", "--top="], 2, "--top requires a positive integer"),
                (["traffic", "--period=5m"], 2, "--period must be"),
                (["traffic", "--period="], 2, "--period must be"),
                (["traffic", "--period"], 2, "--period requires a value"),
                (["traffic", "--top"], 2, "--top requires a value"),
                (["policy", "--top", "3"], 2, "only valid for traffic"),
                (["traffic", "--interactive"], 2, "unknown option for traffic"),
                (["traffic", "--all"], 2, "unknown option for traffic"),
                (["--all", "traffic"], 2, "--all is only valid"),
                (["traffic", "--dry-run"], 2, "unknown option for traffic"),
                (["traffic", "Laptop"], 2, "unknown option for traffic"),
                (["interfaces", "--offline"], 2, "unknown option for interfaces"),
                (["interfaces", "--client", "Laptop"], 2, "unknown option for interfaces"),
                (["interfaces", "Wireguard0"], 2, "unknown option for interfaces"),
                (["interfaces", "--json", "--interactive"], 2, "non-interactive listings"),
                (["interfaces", "--dry-run"], 2, "--dry-run requires"),
                (["--json"], 1, "--init"),
                (["unknown"], 2, "unknown command"),
                (["--init", "--help"], 0, "keenetic --init"),
                (["policy", "--init"], 2, "outside the policy subcommand"),
                (["policy", "--discover"], 2, "outside the policy subcommand"),
                (["--init", "--discover"], 2, "must be used alone"),
                (["--init", "--client", "Laptop"], 2, "unknown command or option"),
                (["--router", "home"], 2, "cannot be combined with KEENETIC_CONFIG"),
                (["--init", "--json"], 2, "cannot be combined"),
                (["--discover", "--json"], 2, "must be used alone"),
                (["--all", "--init"], 2, "only valid for interface or policy listings"),
                (["--discover", "--all"], 2, "only valid for interface or policy listings"),
                (["--all", "wake", "Laptop"], 2, "only valid for interface or policy listings"),
                (["--help", "policy"], 0, "keenetic policy --interactive"),
                (["--verbose", "wake", "--help"], 0, "wake SELECTOR"),
                (["--help", "wake"], 0, "wake SELECTOR"),
                (["--version", "policy"], 0, "keenetic 1.2.0"),
                (["wake", "--version"], 0, "keenetic 1.2.0"),
                (["wake"], 2, "requires at least one"),
                (["wake", "--json"], 2, "unknown option for wake"),
                (["wake", "--policy", "VPN"], 2, "unknown option for wake"),
                (["policy", "--wake"], 2, "wake' subcommand"),
                (["--init", "policy"], 2, "cannot be combined with a subcommand"),
                (["--discover", "wake"], 2, "cannot be combined with a subcommand"),
                (["--ca-file", "ca.pem", "policy", "--insecure"], 2, "cannot be combined"),
                (["--client", "Laptop", "wake"], 2, "unknown command or option"),
            ):
                result = subprocess.run([str(SCRIPT), *args], cwd=ROOT, env=root_env,
                                        text=True, capture_output=True, timeout=5)
                check(result.returncode == status and expected in result.stdout + result.stderr,
                      f"command dispatch {args}: {result.stdout} {result.stderr}")
            check(STATE.authenticated_requests == 0, "help or invalid commands contacted the router")
            report(index, "policy subcommand dispatch and configuration-free help"); index += 1

            result = run(config, subcommand=None, extra_env={"COLUMNS": "200"})
            check(result.returncode == 0, result.stderr)
            check(re.search(r"^Router\s+" + re.escape(url) + r"$", result.stdout, re.M)
                  and "VPN / proxy interfaces" in result.stdout,
                  "bare command did not show router status")
            info = result.stdout.split("\n\n", 1)[0].splitlines()
            check(len(info) == 4 and info[0].startswith("ROUTER INFO"), "router info table header or rows")
            info_column = info[0].index("VALUE")
            for row, label in zip(info[1:], ("Router", "KeenDNS", "Connected clients")):
                check(row.startswith(label) and row[info_column:].strip()
                      and row[len(label):info_column].isspace(), "router info values are misaligned")
            check(max(map(display_width, info)) < 80, "router info stretched beyond its content")
            for value in ("Work VPN", "192.0.2.1", "10.0.0.2", "2001:db8::1/64", "fe80::1/64",
                          "link up"):
                check(value in result.stdout, f"missing interface status: {value}")
            for hidden in ("OpenVPN0", "Proxy0", "Unknown0"):
                check(hidden not in result.stdout, f"inactive interface shown by default: {hidden}")
            check(result.stdout.index("Wireguard0") < result.stdout.index("Bridge0"), "VPN ordering")
            interface_rows = [line for line in result.stdout.splitlines()
                              if line.startswith(("Wireguard0", "Bridge0", "GigabitEthernet1/0"))]
            check(len(interface_rows) == 3, "wide interface view should use one row per interface")
            status_columns = [line.index("link up" if "link up" in line else "connected") for line in interface_rows]
            check(len(set(status_columns)) == 1, "interface status columns are misaligned")
            check(not any(char in result.stdout for char in "╭├╰│"), "interface list still has table borders")
            check("INTERFACE / NAME" in result.stdout and "IP ADDRESS" in result.stdout, "missing interface headers")
            result = run(config, "--json", subcommand=None)
            check(result.returncode == 0, result.stderr)
            active_ids = {entry["id"] for entry in json.loads(result.stdout)["interfaces"]}
            check(active_ids == {"Bridge0", "Wireguard0", "GigabitEthernet1/0"}, "default status filter")
            queried_ids = {entry["show"]["interface"]["name"] for entry in STATE.stats_posts[-1]}
            check(queried_ids == active_ids, "traffic requested for hidden interfaces")
            all_status = run(config, "--all", subcommand=None)
            check(all_status.returncode == 0, all_status.stderr)
            for value in ("OpenVPN0", "Proxy0", "Unknown0", "disconnected", "disabled", "unknown"):
                check(value in all_status.stdout, f"--all omitted interface status: {value}")
            result = run(config, "--all", "--json", subcommand=None)
            check(result.returncode == 0, result.stderr)
            status = json.loads(result.stdout)
            interfaces = {item["id"]: item for item in status["interfaces"]}
            check(status["router"] == url and len(interfaces) == 6, "status JSON contract")
            check(interfaces["Wireguard0"]["vpn"] and interfaces["Wireguard0"]["connected"] is True,
                  "VPN connection normalization")
            check(interfaces["Proxy0"]["connected"] is False, "boolean connection normalization")
            check(interfaces["Unknown0"]["connected"] is None, "missing connection treated as known")
            check(interfaces["Bridge0"]["ipv6"][1] == {"address": "fe80::1", "prefix_length": 64},
                  "IPv6 address normalization")
            check(interfaces["OpenVPN0"]["ipv4"] is None, "absent IPv4 address")
            check("must-not-be-output" not in result.stdout, "raw VPN data leaked")
            check(not STATE.host_posts and not STATE.wake_posts and STATE.assignment_gets == 0,
                  "status invoked client or mutation endpoints")
            saved_interfaces = STATE.interfaces
            STATE.interfaces = {
                "Port0": {"type": "Port", "link": "down"},
                "VPN0": {"type": "Wireguard", "state": "up", "link": "down", "connected": "yes"},
            }
            previous_stats_posts = len(STATE.stats_posts)
            filtered = run(config, "--json", subcommand=None)
            check(filtered.returncode == 0 and json.loads(filtered.stdout)["interfaces"] == [],
                  "link-down interfaces appeared in default output")
            check(len(STATE.stats_posts) == previous_stats_posts, "empty view fetched traffic stats")
            check("link down" in run(config, "--all", subcommand=None).stdout, "--all omitted link-down port")
            STATE.interfaces = {}
            check("None" in run(config, subcommand=None).stdout, "empty status table")
            for invalid in ([], {"Bridge0": "invalid"}):
                STATE.interfaces = invalid
                failed = run(config, subcommand=None)
                check(failed.returncode == 1 and "invalid" in failed.stderr, "invalid interface response")
            STATE.interfaces = {"message": "unsupported interface API"}
            STATE.interface_status = 404
            failed = run(config, subcommand=None)
            check(failed.returncode == 1 and "HTTP 404" in failed.stderr, "unsupported status endpoint")
            STATE.interfaces = saved_interfaces
            STATE.interface_status = 200
            report(index, "default interface status, IPv4/IPv6, JSON, and API failures"); index += 1

            original_description = STATE.interfaces["Bridge0"]["description"]
            original_ipv6 = STATE.interfaces["Bridge0"]["ipv6"]
            long_name = "家庭网络 Cafe\u0301 " + "x" * 45
            long_ip = "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff/64"
            STATE.interfaces["Bridge0"]["description"] = long_name
            STATE.interfaces["Bridge0"]["ipv6"] = {"addresses": [
                {"address": long_ip.split("/")[0], "prefix-length": 64}]}
            for columns in (20, 32, 40, 60, 80, 120):
                result = run(config, "--all", "--color=always", subcommand=None,
                             extra_env={"COLUMNS": str(columns)})
                check(result.returncode == 0, result.stderr)
                clean = ANSI.sub("", result.stdout)
                check(all(display_width(line) <= columns for line in clean.splitlines()),
                      f"status output exceeds {columns} columns")
                check(not any(char in clean for char in "╭├╰│"), "narrow status still has table borders")
                check("…" in clean, "long interface fields should be abbreviated")
                if columns < 72:
                    check(long_ip in "".join(clean.split()), "narrow view lost its wrapped address details")
            wide = run(config, subcommand=None, extra_env={"COLUMNS": "240"})
            check(wide.returncode == 0 and "INTERFACE / NAME" in wide.stdout,
                  "wide screens lost the aligned list")
            full = json.loads(run(config, "--json", subcommand=None, extra_env={"COLUMNS": "20"}).stdout)
            full_bridge = next(item for item in full["interfaces"] if item["id"] == "Bridge0")
            check(full_bridge["description"] == long_name and
                  full_bridge["ipv6"][0]["address"] == long_ip.split("/")[0], "JSON truncated interface data")
            STATE.interfaces["Bridge0"]["description"] = original_description
            STATE.interfaces["Bridge0"]["ipv6"] = original_ipv6
            report(index, "compact responsive interface rows, color alignment, and complete JSON"); index += 1

            result = run(config, subcommand=None)
            check(result.returncode == 0, result.stderr)
            for value in ("home.keenetic.link (direct)", "1 GiB", "2 MiB", "5 TiB", "0 B"):
                check(value in result.stdout, f"missing status detail: {value}")
            details = json.loads(run(config, "--json", subcommand=None).stdout)
            check(details["keendns"] == {"hostname": "home.keenetic.link", "access": "direct"}, "KeenDNS JSON")
            by_id = {entry["id"]: entry for entry in details["interfaces"]}
            check(by_id["Bridge0"]["traffic"]["rx_bytes"] == 1073741824, "traffic mapped to wrong interface")
            check(by_id["Wireguard0"]["traffic"]["rx_bytes"] == 5497558138880, "large traffic counter")
            check(by_id["Wireguard0"]["traffic"]["tx_bytes"] == 0, "zero traffic counter lost")
            check(by_id["Bridge0"]["traffic"]["rx_packets"] == 1000
                  and by_id["Bridge0"]["traffic"]["tx_errors"] == 1
                  and by_id["Bridge0"]["traffic"]["rx_dropped"] == 2, "packet/error/drop counters")
            check(STATE.stats_posts and not STATE.host_posts and not STATE.wake_posts, "status changed router config")
            STATE.ndns = {}
            check(re.search(r"KeenDNS\s+not configured", run(config, subcommand=None).stdout), "unconfigured KeenDNS")
            STATE.ndns = {"name": "home.keenetic.link", "domain": "keenetic.link", "access": "cloud"}
            check("home.keenetic.link.keenetic.link" not in run(config, subcommand=None).stdout, "duplicated DNS suffix")
            for ndns_status, ndns_data in ((404, {}), (200, []), (200, {"status": [{"status": "error"}]})):
                STATE.ndns_status, STATE.ndns = ndns_status, ndns_data
                result = run(config, "--json", subcommand=None)
                check(result.returncode == 0 and json.loads(result.stdout)["keendns"] is None, "optional KeenDNS failure")
                check("KeenDNS status unavailable" in result.stderr, "missing KeenDNS diagnostic")
            STATE.ndns_status = 200
            STATE.ndns = {"name": "home", "domain": "keenetic.link", "access": "direct"}
            for stats_status, stats_data in ((404, {}), (200, []), (200, {"status": [{"status": "error"}]})):
                STATE.stats_status, STATE.stats_override = stats_status, stats_data
                result = run(config, "--json", subcommand=None)
                check(result.returncode == 0 and all(entry["traffic"] is None for entry in json.loads(result.stdout)["interfaces"]),
                      "invalid batch statistics were mapped to interfaces")
                check("Traffic statistics unavailable" in result.stderr, "missing traffic diagnostic")
            STATE.stats_status, STATE.stats_override = 200, None
            original_stats = STATE.stats["Wireguard0"]
            STATE.stats["Wireguard0"] = {"status": [{"status": "error"}], "rxbytes": 123}
            result = run(config, "--json", subcommand=None)
            by_id = {entry["id"]: entry for entry in json.loads(result.stdout)["interfaces"]}
            check(by_id["Wireguard0"]["traffic"] is None and by_id["Bridge0"]["traffic"]["rx_bytes"] == 1073741824,
                  "partial statistics error discarded valid counters or reported bogus data")
            STATE.stats["Wireguard0"] = {"rxbytes": "1024", "txbytes": -1}
            result = run(config, "--json", subcommand=None)
            by_id = {entry["id"]: entry for entry in json.loads(result.stdout)["interfaces"]}
            check(by_id["Wireguard0"]["traffic"]["rx_bytes"] == 1024 and by_id["Wireguard0"]["traffic"]["tx_bytes"] is None,
                  "traffic counter normalization")
            STATE.stats["Wireguard0"] = original_stats
            report(index, "KeenDNS and traffic totals, partial support, and read-only batches"); index += 1

            result = run(config, subcommand=None)
            check(result.returncode == 0 and re.search(r"Connected clients\s+4 \(2 wired / 2 wireless\)", result.stdout),
                  result.stderr or "missing client counts")
            saved_clients = STATE.clients
            STATE.clients = [
                {"mac": "AA:BB:CC:DD:EE:01", "link": "down", "ap": "WifiMaster0/AccessPoint0"},
                {"mac": "AA:BB:CC:DD:EE:01", "link": "up", "ap": ""},
                {"mac": "aa:bb:cc:dd:ee:01", "link": "up"},
                {"mac": "aa:bb:cc:dd:ee:02", "mws": {"link": "up", "ap": "WifiMaster0/AccessPoint0"}},
                {"mac": "aa:bb:cc:dd:ee:03", "link": "down", "ssid": "Offline"},
                {"mac": "aa:bb:cc:dd:ee:04", "link": "up", "ssid": ""},
            ]
            for flags in (("--json",), ("--all", "--json")):
                result = run(config, *flags, subcommand=None)
                check(result.returncode == 0, result.stderr)
                check(json.loads(result.stdout)["clients"] == {"connected": 3, "wired": 1, "wireless": 2},
                      "client counts did not handle offline, duplicate, or mesh clients")
            STATE.clients = []
            empty = json.loads(run(config, "--json", subcommand=None).stdout)
            check(empty["clients"] == {"connected": 0, "wired": 0, "wireless": 0}, "empty client counts")
            for status, body in ((404, {}), (200, {}), (200, [{"link": "up"}])):
                STATE.clients_status, STATE.clients = status, body
                result = run(config, "--json", subcommand=None)
                check(result.returncode == 0 and json.loads(result.stdout)["clients"] is None,
                      "unavailable client counts were reported as zero")
                check("Connected client counts unavailable" in result.stderr, "missing client count diagnostic")
            STATE.clients_status, STATE.clients = 200, saved_clients
            report(index, "wired/wireless connected-client summary and unavailable counts"); index += 1

            before_posts = (len(STATE.stats_posts), len(STATE.interface_posts), len(STATE.host_posts), len(STATE.wake_posts))
            result = run(config, "--json", subcommand="traffic")
            check(result.returncode == 0, result.stderr)
            traffic = json.loads(result.stdout)
            check(traffic["window_seconds"] == 180 and traffic["limit"] == 5 and traffic["router"] == url,
                  "traffic window or JSON metadata")
            check(STATE.traffic_summary_query == {"count": ["5"], "detail": ["0"], "attribute": ["sumbytes"]},
                  "default traffic query did not request the three-minute top five")
            check([client["total_bytes"] for client in traffic["clients"]] == [5497558138880, 8192, 4096, 3072, 2048],
                  "traffic did not rank the top five clients by combined bytes")
            check([client["rank"] for client in traffic["clients"]] == [1, 2, 3, 4, 5], "traffic ranks")
            check(traffic["clients"][1]["name"] == "设备客户端" and traffic["clients"][1]["ip"] == "192.0.2.60",
                  "offline client traffic was hidden")
            check(traffic["clients"][-1]["mac"] == "02:00:00:00:ab:70" and traffic["clients"][-1]["ip"] is None,
                  "missing-inventory client traffic was lost")
            check(traffic["clients"][0]["tx_bytes"] == 0, "zero traffic counter lost")
            check([client["online"] for client in traffic["clients"]] == [True, False, True, True, None],
                  "traffic client online/offline/unknown status")
            listed = run(config, subcommand="traffic", extra_env={"COLUMNS": "120"})
            check(listed.returncode == 0 and "last 3 minutes" in listed.stdout and "5 TiB" in listed.stdout,
                  listed.stderr or "traffic table content")
            rows = listed.stdout.splitlines()
            check(len(rows) == 7 and max(map(display_width, rows)) < 120, "traffic table stretched or added rows")
            total_end = rows[1].index("TOTAL") + len("TOTAL")
            status_column = rows[1].index("STATUS")
            for row, expected in zip(rows[2:], ("online", "offline", "online", "online", "unknown")):
                status = re.search(r"\b(online|offline|unknown)\s*$", row)
                check(status and status.group().strip() == expected
                      and display_width(row[:status.start()]) == status_column, "traffic status column is misaligned")
                check(display_width(row[:status.start()].rstrip()) == total_end, "traffic totals are misaligned")
            check(before_posts == (len(STATE.stats_posts), len(STATE.interface_posts), len(STATE.host_posts), len(STATE.wake_posts)),
                  "traffic command sent a POST")
            saved_traffic = json.loads(json.dumps(STATE.traffic_summary))
            STATE.traffic_summary["host"][0]["name"] = long_name
            for columns in (20, 32, 40, 60, 80, 120):
                listed = run(config, "--color=always", subcommand="traffic", extra_env={"COLUMNS": str(columns)})
                clean = ANSI.sub("", listed.stdout)
                check(listed.returncode == 0 and all(display_width(line) <= columns for line in clean.splitlines()),
                      f"traffic table exceeds {columns} columns: {listed.stderr}")
                check("TOTAL" in clean, "narrow traffic view lost totals")
                check("STATUS" in clean and len(re.findall(r"\b(online|offline|unknown)\s*$", clean, re.M)) == 5,
                      "traffic status missing on narrow screens")
                if columns < 72:
                    check("192.0.2.10" in clean and "RX" in clean and "TX" in clean, "narrow traffic details lost")
            full = json.loads(run(config, "--json", subcommand="traffic", extra_env={"COLUMNS": "20"}).stdout)
            check(any(client["name"] == long_name for client in full["clients"]), "traffic JSON truncated names")
            STATE.traffic_summary = json.loads(json.dumps(saved_traffic))
            original_hosts = STATE.clients
            STATE.clients = [{"mac": "02:00:00:00:00:10", "link": "down"},
                             {"mac": "02:00:00:00:00:10", "mws": {"link": "up"}},
                             {"mac": "02:00:00:00:00:20", "ip": "192.0.2.20"}]
            statuses = {client["mac"]: client["online"] for client in
                        json.loads(run(config, "--json", subcommand="traffic").stdout)["clients"]}
            check(statuses["02:00:00:00:00:10"] is True and statuses["02:00:00:00:00:20"] is None,
                  "traffic status ignored mesh links or assumed a missing link was offline")
            STATE.clients = original_hosts
            report(index, "three-minute traffic ranking, offline clients, read-only requests, and compact tables"); index += 1

            for summary in ({"t": 0, "host": []}, {"t": 0, "host": [{"type": "others", "sumbytes": 512}]}):
                STATE.traffic_summary = summary
                listed = run(config, subcommand="traffic")
                check(listed.returncode == 0 and "No client traffic recorded" in listed.stdout, "empty traffic history")
            STATE.traffic_summary = {"t": 0, "host": [
                {"name": "", "mac": "02:00:00:00:AB:70", "rxbytes": 512, "txbytes": 1024},
                {"name": "", "mac": "02:00:00:00:ab:70", "sumbytes": 100, "rxbytes": 50, "txbytes": 50},
            ]}
            partial = json.loads(run(config, "--json", subcommand="traffic").stdout)["clients"]
            check(len(partial) == 1 and partial[0]["total_bytes"] == 1536 and partial[0]["name"].lower() == partial[0]["mac"],
                  "traffic duplicate MAC, empty name, or derived total")
            STATE.traffic_summary = {"t": 0, "host": [{"mac": "02:00:00:00:00:10", "sumbytes": 1024}]}
            partial = json.loads(run(config, "--json", subcommand="traffic").stdout)["clients"][0]
            check(partial["rx_bytes"] is None and partial["tx_bytes"] is None, "missing traffic counters became zero")
            STATE.traffic_summary = saved_traffic
            STATE.clients_status = 404
            partial = run(config, "--json", subcommand="traffic")
            check(partial.returncode == 0 and all(client["ip"] is None for client in json.loads(partial.stdout)["clients"])
                  and all(client["online"] is None for client in json.loads(partial.stdout)["clients"])
                  and "details unavailable" in partial.stderr, "unavailable client inventory lost traffic history")
            STATE.clients_status = 200
            for summary in ({}, {"t": 2, "host": []}, {"t": 0, "host": {}},
                            {"t": 0, "host": ["invalid"]}, {"t": 0, "host": [{"mac": "invalid", "sumbytes": 5}]},
                            {"t": 0, "host": [{"mac": "02:00:00:00:00:10", "sumbytes": -1}]},
                            {"t": 0, "host": [{"mac": "02:00:00:00:00:10", "sumbytes": "bad"}]},
                            {"t": 0, "host": [{"mac": "02:00:00:00:00:10"}]},
                            {"t": 0, "host": [], "status": [{"status": "error"}]}):
                STATE.traffic_summary = summary
                failed = run(config, "--json", subcommand="traffic")
                check(failed.returncode == 1 and not failed.stdout and "invalid 3m traffic history" in failed.stderr,
                      "invalid history was shown as a successful three-minute result")
            STATE.traffic_summary = saved_traffic
            for status in (404, 403):
                STATE.traffic_summary_status = status
                failed = run(config, subcommand="traffic")
                check(failed.returncode == 1 and f"HTTP {status}" in failed.stderr, "traffic endpoint failure")
            STATE.traffic_summary_status = 200
            report(index, "empty, partial, duplicate, invalid, and unsupported traffic history"); index += 1

            for period, detail, seconds, title in (("3m", 0, 180, "3 minutes"), ("1h", 1, 3600, "1 hour"),
                                                   ("3h", 2, 10800, "3 hours"), ("1d", 3, 86400, "1 day")):
                STATE.traffic_periods[str(detail)] = {**saved_traffic, "t": detail}
                result = run(config, "--top", "2", f"--period={period}", "--json", subcommand="traffic")
                check(result.returncode == 0, result.stderr)
                data = json.loads(result.stdout)
                check(data["period"] == period and data["window_seconds"] == seconds and data["limit"] == 2
                      and len(data["clients"]) == 2, "configurable traffic metadata or count")
                check(STATE.traffic_summary_query == {"count": ["2"], "detail": [str(detail)], "attribute": ["sumbytes"]},
                      "traffic options did not reach the router query")
                listed = run(config, "--top=1", "--period", period, subcommand="traffic")
                check(listed.returncode == 0 and f"Top 1 clients · last {title}" in listed.stdout, "traffic title ignores options")
            larger = json.loads(run(config, "--top=10", "--period=1d", "--json", subcommand="traffic").stdout)
            check(len(larger["clients"]) == 6 and larger["limit"] == 10, "traffic count larger than available clients")
            STATE.traffic_periods = {}
            report(index, "configurable traffic limits and all four stored history windows"); index += 1

            saved_wifi_interfaces, saved_wifi_clients = STATE.interfaces, STATE.clients
            STATE.interfaces = {
                "WifiMaster0": {"type": "WifiMaster", "state": "up", "link": "up", "channel": 6, "bandwidth": "40"},
                "WifiMaster1": {"type": "WifiMaster", "state": "up", "link": "up", "channel": 36, "bandwidth": "80"},
                "WifiMaster2": {"type": "WifiMaster", "state": "up", "link": "up", "frequency": 5975,
                                "channel": 5, "bandwidth": "160"},
                "WifiMaster3": {"type": "WifiMaster", "state": "down", "link": "down", "band": "5GHz"},
                "WifiMaster0/AccessPoint0": {"type": "AccessPoint", "state": "up", "link": "up", "ssid": "Home",
                    "mac": "02:AA:00:00:00:01", "auth-type": "none", "encryption": "wpa2",
                    "authentication": {"wpa-psk": "wifi-password-must-not-leak"}},
                "WifiMaster1/AccessPoint0": {"type": "AccessPoint", "state": "up", "link": "up", "ssid": "Home",
                    "auth-type": "none", "encryption": "wpa2+wpa3"},
                "WifiMaster0/AccessPoint1": {"type": "AccessPoint", "state": "down", "link": "down", "ssid": "Guest"},
                "WifiMaster1/WifiStation0": {"type": "WifiStation", "state": "up", "link": "up", "ssid": "Uplink"},
                "WifiMaster2/AccessPoint0": {"type": "AccessPoint", "state": "up", "link": "up", "ssid": long_name,
                    "auth-type": "none", "encryption": "wpa3"},
                "WifiMaster3/AccessPoint0": {"type": "AccessPoint", "state": "up", "link": "up", "ssid": "Radio disabled"},
                "WifiMaster4/AccessPoint0": {"type": "AccessPoint", "state": "up", "link": "up", "ssid": "Open network",
                    "auth-type": "none", "encryption": "none"},
                "WifiMaster4/AccessPoint1": {"type": "AccessPoint", "state": "up", "link": "down", "ssid": "Link down"},
            }
            STATE.clients = [
                {"mac": "02:00:00:00:AB:10", "link": "up", "ap": "WifiMaster0/AccessPoint0"},
                {"mac": "02:00:00:00:ab:10", "link": "up", "ap": "WifiMaster0/AccessPoint0"},
                {"mac": "02:00:00:00:00:20", "link": "down", "ap": "WifiMaster0/AccessPoint0"},
                {"mac": "02:00:00:00:00:21", "mws": {"link": "up", "ap": "WifiMaster1/AccessPoint0"}},
                {"mac": "02:00:00:00:00:22", "link": "up", "ssid": "Home"},
            ]
            before_posts = (len(STATE.stats_posts), len(STATE.interface_posts), len(STATE.host_posts))
            result = run(config, "--json", subcommand="wifi")
            check(result.returncode == 0, result.stderr)
            wifi = json.loads(result.stdout)
            check(wifi["router"] == url and len(wifi["networks"]) == 4, "Wi-Fi active-network filter")
            networks = {network["id"]: network for network in wifi["networks"]}
            check(networks["WifiMaster0/AccessPoint0"]["band"] == "2.4 GHz"
                  and networks["WifiMaster1/AccessPoint0"]["band"] == "5 GHz", "Wi-Fi radio band fallback")
            check(networks["WifiMaster2/AccessPoint0"]["band"] == "6 GHz"
                  and networks["WifiMaster2/AccessPoint0"]["band_source"] == "frequency", "6 GHz frequency-derived band")
            check(networks["WifiMaster4/AccessPoint0"]["band"] is None, "unknown radio band was guessed")
            check(networks["WifiMaster0/AccessPoint0"]["channel"] == 6
                  and networks["WifiMaster1/AccessPoint0"]["channel_width_mhz"] == 80, "radio channel/width inheritance")
            check(networks["WifiMaster0/AccessPoint0"]["clients"] == networks["WifiMaster1/AccessPoint0"]["clients"] == 1,
                  "Wi-Fi client counts mixed bands, duplicates, or offline devices")
            check(networks["WifiMaster4/AccessPoint0"]["clients"] == 0, "empty AP client count")
            check("wifi-password-must-not-leak" not in result.stdout and "wpa-psk" not in result.stdout,
                  "Wi-Fi JSON leaked authentication credentials")
            all_wifi = json.loads(run(config, "--all", "--json", subcommand="wifi").stdout)["networks"]
            check(len(all_wifi) == 7, "--all omitted inactive Wi-Fi networks or included radio/station interfaces")
            statuses = {network["ssid"]: network["status"] for network in all_wifi}
            check(statuses["Guest"] == statuses["Radio disabled"] == "disabled" and statuses["Link down"] == "link down",
                  "Wi-Fi administrative or link state")
            for columns in (20, 32, 40, 60, 80, 120):
                listed = run(config, "--all", "--color=always", subcommand="wifi", extra_env={"COLUMNS": str(columns)})
                clean = ANSI.sub("", listed.stdout)
                check(listed.returncode == 0 and all(display_width(line) <= columns for line in clean.splitlines()),
                      f"Wi-Fi output exceeds {columns} columns: {listed.stderr}")
                check("STATUS" in clean and "WPA2" in clean and "Open" in clean, "Wi-Fi status/security display")
                check("wifi-password-must-not-leak" not in clean, "Wi-Fi table leaked a password")
            before_ssid = STATE.interfaces["WifiMaster2/AccessPoint0"]["ssid"]
            STATE.interfaces["WifiMaster2/AccessPoint0"]["ssid"] = "Fast network"
            wide = run(config, subcommand="wifi", extra_env={"COLUMNS": "200"}).stdout.splitlines()
            check(len(wide) == 6 and max(map(display_width, wide)) < 100, "Wi-Fi table stretches to screen width")
            status_column = wide[1].index("STATUS")
            check(all(display_width(row[:row.index("active")]) == status_column for row in wide[2:]),
                  "Wi-Fi status columns misaligned")
            STATE.interfaces["WifiMaster2/AccessPoint0"]["ssid"] = before_ssid
            check(before_posts == (len(STATE.stats_posts), len(STATE.interface_posts), len(STATE.host_posts)), "Wi-Fi listing sent a POST")
            report(index, "Wi-Fi networks, radio metadata, security, client counts, and responsive tables"); index += 1

            for code, data in ((404, []), (200, {})):
                STATE.clients_status, STATE.clients = code, data
                result = run(config, "--json", subcommand="wifi")
                check(result.returncode == 0 and all(network["clients"] is None for network in json.loads(result.stdout)["networks"])
                      and "counts unavailable" in result.stderr, "unavailable Wi-Fi counts became zero")
            STATE.clients_status, STATE.clients = 200, saved_wifi_clients
            STATE.interfaces = {"WifiMaster4/AccessPoint0": {"type": "AccessPoint"}}
            check("No active Wi-Fi networks" in run(config, subcommand="wifi").stdout, "Wi-Fi unknown status default filter")
            unknown = json.loads(run(config, "--all", "--json", subcommand="wifi").stdout)["networks"][0]
            check(unknown["ssid"] is None and unknown["channel"] is None and unknown["status"] == "unknown",
                  "missing Wi-Fi fields were fabricated")
            STATE.interfaces = {}
            check("No Wi-Fi networks found" in run(config, "--all", subcommand="wifi").stdout, "empty Wi-Fi inventory")
            for data in ([], {"WifiMaster0": "invalid"}, {"status": [{"status": "error"}]}):
                STATE.interfaces = data
                result = run(config, "--json", subcommand="wifi")
                check(result.returncode == 1 and not result.stdout, "malformed Wi-Fi response accepted")
            STATE.interface_status = 404
            result = run(config, subcommand="wifi")
            check(result.returncode == 1 and "HTTP 404" in result.stderr, "unsupported Wi-Fi interface API")
            STATE.interface_status, STATE.interfaces = 200, saved_wifi_interfaces
            report(index, "Wi-Fi unavailable counts, missing metadata, empty inventory, and API errors"); index += 1

            root_listing = run(config, subcommand=None).stdout
            listed = run(config, subcommand="interfaces")
            check(listed.returncode == 0 and listed.stdout == root_listing.split("\n\n", 1)[1],
                  listed.stderr or "interfaces output differs from root interface table")
            listed_json = json.loads(run(config, "--all", "--json", subcommand="interfaces").stdout)
            root_json = json.loads(run(config, "--all", "--json", subcommand=None).stdout)
            check(listed_json == {key: root_json[key] for key in ("router", "interfaces")},
                  "interfaces JSON differs from root interface data")
            check("must-not-be-output" not in json.dumps(listed_json), "interface listing leaked VPN secrets")
            check(not STATE.interface_posts, "listing mutated interfaces")
            nonterminal = run(config, "--interactive", subcommand="interfaces")
            check(nonterminal.returncode == 1 and "requires a terminal" in nonterminal.stderr,
                  "nonterminal interface selection did not fail")
            report(index, "interfaces subcommand listing, JSON, and terminal requirement"); index += 1

            interface_fzf = temp / "interface-fzf"
            interface_capture = temp / "interface-menu"
            interface_fzf.write_text(
                "#!/usr/bin/env bash\n"
                "input=$(cat)\n"
                "if [[ $* == *'Interface> '* ]]; then\n"
                "  printf '%s\\n' \"$input\" > \"$TEST_INTERFACE_CAPTURE\"\n"
                "  [[ $TEST_INTERFACE != cancel ]] || exit 130\n"
                "  if [[ $TEST_INTERFACE == invalid ]]; then printf '999999\\tinvalid\\n'; exit; fi\n"
                "  while IFS= read -r row; do\n"
                "    if [[ $row == *$'\\t'\"$TEST_INTERFACE \"* ]]; then printf '%s\\n' \"$row\"; exit; fi\n"
                "  done <<< \"$input\"\n"
                "  exit 1\n"
                "else\n"
                "  [[ $TEST_INTERFACE_ACTION != escape ]] || exit 130\n"
                "  printf '%s\\taction\\n' \"$TEST_INTERFACE_ACTION\"\n"
                "fi\n"
            )
            interface_fzf.chmod(0o700)

            def interface_action(ident, action, *args):
                process, master = start_pty(config, "--interactive", *args, subcommand="interfaces",
                    extra_env={"KEENETIC_FZF": str(interface_fzf), "TEST_INTERFACE": ident,
                               "TEST_INTERFACE_ACTION": action, "TEST_INTERFACE_CAPTURE": str(interface_capture)})
                output = finish_pty(process, master)
                return process.returncode, output

            saved_interfaces = json.loads(json.dumps(STATE.interfaces))
            before_posts = len(STATE.interface_posts)
            for ident, action in (("cancel", "up"), ("Proxy0", "cancel"), ("Proxy0", "escape")):
                code, output = interface_action(ident, action)
                check(code == 0 and "No changes made" in output, "interface selection cancellation")
            code, output = interface_action("Proxy0", "up", "--dry-run")
            check(code == 0 and "Would set interface Proxy0 administratively up" in output, output)
            check("Proxy0" in interface_capture.read_text() and "disabled" in interface_capture.read_text(),
                  "interactive interface list hid disabled interfaces")
            check(len(STATE.interface_posts) == before_posts, "cancel or dry run mutated interfaces")
            code, output = interface_action("invalid", "up")
            check(code == 1 and "unknown interface selection" in output, output)
            code, output = interface_action("Proxy0", "invalid")
            check(code == 1 and "unknown interface action" in output, output)
            check(len(STATE.interface_posts) == before_posts, "invalid selection mutated interfaces")
            STATE.interface_delay_reads = 2
            before_gets = STATE.interface_gets
            code, output = interface_action("Proxy0", "up")
            check(code == 0 and "Applied and verified" in output and "status: disconnected" in output, output)
            check(STATE.interface_posts[-1] == {"interface": {"Proxy0": {"up": True}}}, "connect payload")
            check(STATE.interface_gets - before_gets >= 5, "interface verification did not retry")
            STATE.interface_delay_reads = 0
            before_posts = len(STATE.interface_posts)
            code, output = interface_action("Proxy0", "up")
            check(code == 0 and "already administratively up" in output
                  and len(STATE.interface_posts) == before_posts, "idempotent interface enable")
            code, output = interface_action("Wireguard0", "down")
            check(code == 0 and "administratively down (status: disabled)" in output, output)
            check(STATE.interface_posts[-1] == {"interface": {"Wireguard0": {"up": {"no": True}}}},
                  "disconnect payload")
            code, output = interface_action("GigabitEthernet1/0", "down")
            check(code == 0 and "GigabitEthernet1/0" in output, output)
            check(STATE.interface_posts[-1] == {"interface": {"GigabitEthernet1/0": {"up": {"no": True}}}},
                  "slash-containing interface ID changed")
            report(index, "fzf interface actions, cancellation, dry run, and verified state changes"); index += 1

            STATE.interfaces = json.loads(json.dumps(saved_interfaces))
            STATE.interface_drop_updates = True
            for response, status in (({"interface": {"Proxy0": {"status": [{"status": "error"}]}}}, 200),
                                     ({"message": "denied"}, 403), ([], 200)):
                STATE.interface_reply, STATE.interface_post_status = response, status
                code, output = interface_action("Proxy0", "up")
                check(code == 1 and "Applied and verified" not in output, output)
            STATE.interface_reply = {"status": [{"status": "message", "message": "Interface updated."}]}
            STATE.interface_post_status = 200
            code, output = interface_action("Proxy0", "up")
            check(code == 5 and "could not verify" in output, output)
            STATE.interface_drop_updates = False
            before_posts = len(STATE.interface_posts)
            STATE.remove_interface_on_get = (STATE.interface_gets + 2, "Proxy0")
            code, output = interface_action("Proxy0", "up")
            check(code == 1 and "no longer available" in output and len(STATE.interface_posts) == before_posts,
                  "stale interface selection was applied")
            STATE.interfaces = json.loads(json.dumps(saved_interfaces))
            report(index, "interface command errors, failed verification, and stale selections"); index += 1

            native_interface_env = {"KEENETIC_FZF": "keenetic-fzf-not-installed", "COLUMNS": ""}
            process, master = start_pty(config, "--interactive", subcommand="interfaces", columns=40,
                                        extra_env=native_interface_env)
            first = read_pty(master, "Esc/q to cancel") + read_pty(master, timeout=0.4)
            option_lines = [ANSI.sub("", line).replace("\r", "") for line in first.splitlines()]
            option_lines = [line for line in option_lines if line.startswith(("> ", "  "))]
            check(option_lines and all(display_width(line) <= 40 for line in option_lines),
                  "native interface menu exceeds terminal width")
            fcntl.ioctl(master, *termios_size(24, 20))
            os.kill(process.pid, signal.SIGWINCH)
            resized = read_pty(master, timeout=0.4)
            check("disabled" in resized, "interface menu did not redraw on resize")
            os.write(master, b"\x1b[B\r")  # Proxy0 follows OpenVPN0.
            read_pty(master, "Interface: Proxy0")
            os.write(master, b"\r")
            output = finish_pty(process, master)
            check(process.returncode == 0 and STATE.interfaces["Proxy0"]["state"] == "up", output)
            STATE.interfaces = saved_interfaces
            report(index, "native interface selection, resizing, and connect action"); index += 1

            result = run(config)
            check(result.returncode == 0, result.stderr)
            check("* Workstation (this device)" in result.stdout, "local MAC fallback")
            check("设备客户端" not in result.stdout, "offline client leaked")
            check(STATE.authenticated_requests > 0, "challenge authentication was not used")
            report(index, "authentication, listing, and local MAC fallback"); index += 1

            clients = json.loads(run(config, "--json").stdout)
            check(len(clients) == 4 and all(client["online"] for client in clients), "connected JSON contract")
            all_clients = json.loads(run(config, "--all", "--json").stdout)
            check(len(all_clients) == 5 and any(not client["online"] for client in all_clients), "all JSON contract")
            offline = run(config, "--offline")
            check("设备客户端" in offline.stdout and "offline" in offline.stdout
                  and "(offline)" not in offline.stdout and "Laptop" not in offline.stdout, "offline listing")
            report(index, "connected, all, and offline listing modes"); index += 1

            table = run(config, "--all", extra_env={"COLUMNS": "80"}).stdout.splitlines()
            check(len(table) == 6 and "IP ADDRESS" in table[0], "policy table header or row count")
            ip_column = table[0].index("IP ADDRESS")
            policy_column = table[0].index("POLICY")
            status_column = table[0].index("STATUS")
            check(max(map(display_width, table)) < 80, "policy table stretched beyond its content")
            for row in table[1:]:
                address = re.search(r"192\.0\.2\.\d+", row)
                policy = re.search(r"(?:Default|Direct|VPN)\s+", row)
                status = re.search(r"(?:online|offline)\s*$", row)
                check(address and display_width(row[:address.start()]) == ip_column,
                      "policy IP column is misaligned")
                check(policy and display_width(row[:policy.start()]) == policy_column,
                      "policy label column is misaligned")
                check(status and display_width(row[:status.start()]) == status_column,
                      "policy status column is misaligned")
                check(status.group().strip() == ("offline" if "设备客户端" in row else "online"),
                      "incorrect client status")
            original_client = STATE.clients[0].copy()
            original_policy = STATE.policies["Policy1"]["description"]
            STATE.clients[0].update(name=long_name, ip=long_ip.split("/")[0])
            STATE.policies["Policy1"]["description"] = "家庭 VPN " + "x" * 50
            for columns in (20, 32, 40, 60, 80, 120):
                result = run(config, "--all", "--color=always", extra_env={"COLUMNS": str(columns)})
                check(result.returncode == 0, result.stderr)
                clean = ANSI.sub("", result.stdout)
                check(all(display_width(line) <= columns for line in clean.splitlines()),
                      f"policy output exceeds {columns} columns")
                check("…" in clean and not any(char in clean for char in "╭├╰│"),
                      "policy output lost compact formatting")
                check("STATUS" in clean and len(re.findall(r"\bonline\s*$", clean, re.M)) == 4
                      and len(re.findall(r"\boffline\s*$", clean, re.M)) == 1,
                      "policy status column missing on narrow screens")
                if columns < 72:
                    check(STATE.clients[0]["ip"] in "".join(clean.split()), "narrow policy list lost IP")
            full = json.loads(run(config, "--json", extra_env={"COLUMNS": "20"}).stdout)
            check(any(client["name"] == long_name and client["ip"] == STATE.clients[0]["ip"] for client in full),
                  "policy JSON truncated client data")
            STATE.clients[0] = original_client
            STATE.policies["Policy1"]["description"] = original_policy
            report(index, "compact responsive policy rows and Unicode column alignment"); index += 1

            password_helper = temp / "password-helper"
            password_helper.write_text("#!/usr/bin/env bash\nprintf secret\n")
            password_helper.chmod(0o700)
            command_config = temp / "command-config"
            command_config.write_text(f"ROUTER_URL={url}\nROUTER_USERNAME={USERNAME}\nROUTER_PASSWORD_COMMAND={password_helper}\n")
            command_config.chmod(0o600)
            password_file = temp / "router-password"
            password_file.write_text("secret\n")
            password_file.chmod(0o600)
            file_config = temp / "file-config"
            file_config.write_text(f"ROUTER_URL={url}\nROUTER_USERNAME={USERNAME}\nROUTER_PASSWORD_FILE={password_file}\n")
            file_config.chmod(0o600)
            check(run(command_config, "--json").returncode == 0, "password command")
            check(run(file_config, "--json").returncode == 0, "password file")
            report(index, "command and file password retrieval"); index += 1

            posts = len(STATE.host_posts)
            result = run(config, "--client", "Laptop", "--policy", "VPN", "--dry-run")
            check(result.returncode == 0 and "Plan" in result.stdout and "Would set" in result.stdout, result.stderr)
            check(len(STATE.host_posts) == posts, "dry run posted a mutation")
            verbose = run(config, "--json", "--verbose")
            check("Debug: GET /auth" in verbose.stderr and "Debug: Clients:" in verbose.stderr, "verbose diagnostics")
            check(PASSWORD not in verbose.stderr and CHALLENGE not in verbose.stderr, "verbose output leaked a secret")
            report(index, "dry-run plan and sanitized verbose diagnostics"); index += 1

            STATE.assignments["02:00:00:00:00:10"] = {"policy": False, "deny": False}
            STATE.delay_next_update_reads = 2
            before_gets = STATE.assignment_gets
            result = run(config, "--client", "Laptop", "--policy", "VPN")
            check(result.returncode == 0 and "Applied and verified" in result.stdout, result.stderr)
            check(STATE.assignment_gets - before_gets >= 4, "verification did not retry")
            report(index, "bounded eventual-consistency verification retries"); index += 1

            STATE.assignments["02:00:00:00:00:10"] = {"policy": False, "deny": False}
            STATE.assignments["02:00:00:00:00:20"] = {"policy": False, "deny": False}
            posts = len(STATE.host_posts)
            missing = run(config, "--client", "Laptop", "--client", "Missing", "--policy", "VPN")
            check(missing.returncode == 3 and len(STATE.host_posts) == posts, "batch preflight mutated before failure")
            batch = run(config, "--client", "Laptop", "--ip", "192.0.2.20", "--policy", "VPN")
            check(batch.returncode == 0 and "Plan (2 clients)" in batch.stdout, batch.stderr)
            check(STATE.assignments["02:00:00:00:00:10"]["policy"] == "Policy1", "batch first client")
            check(STATE.assignments["02:00:00:00:00:20"]["policy"] == "Policy1", "batch second client")
            report(index, "preflighted multi-client batch assignment"); index += 1

            STATE.assignments["02:00:00:00:00:10"] = {"policy": False, "deny": False}
            STATE.assignments["02:00:00:00:00:20"] = {"policy": False, "deny": False}
            STATE.fail_mac_once = "02:00:00:00:00:20"
            partial = run(config, "--client", "Laptop", "--ip", "192.0.2.20", "--policy", "VPN")
            check(partial.returncode == 1 and "1 already completed" in partial.stderr, "partial failure context")
            check(STATE.assignments["02:00:00:00:00:10"]["policy"] == "Policy1", "partial first mutation")
            check(STATE.assignments["02:00:00:00:00:20"]["policy"] is False, "partial failed mutation")
            report(index, "precise non-atomic batch failure reporting"); index += 1

            blocked = run(config, "--client", "Laptop", "--block")
            check(blocked.returncode == 0 and STATE.assignments["02:00:00:00:00:10"]["deny"], blocked.stderr)
            unblocked = run(config, "--client", "Laptop", "--unblock")
            check(unblocked.returncode == 0 and not STATE.assignments["02:00:00:00:00:10"]["deny"], unblocked.stderr)
            wake = run(config, "--client", "设备客户端", subcommand="wake")
            check(wake.returncode == 0 and "magic packet queued" in wake.stdout, wake.stderr)
            check(STATE.wake_posts[-1]["mac"] == "02:00:00:00:00:60", "offline wake target")
            report(index, "block, unblock, and offline Wake-on-LAN actions"); index += 1

            wake_posts = len(STATE.wake_posts)
            host_posts = len(STATE.host_posts)
            history_before_wake = (temp / "history.json").read_bytes()
            preview = run(config, "--client", "Laptop", "--mac", "02:00:00:00:00:10",
                          "--client", "设备客户端", "--dry-run", subcommand="wake")
            check(preview.returncode == 0 and "Plan (2 clients)" in preview.stdout, preview.stderr)
            check(len(STATE.wake_posts) == wake_posts, "wake dry-run sent a request")
            missing_wake = run(config, "--client", "Laptop", "--client", "Missing", subcommand="wake")
            check(missing_wake.returncode == 3 and len(STATE.wake_posts) == wake_posts,
                  "wake batch mutated before preflight completed")
            batch_wake = run(config, "--client", "Laptop", "--mac", "02:00:00:00:00:10",
                             "--client", "设备客户端", subcommand="wake")
            check(batch_wake.returncode == 0 and len(STATE.wake_posts) == wake_posts + 2, batch_wake.stderr)
            check(len(STATE.host_posts) == host_posts, "wake changed client policy")
            check((temp / "history.json").read_bytes() == history_before_wake, "wake changed undo history")
            report(index, "wake subcommand batch preflight, deduplication, and dry-run"); index += 1

            for args in (
                ("--verbose", "--no-color", "policy", "--json"),
                ("policy", "--json", "--verbose", "--no-color"),
            ):
                listed = run(config, *args, subcommand=None)
                check(listed.returncode == 0 and len(json.loads(listed.stdout)) == 4, listed.stderr)
                check("Debug: Clients:" in listed.stderr and "\x1b[" not in listed.stderr,
                      "global diagnostics or color option was not applied")
            for args in (
                ("--quiet", "wake", "--client", "Laptop"),
                ("wake", "--client", "Laptop", "--quiet"),
            ):
                quiet_wake = run(config, *args, subcommand=None)
                check(quiet_wake.returncode == 0 and not quiet_wake.stdout, quiet_wake.stderr)
            # Literal selectors that look like commands or global flags stay values.
            for args in (("wake", "--client", "policy"), ("wake", "--", "--verbose")):
                missing_literal = run(config, *args, subcommand=None)
                check(missing_literal.returncode == 3, missing_literal.stderr)
            report(index, "global options before and after subcommands and literal selectors"); index += 1

            history = temp / "rollback.json"
            history.write_text(json.dumps([
                {
                    "router": "http://other-router",
                    "mac": "02:00:00:00:ff:ff",
                    "name": f"old-{number}",
                    "action": "policy",
                    "timestamp": "2026-01-01T00:00:00Z",
                    "before": {"policy": False, "deny": False},
                    "after": {"policy": "Policy0", "deny": False},
                }
                for number in range(20)
            ]))
            STATE.assignments["02:00:00:00:00:10"] = {"policy": False, "deny": False}
            changed = run(config, "--client", "Laptop", "--policy", "Direct", extra_env={"KEENETIC_STATE_FILE": str(history)})
            check(changed.returncode == 0 and history.exists(), changed.stderr)
            entries = json.loads(history.read_text())
            check(len(entries) == 20 and entries[0]["name"] == "old-1", "rollback history bound")
            check(entries[-1]["before"] == {"policy": False, "deny": False}, "rollback before state")
            undone = run(config, "--undo", extra_env={"KEENETIC_STATE_FILE": str(history)})
            check(undone.returncode == 0 and STATE.assignments["02:00:00:00:00:10"]["policy"] is False, undone.stderr)
            remaining = json.loads(history.read_text())
            check(len(remaining) == 19 and all(entry["router"] == "http://other-router" for entry in remaining),
                  "rollback entry was not consumed")
            report(index, "bounded local rollback history and undo"); index += 1

            check(run(config, "--bad-option").returncode == 2, "usage exit code")
            check(run(config, "--client", "Missing", "--policy", "VPN").returncode == 3, "client exit code")
            check(run(config, "--client", "Laptop", "--policy", "Missing").returncode == 4, "policy exit code")
            STATE.assignments["02:00:00:00:00:20"] = {"policy": "Policy1", "deny": False}
            STATE.drop_next_update = True
            failed_verify = run(config, "--ip", "192.0.2.20", "--policy", "Direct")
            check(failed_verify.returncode == 5 and "4 checks over 1 second" in failed_verify.stderr, "verification exit code")
            report(index, "stable documented exit codes"); index += 1

            fake_fzf = temp / "fake-fzf"
            fzf_count = temp / "fzf-count"
            fzf_capture = temp / "fzf-input"
            fake_fzf.write_text(
                "#!/usr/bin/env bash\n"
                "input=$(cat)\n"
                "count=0\n"
                "[[ ! -r $FZF_COUNT_FILE ]] || read -r count < \"$FZF_COUNT_FILE\"\n"
                "printf '%s\\n' \"$input\" > \"$FZF_CAPTURE_FILE.$count\"\n"
                "printf '%s\\n' \"$((count + 1))\" > \"$FZF_COUNT_FILE\"\n"
                "printf '%s\\n' \"${input%%$'\\n'*}\"\n"
            )
            fake_fzf.chmod(0o700)
            process, master = start_pty(
                config, "--interactive",
                extra_env={
                    "KEENETIC_FZF": str(fake_fzf),
                    "FZF_COUNT_FILE": str(fzf_count),
                    "FZF_CAPTURE_FILE": str(fzf_capture),
                },
            )
            finish_pty(process, master)
            check(process.returncode == 0 and fzf_count.read_text().strip() == "2",
                  "fzf was not used for both menus")
            client_rows = [line.split("\t", 1)[1] for line in Path(f"{fzf_capture}.0").read_text().splitlines()]
            ip_columns = {row.index("192.0.2.") for row in client_rows}
            policy_columns = {
                min(position for label in ("Default", "Direct", "VPN")
                    if (position := row.find(label)) >= 0)
                for row in client_rows
            }
            status_columns = {row.rfind("online") for row in client_rows}
            check(len(ip_columns) == len(policy_columns) == len(status_columns) == 1,
                  "fzf client columns are not aligned")
            report(index, "fzf interactive search with aligned columns"); index += 1

            native_env = {"KEENETIC_FZF": "keenetic-fzf-not-installed"}
            process, master = start_pty(config, "--all", "--interactive", columns=40, extra_env=native_env)
            first = read_pty(master, "Esc/q to cancel") + read_pty(master, timeout=0.4)
            clean_lines = [ANSI.sub("", line).replace("\r", "") for line in first.splitlines()]
            option_lines = [line for line in clean_lines if line.startswith(("> ", "  "))]
            check(option_lines and max(map(display_width, option_lines)) <= 40, "Unicode narrow terminal overflow")
            fcntl.ioctl(master, *termios_size(24, 32))
            os.kill(process.pid, signal.SIGWINCH)
            resized = read_pty(master, timeout=0.5)
            check("Workstation" in resized or "设备" in resized, "resize did not redraw menu")
            os.write(master, b"\r")
            read_pty(master, "Current policy:")
            os.write(master, b"\x1b")
            finish_pty(process, master)
            check(process.returncode == 0, "native resize and Escape cancellation")
            report(index, "Unicode-safe native TUI resizing"); index += 1

            process, master = start_pty(config, "Phone", columns=80, extra_env=native_env)
            read_pty(master, "Esc/q to cancel")
            os.write(master, b"\x1b[B\r")
            read_pty(master, "Current policy:")
            os.write(master, b"\x1b[A\r")
            finish_pty(process, master)
            check(process.returncode == 0, "arrow policy selection")
            check(STATE.host_posts[-1]["mac"] == "02:00:00:00:00:21", "duplicate arrow client")
            check(STATE.host_posts[-1]["policy"] == "Policy0", "arrow policy")
            report(index, "native arrow fallback and duplicate disambiguation"); index += 1

            init_path = temp / "initialized" / "config"
            init_input = f"{url}\n{USERNAME}\n\n\n{PASSWORD}\n{PASSWORD}\n"
            initialized = run(init_path, "--init", input_text=init_input, subcommand=None)
            check(initialized.returncode == 0, initialized.stderr)
            check(stat.S_IMODE(init_path.stat().st_mode) == 0o600, "initialized config mode")
            check("ROUTER_INSECURE=false" in init_path.read_text(), "TLS setting not saved")
            report(index, "secure guided configuration"); index += 1

            config_home = temp / "config-home"
            profile = config_home / "keenetic-policy" / "routers" / "home"
            profile.parent.mkdir(parents=True)
            profile.write_text(config.read_text())
            profile.chmod(0o600)
            profile_env = base_env()
            profile_env.update({"XDG_CONFIG_HOME": str(config_home), "KEENETIC_STATE_FILE": str(temp / "profile-history")})
            for args in (
                ("--router", "home", "policy", "--json"),
                ("policy", "--router=home", "--json"),
                ("--router=home", "wake", "--client", "Laptop", "--dry-run"),
                ("wake", "--router", "home", "--client", "Laptop", "--dry-run"),
            ):
                profiled = subprocess.run([str(SCRIPT), *args], cwd=ROOT, env=profile_env,
                                          text=True, capture_output=True, timeout=12)
                check(profiled.returncode == 0, profiled.stderr)
                if "--json" in args:
                    check(len(json.loads(profiled.stdout)) == 4, "profile listing")
                else:
                    check("Would wake Laptop" in profiled.stdout, "profile wake")
            command_named_profile = profile.parent / "policy"
            profiled_status = subprocess.run([str(SCRIPT), "--router", "home", "--json"],
                                            cwd=ROOT, env=profile_env, text=True, capture_output=True, timeout=12)
            check(profiled_status.returncode == 0 and json.loads(profiled_status.stdout)["router"] == url,
                  profiled_status.stderr)
            command_named_profile.write_text(config.read_text())
            command_named_profile.chmod(0o600)
            profiled = subprocess.run([str(SCRIPT), "--router", "policy", "policy", "--json"],
                                      cwd=ROOT, env=profile_env, text=True, capture_output=True, timeout=12)
            check(profiled.returncode == 0 and len(json.loads(profiled.stdout)) == 4, profiled.stderr)

            initialized_profile = subprocess.run(
                [str(SCRIPT), "--router", "office", "--init"], cwd=ROOT, env=profile_env,
                input=init_input, text=True, capture_output=True, timeout=12,
            )
            check(initialized_profile.returncode == 0, initialized_profile.stderr)
            office_profile = profile.parent / "office"
            check(stat.S_IMODE(office_profile.stat().st_mode) == 0o600, "initialized profile mode")

            fake_bin = temp / "discover-bin"
            fake_bin.mkdir()
            (fake_bin / "ip").write_text("#!/usr/bin/env bash\nprintf '%s\\n' '[{\"gateway\":\"192.0.2.1\",\"metric\":100}]'\n")
            (fake_bin / "curl").write_text("#!/usr/bin/env bash\nprintf 401\n")
            (fake_bin / "ip").chmod(0o700)
            (fake_bin / "curl").chmod(0o700)
            discover_env = base_env()
            discover_env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
            discovered = subprocess.run([str(SCRIPT), "--discover"], cwd=ROOT, env=discover_env,
                                        text=True, capture_output=True, timeout=5)
            check(discovered.returncode == 0 and discovered.stdout.strip() == "http://192.0.2.1", discovered.stderr)
            report(index, "named profiles and default-gateway discovery"); index += 1

            check(subprocess.run(["openssl", "version"], capture_output=True).returncode == 0, "openssl unavailable")
            tls_server, tls_thread, ca_cert = make_tls_server(temp)
            tls_url = f"https://127.0.0.1:{tls_server.server_port}"
            tls_config = temp / "tls-config"
            tls_config.write_text(f"ROUTER_URL={tls_url}\nROUTER_USERNAME={USERNAME}\nROUTER_PASSWORD={PASSWORD}\n")
            tls_config.chmod(0o600)
            trusted = run(tls_config, "--ca-file", str(ca_cert), "--json")
            check(trusted.returncode == 0 and len(json.loads(trusted.stdout)) == 4, trusted.stderr)
            trusted_status = run(tls_config, "--ca-file", str(ca_cert), "--json", subcommand=None)
            check(trusted_status.returncode == 0 and json.loads(trusted_status.stdout)["router"] == tls_url,
                  trusted_status.stderr)
            trusted_prefix = run(tls_config, "--ca-file", str(ca_cert), "policy", "--json", subcommand=None)
            check(trusted_prefix.returncode == 0 and len(json.loads(trusted_prefix.stdout)) == 4,
                  trusted_prefix.stderr)
            secure_wake = run(tls_config, "--ca-file", str(ca_cert), "wake", "--client", "Laptop",
                              subcommand=None)
            check(secure_wake.returncode == 0 and "magic packet queued" in secure_wake.stdout, secure_wake.stderr)
            untrusted = run(tls_config, "--json")
            check(untrusted.returncode == 1 and "TLS" in untrusted.stderr,
                  f"untrusted TLS result: rc={untrusted.returncode}, stderr={untrusted.stderr!r}")
            insecure = run(tls_config, "--insecure", "--json")
            check(insecure.returncode == 0 and "certificate verification is disabled" in insecure.stderr, insecure.stderr)
            insecure_prefix = run(tls_config, "--insecure", "policy", "--json", subcommand=None)
            check(insecure_prefix.returncode == 0 and "certificate verification is disabled" in insecure_prefix.stderr,
                  insecure_prefix.stderr)
            check(run(tls_config, "--ca-file", str(ca_cert), "--insecure").returncode == 2, "TLS conflict")
            report(index, "real HTTPS trust, custom CA, and insecure transport"); index += 1

            # New status commands use whitelisted payloads and the same responsive renderer.
            system = run(config, "--json", subcommand="system")
            check(system.returncode == 0, system.stderr)
            health = json.loads(system.stdout)
            check(health["memory"]["used_bytes"] == 128 * 1024 and health["uptime_seconds"] == 90061,
                  "system units")
            check(health["connections"]["used"] == 100 and "must-not-be-output" not in system.stdout,
                  "system whitelist")
            original_system = STATE.system
            STATE.system = {"status": [{"status": "error"}]}
            check(run(config, "--json", subcommand="system").returncode != 0, "invalid system accepted")
            STATE.system = original_system
            report(index, "system health units and malformed data"); index += 1

            original_interfaces = json.loads(json.dumps(STATE.interfaces))
            STATE.interfaces["Wireguard0"]["wireguard"]["peer"] = [
                {"description": "Amsterdam", "remote-endpoint-address": "2001:db8::2", "remote-port": 51820,
                 "last-handshake": 49, "rxbytes": 1024, "txbytes": 2048, "online": True,
                 "preshared-key": "must-not-be-output"},
                {"enabled": False, "online": True}]
            peers = run(config, "peers", "--json", subcommand="vpn")
            check(peers.returncode == 0, peers.stderr)
            rows = json.loads(peers.stdout)["peers"]
            check(rows[0]["handshake_age_seconds"] == 49 and rows[1]["status"] == "disabled", "peer status/age")
            check("must-not-be-output" not in peers.stdout, "VPN secret leaked")
            check("[2001:db8::2]:51820" in run(config, "peers", subcommand="vpn", extra_env={"COLUMNS": "160"}).stdout,
                  "IPv6 peer endpoint")
            report(index, "WireGuard peer age, status, IPv6, and secret exclusion"); index += 1

            STATE.interfaces["WifiMaster1"] = {"type": "WifiMaster", "state": "up", "channel": 37,
                                               "bandwidth": 80, "frequency": 6115}
            radio = run(config, "monitor", "--json", subcommand="wifi")
            check(radio.returncode == 0, radio.stderr)
            row = next(r for r in json.loads(radio.stdout)["radios"] if r["id"] == "WifiMaster1")
            check(row["samples"] == 2 and row["current_percent"] == 20 and row["average_percent"] == 30
                  and row["peak_percent"] == 40, "radio rolling window")
            original_load = STATE.radio_load
            STATE.radio_load = {"data": []}
            empty = run(config, "monitor", "--json", subcommand="wifi")
            check(empty.returncode == 0 and json.loads(empty.stdout)["radios"][0]["current_percent"] is None,
                  "empty radio samples")
            STATE.radio_load = original_load
            report(index, "Wi-Fi utilization window and missing samples"); index += 1

            inspected = run(config, "inspect", "192.0.2.10", "--json", subcommand="clients")
            check(inspected.returncode == 0, inspected.stderr)
            client = json.loads(inspected.stdout)["client"]
            check(client["mac"] == "02:00:00:00:00:10" and client["band"] == "6 GHz", "client radio enrichment")
            check(client["recent_traffic"]["window_seconds"] == 180, "client traffic")
            check(run(config, "inspect", "Phone", subcommand="clients").returncode == 3, "ambiguous client")
            check(run(config, "inspect", "absent", subcommand="clients").returncode == 3, "missing client")
            original_summary = STATE.traffic_summary
            STATE.traffic_summary = {"t": 0, "host": []}
            inspected = run(config, "inspect", "02:00:00:00:00:10", "--json", subcommand="clients")
            check(inspected.returncode == 0 and json.loads(inspected.stdout)["client"]["recent_traffic"] is None,
                  "missing traffic lost client details")
            STATE.traffic_summary = original_summary
            report(index, "client inspection selection, enrichment, and missing history"); index += 1

            STATE.policies["Policy1"]["permit"] = [{"interface": "Wireguard0", "enabled": True},
                                                      {"interface": "OpenVPN0", "no": True}]
            policy = run(config, "inspect", "VPN", "--json")
            check(policy.returncode == 0, policy.stderr)
            detail = json.loads(policy.stdout)
            check(detail["interfaces"][0]["id"] == "Wireguard0" and not detail["interfaces"][1]["enabled"],
                  "policy permit order")
            check(run(config, "inspect", "absent", "--json").returncode == 4, "unknown policy")
            check(run(config, "inspect", "default", "--json").returncode == 0, "default policy inspect")
            report(index, "policy inspection and permit order"); index += 1

            logs = run(config, "--limit", "50", "--filter", "WIREGUARD", "--json", subcommand="logs")
            check(logs.returncode == 0, logs.stderr)
            check(STATE.log_posts[-1] == {"max-lines": 50, "once": True}, "bounded log request")
            check(len(json.loads(logs.stdout)["entries"]) == 1, "case insensitive log filter")
            report(index, "bounded logs and literal filtering"); index += 1

            diagnostics = run(config, "127.0.0.1", "--interface", "Wireguard0", "--json", subcommand="diagnose")
            check(diagnostics.returncode == 0, diagnostics.stderr)
            tests = json.loads(diagnostics.stdout)["tests"]
            check(len(tests) == 2 and tests[0]["lines"] == ["started", "reply"], "diagnostic polling")
            check(STATE.diagnostic_posts[-2][1] == {"host": "127.0.0.1", "count": 4, "source": "Wireguard0"},
                  "ping payload")
            check(STATE.diagnostic_posts[-1][1] == {"host": "127.0.0.1", "count": 1, "max-ttl": 12,
                  "wait-time": 1, "source-interface": "Wireguard0"}, "traceroute payload")
            before = len(STATE.diagnostic_posts)
            check(run(config, "127.0.0.1", "--interface", "missing", subcommand="diagnose").returncode == 2,
                  "invalid source")
            check(len(STATE.diagnostic_posts) == before, "invalid source started diagnostic")
            check(run(config, "::1", "--json", subcommand="diagnose").returncode == 0, "IPv6 diagnostic")
            check(STATE.diagnostic_posts[-2][0].endswith("/ping6"), "IPv6 tool")
            STATE.diagnostic_invalid = True
            check(run(config, "127.0.0.1", subcommand="diagnose").returncode != 0, "malformed diagnostic")
            check(STATE.diagnostic_cancelled[-1] == "/rci/tools/ping", "failed diagnostic cancellation")
            STATE.diagnostic_invalid = False
            report(index, "router diagnostics, polling, validation, and failure cleanup"); index += 1

            before = STATE.authenticated_requests
            process = subprocess.Popen([str(SCRIPT), "system", "--watch", "1", "--json"],
                                       env=base_env(config), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                snapshots = []
                for _ in range(2):
                    check(select.select([process.stdout], [], [], 8)[0], "watch snapshot timeout")
                    snapshots.append(json.loads(process.stdout.readline()))
                check(snapshots[0]["hostname"] == snapshots[1]["hostname"] == "Router", "watch NDJSON")
            finally:
                process.send_signal(signal.SIGINT)
                process.communicate(timeout=8)
            check(process.returncode == 130 and STATE.authenticated_requests == before + 1, "watch session reuse/interrupt")
            for command, args in [("system", ["--watch", "0", "--json"]),
                                  ("system", ["--watch", "1"]), ("system", ["--watch", "1.5", "--json"]),
                                  ("policy", ["--watch", "1", "--policy", "VPN", "Laptop"]),
                                  ("diagnose", ["127.0.0.1", "--watch", "1", "--json"]),
                                  ("logs", ["--limit", "0"]), ("system", ["--all"])]:
                check(run(config, *args, subcommand=command).returncode == 2, f"invalid options {command} {args}")
            process, master = start_pty(config, "--watch", "1", subcommand="system", columns=40)
            output = read_pty(master, marker="Router health", timeout=8)
            process.send_signal(signal.SIGINT)
            output += finish_pty(process, master)
            check(process.returncode == 130 and "\x1b[?1049h" in output and "\x1b[?1049l" in output
                  and "\x1b[?25h" in output, "watch terminal restoration")
            report(index, "watch NDJSON, authentication reuse, option guards, and terminal restoration"); index += 1

            for width in (20, 40, 80, 120):
                for command, args in [("system", []), ("vpn", ["peers"]), ("wifi", ["monitor"]),
                                      ("clients", ["inspect", "Laptop"]), ("policy", ["inspect", "VPN"]),
                                      ("logs", [])]:
                    result = run(config, *args, subcommand=command, extra_env={"COLUMNS": str(width)})
                    check(result.returncode == 0, result.stderr)
                    check(all(display_width(ANSI.sub("", line)) <= width for line in result.stdout.splitlines()),
                          f"{command} overflow at {width}: {result.stdout}")
            STATE.interfaces = original_interfaces
            report(index, "responsive report widths from 20 to 120 columns"); index += 1

            for words, word_index, expected in (
                ("keenetic sys", 1, "system"),
                ("keenetic clients ins", 2, "inspect"),
                ("keenetic policy ins", 2, "inspect"),
                ("keenetic wifi mon", 2, "monitor"),
                ("keenetic vpn pe", 2, "peers"),
                ("keenetic logs --li", 2, "--limit"),
                ("keenetic diagnose --int", 2, "--interface"),
                ("keenetic system --watch 2", 3, None),
                ("keenetic pol", 1, "policy"),
                ("keenetic wa", 1, "wake"),
                ("keenetic --router home pol", 3, "policy"),
                ("keenetic --router wake pol", 3, "policy"),
                ("keenetic --router home policy --cli", 4, "--client"),
                ("keenetic int", 1, "interfaces"),
                ("keenetic tra", 1, "traffic"),
                ("keenetic wi", 1, "wifi"),
                ("keenetic wifi --al", 2, "--all"),
                ("keenetic wifi --js", 2, "--json"),
                ("keenetic wifi --int", 2, None),
                ("keenetic --router wifi wifi --js", 4, "--json"),
                ("keenetic traffic --js", 2, "--json"),
                ("keenetic traffic --to", 2, "--top"),
                ("keenetic traffic --per", 2, "--period"),
                ("keenetic traffic --period 1", 3, "1h"),
                ("keenetic traffic --period=3", 2, "--period=3h"),
                ("keenetic traffic --top 1", 3, None),
                ("keenetic traffic --top 10 --js", 4, "--json"),
                ("keenetic traffic --int", 2, None),
                ("keenetic traffic --al", 2, None),
                ("keenetic interfaces --int", 2, "--interactive"),
                ("keenetic interfaces --al", 2, "--all"),
                ("keenetic interfaces --cli", 2, None),
                ("keenetic --router interfaces interfaces --js", 4, "--json"),
                ("keenetic --verbose wake --cli", 3, "--client"),
                ("keenetic wake --dry", 2, "--dry-run"),
                ("keenetic wake --pol", 2, None),
                ("keenetic policy --wa", 2, "--watch"),
                ("keenetic policy --client wake --pol", 4, "--policy"),
                ("keenetic policy -- --ver", 3, None),
                ("keenetic --ver", 1, "--version"),
                ("keenetic --ini", 1, "--init"),
                ("keenetic --dis", 1, "--discover"),
                ("keenetic --js", 1, "--json"),
                ("keenetic --al", 1, "--all"),
                ("keenetic --init --al", 2, None),
                ("keenetic --init --js", 2, None),
                ("keenetic --init --rou", 2, "--router"),
                ("keenetic --router office --ini", 3, "--init"),
                ("keenetic policy --ini", 2, None),
                ("keenetic policy --dis", 2, None),
                ("keenetic policy --cli", 2, "--client"),
                ("keenetic policy --ver", 2, "--version"),
                ("keenetic policy --client Lap", 3, None),
                ("keenetic unknown --cli", 2, None),
            ):
                completion = subprocess.run(
                    ["bash", "-c", 'source "$1"; COMP_WORDS=(' + words + '); COMP_CWORD=' + str(word_index) + '; '
                     '_keenetic; printf "%s\\n" "${COMPREPLY[@]}"', "_",
                     str(ROOT / "completions" / "keenetic.bash")],
                    text=True, capture_output=True, timeout=5,
                )
                check(completion.returncode == 0, completion.stderr)
                if expected is None:
                    check(not completion.stdout.strip(), f"unexpected completion for {words}")
                else:
                    check(expected in completion.stdout.splitlines(), f"missing completion for {words}")
            report(index, "static Bash completion"); index += 1

        print(f"1..{index - 1}")
    finally:
        if tls_server is not None:
            tls_server.shutdown()
            tls_server.server_close()
            tls_thread.join(timeout=2)
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    main()
