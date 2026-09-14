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
            {"name": "设备客户端", "ip": "192.0.2.60", "mac": "02:00:00:00:00:60", "link": "down"},
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
        if not self.authenticated():
            self.reply(401, {"message": "authentication required"})
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


def base_env(config=None, history=None):
    env = os.environ.copy()
    env.pop("CURL_CA_BUNDLE", None)
    env.pop("SSL_CERT_FILE", None)
    env["NO_COLOR"] = "1"
    if config is not None:
        env["KEENETIC_CONFIG"] = str(config)
        env["KEENETIC_STATE_FILE"] = str(history or config.parent / "history.json")
    return env


def run(config, *args, input_text=None, extra_env=None, timeout=12):
    env = base_env(config)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [str(SCRIPT), *args], cwd=ROOT, env=env, input=input_text,
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


def start_pty(config, *args, columns=80, extra_env=None):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, *termios_size(24, columns))
    env = base_env(config)
    if extra_env:
        env.update(extra_env)
    process = subprocess.Popen(
        [str(SCRIPT), *args], cwd=ROOT, env=env,
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
            check(result.returncode == 0 and result.stdout.strip().endswith("1.1.2"), "version output")
            report(index, "version output"); index += 1

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
            check("设备客户端 (offline)" in offline.stdout and "Laptop" not in offline.stdout, "offline listing")
            report(index, "connected, all, and offline listing modes"); index += 1

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
            wake = run(config, "--client", "设备客户端", "--wake")
            check(wake.returncode == 0 and "magic packet queued" in wake.stdout, wake.stderr)
            check(STATE.wake_posts[-1]["mac"] == "02:00:00:00:00:60", "offline wake target")
            report(index, "block, unblock, and offline Wake-on-LAN actions"); index += 1

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
            initialized = run(init_path, "--init", input_text=init_input)
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
            profiled = subprocess.run([str(SCRIPT), "--router", "home", "--json"], cwd=ROOT, env=profile_env,
                                      text=True, capture_output=True, timeout=12)
            check(profiled.returncode == 0 and len(json.loads(profiled.stdout)) == 4, profiled.stderr)

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
            untrusted = run(tls_config, "--json")
            check(untrusted.returncode == 1 and "TLS" in untrusted.stderr,
                  f"untrusted TLS result: rc={untrusted.returncode}, stderr={untrusted.stderr!r}")
            insecure = run(tls_config, "--insecure", "--json")
            check(insecure.returncode == 0 and "certificate verification is disabled" in insecure.stderr, insecure.stderr)
            check(run(tls_config, "--ca-file", str(ca_cert), "--insecure").returncode == 2, "TLS conflict")
            report(index, "real HTTPS trust, custom CA, and insecure transport"); index += 1

            completion = subprocess.run(
                ["bash", "-c", 'source "$1"; COMP_WORDS=(keenetic-policy --ver); COMP_CWORD=1; '
                 '_keenetic_policy; printf "%s\\n" "${COMPREPLY[@]}"', "_",
                 str(ROOT / "completions" / "keenetic-policy.bash")],
                text=True, capture_output=True, timeout=5,
            )
            check(completion.returncode == 0 and "--version" in completion.stdout, "Bash completion")
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
