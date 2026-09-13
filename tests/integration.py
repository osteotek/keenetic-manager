#!/usr/bin/env python3

import errno
import hashlib
import json
import os
import pty
import re
import select
import stat
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "keenetic-policy.sh"
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
            {"name": "Offline", "ip": "192.0.2.60", "mac": "02:00:00:00:00:60", "link": "down"},
        ]
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
        self.authenticated_requests = 0
        self.policy_posts = []
        self.ignore_next_update = False

    def assignment_list(self):
        return [{"mac": mac, **value} for mac, value in self.assignments.items()]


STATE = RouterState()


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
            self.reply(200, STATE.clients)
        elif self.path == "/rci/show/rc/ip/hotspot/host":
            self.reply(200, STATE.assignment_list())
        elif self.path == "/rci/show/rc/ip/policy":
            self.reply(200, STATE.policies)
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
        if self.path == "/rci/ip/hotspot/host" and self.authenticated():
            STATE.policy_posts.append(body)
            if STATE.ignore_next_update:
                STATE.ignore_next_update = False
            else:
                STATE.assignments[body["mac"]] = {"policy": body["policy"], "deny": False}
            self.reply(200, {"status": "ok"})
        else:
            self.reply(404, {"message": "not found"})


def run(config, *args, input_text=None, extra_env=None):
    env = os.environ.copy()
    env["KEENETIC_CONFIG"] = str(config)
    env["NO_COLOR"] = "1"
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [str(SCRIPT), *args],
        cwd=ROOT,
        env=env,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=10,
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


def start_pty(config, *args, columns=80):
    master, slave = pty.openpty()
    env = os.environ.copy()
    env.update({
        "KEENETIC_CONFIG": str(config),
        "NO_COLOR": "1",
        "COLUMNS": str(columns),
    })
    process = subprocess.Popen(
        [str(SCRIPT), *args],
        cwd=ROOT,
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
    )
    os.close(slave)
    return process, master


def finish_pty(process, master):
    output = read_pty(master, timeout=2)
    process.wait(timeout=5)
    os.close(master)
    return output


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def report(index, name):
    print(f"ok {index} - {name}")


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}"

    try:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            config = temp / "config"
            config.write_text(
                f"ROUTER_URL={url}\nROUTER_USERNAME={USERNAME}\nROUTER_PASSWORD={PASSWORD}\n"
            )
            config.chmod(0o600)
            index = 1

            result = subprocess.run([str(SCRIPT), "--version"], cwd=ROOT, text=True, capture_output=True)
            check(result.returncode == 0 and result.stdout.strip().endswith("1.0.0"), "version output")
            report(index, "version output"); index += 1

            result = run(config)
            check(result.returncode == 0, result.stderr)
            check("* Workstation (this device)" in result.stdout, "local MAC fallback")
            check("Offline" not in result.stdout, "offline client leaked")
            check(STATE.authenticated_requests > 0, "challenge authentication was not used")
            report(index, "authentication, listing, and local MAC fallback"); index += 1

            result = run(config, "--json")
            clients = json.loads(result.stdout)
            check(len(clients) == 4 and all("mac" not in client for client in clients), "JSON contract")
            report(index, "machine-readable JSON"); index += 1

            password_helper = temp / "password-helper"
            password_helper.write_text("#!/usr/bin/env bash\nprintf secret\n")
            password_helper.chmod(0o700)
            command_config = temp / "command-config"
            command_config.write_text(
                f"ROUTER_URL={url}\nROUTER_USERNAME={USERNAME}\n"
                f"ROUTER_PASSWORD_COMMAND={password_helper}\n"
            )
            command_config.chmod(0o600)
            result = run(command_config, "--json")
            check(result.returncode == 0, result.stderr)
            report(index, "command-based password retrieval"); index += 1

            result = run(config, "--client", "Laptop", "--policy", "Direct")
            check(result.returncode == 0 and "Applied and verified" in result.stdout, result.stderr)
            check(STATE.assignments["02:00:00:00:00:10"]["policy"] == "Policy0", "name selector")
            post_count = len(STATE.policy_posts)
            result = run(config, "--quiet", "--client", "Laptop", "--policy", "Policy0")
            check(result.returncode == 0 and result.stdout == "", "quiet no-op")
            check(len(STATE.policy_posts) == post_count, "no-op posted a mutation")
            report(index, "verified assignment, quiet mode, and no-op"); index += 1

            result = run(config, "--ip", "192.0.2.20", "--policy", "VPN")
            check(result.returncode == 0 and STATE.assignments["02:00:00:00:00:20"]["policy"] == "Policy1", "IP selector")
            result = run(config, "--mac", "02:00:00:00:00:10", "--policy", "Default")
            check(result.returncode == 0 and STATE.assignments["02:00:00:00:00:10"]["policy"] is False, "MAC selector")
            report(index, "IP and MAC selectors"); index += 1

            check(run(config, "--bad-option").returncode == 2, "usage exit code")
            check(run(config, "--client", "Missing", "--policy", "VPN").returncode == 3, "client exit code")
            check(run(config, "--client", "Laptop", "--policy", "Missing").returncode == 4, "policy exit code")
            STATE.ignore_next_update = True
            result = run(config, "--ip", "192.0.2.20", "--policy", "Direct")
            check(result.returncode == 5 and "after applying" in result.stderr, "verification exit code")
            report(index, "stable documented exit codes"); index += 1

            process, master = start_pty(config, "--interactive", columns=40)
            first = read_pty(master, "Esc/q to cancel") + read_pty(master, timeout=0.3)
            clean_lines = [ANSI.sub("", line).replace("\r", "") for line in first.splitlines()]
            option_lines = [line for line in clean_lines if line.startswith(("> ", "  "))]
            check(option_lines and max(map(len, option_lines)) <= 40, "narrow terminal overflow")
            os.write(master, b"\r")
            second = read_pty(master, "Current policy:") + read_pty(master, timeout=0.2)
            check("Client: Workstation" in second, "current client was not initially selected")
            os.write(master, b"\x1b")
            finish_pty(process, master)
            check(process.returncode == 0, "Escape cancellation")
            report(index, "width-aware current-client TUI and Escape"); index += 1

            process, master = start_pty(config, "Phone", columns=80)
            read_pty(master, "Esc/q to cancel")
            os.write(master, b"\x1b[B\r")
            read_pty(master, "Current policy:")
            os.write(master, b"\x1b[A\r")
            finish_pty(process, master)
            check(process.returncode == 0, "arrow policy selection")
            check(STATE.policy_posts[-1]["mac"] == "02:00:00:00:00:21", "duplicate arrow client")
            check(STATE.policy_posts[-1]["policy"] == "Policy0", "arrow policy")
            report(index, "arrow navigation and duplicate disambiguation"); index += 1

            init_path = temp / "initialized" / "config"
            init_input = f"{url}\n{USERNAME}\n\n{PASSWORD}\n{PASSWORD}\n"
            result = run(init_path, "--init", input_text=init_input)
            check(result.returncode == 0, result.stderr)
            check(stat.S_IMODE(init_path.stat().st_mode) == 0o600, "initialized config mode")
            check("ROUTER_INSECURE=false" in init_path.read_text(), "TLS setting not saved")
            report(index, "secure guided configuration"); index += 1

            result = run(config, "--ca-file", str(config), "--json")
            check(result.returncode == 0, result.stderr)
            check(run(config, "--ca-file", str(config), "--insecure").returncode == 2, "TLS conflict")
            report(index, "CA and insecure option handling"); index += 1

            completion = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; COMP_WORDS=(keenetic-policy --ver); COMP_CWORD=1; '
                    '_keenetic_policy; printf "%s\\n" "${COMPREPLY[@]}"',
                    "_",
                    str(ROOT / "completions" / "keenetic-policy.bash"),
                ],
                text=True,
                capture_output=True,
                timeout=5,
            )
            check(completion.returncode == 0 and "--version" in completion.stdout, "Bash completion")
            report(index, "static Bash completion"); index += 1

        print(f"1..{index - 1}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    main()
