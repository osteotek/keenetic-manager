# Keenetic Policy CLI

A Bash CLI for listing connected Keenetic router clients and changing their connection policies through the router's RCI API.

![Interactive client selector](docs/demo.svg)

## Requirements

- Bash 4.3 or newer
- `curl`
- `jq`
- `md5sum`
- `sha256sum`
- Python 3 for the regression suite

## Install

```bash
git clone https://github.com/osteotek/omarchy-keenetic.git
cd omarchy-keenetic
make install
keenetic-policy --init
```

The default installation path is `~/.local/bin/keenetic-policy`. Ensure `~/.local/bin` is in `PATH`.

Uninstall with:

```bash
make uninstall
```

## Configuration

Create and test the configuration interactively:

```bash
keenetic-policy --init
```

The default path is `~/.config/keenetic-policy/config`. Override it with `KEENETIC_CONFIG`.

```ini
ROUTER_URL=https://router.example.keenetic.pro
ROUTER_USERNAME=admin
ROUTER_PASSWORD=replace-with-router-password
ROUTER_INSECURE=false
```

The generated file has mode `0600`.

### External password storage

Instead of storing the password directly, configure a command that prints it without a trailing explanation:

```ini
ROUTER_PASSWORD_COMMAND=secret-tool lookup service keenetic-policy
```

Other examples:

```ini
ROUTER_PASSWORD_COMMAND=pass show routers/keenetic
ROUTER_PASSWORD_COMMAND=keepassxc-cli show -q -a Password ~/Passwords.kdbx Keenetic
```

The command is parsed as a space-separated executable and arguments. Shell syntax, pipelines, and quoting are intentionally unsupported.

### HTTPS trust

Trust a private router CA:

```ini
ROUTER_CA_FILE=/home/user/.local/share/keenetic/router-ca.pem
```

Or provide it for one invocation:

```bash
keenetic-policy --ca-file router-ca.pem
```

`--insecure` and `ROUTER_INSECURE=true` disable certificate verification and print a warning. Prefer a trusted CA or a valid KeenDNS certificate. Plain HTTP also prints a warning because it does not protect the authenticated session or API traffic.

## Usage

List connected clients and policies:

```bash
keenetic-policy
```

```text
NAME                                 IP              POLICY
------------------------------------ --------------- ------------------
Laptop                               192.168.1.10    Default
* Workstation (this device)          192.168.1.20    VPN
```

Select a client and policy interactively:

```bash
keenetic-policy --interactive
```

Use Up/Down arrows to move, Enter to select, and Esc or `q` to cancel. The client matching the router-facing local IP or a local interface MAC is initially selected.

Select a policy for one named client:

```bash
keenetic-policy "Living Room TV"
```

Apply policies non-interactively:

```bash
keenetic-policy --client "Living Room TV" --policy VPN
keenetic-policy --ip 192.168.1.20 --policy Policy1
keenetic-policy --mac aa:bb:cc:dd:ee:ff --policy Default
```

Policy descriptions and IDs are matched case-insensitively. Every mutation is fetched back from the router and verified before success is reported.

Machine-readable listing:

```bash
keenetic-policy --json
```

```json
[
  {
    "name": "Living Room TV",
    "ip": "192.168.1.20",
    "policy": "VPN",
    "policy_id": "Policy1"
  }
]
```

Suppress successful mutation output:

```bash
keenetic-policy --quiet --client Laptop --policy Direct
```

Show the installed version:

```bash
keenetic-policy --version
```

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success, cancellation, or policy already selected |
| 1 | Configuration, authentication, connection, or API failure |
| 2 | Invalid command-line arguments |
| 3 | Client not found or ambiguous |
| 4 | Policy not found or ambiguous |
| 5 | Router accepted a mutation but verification failed |

## Development

Run syntax checks, ShellCheck when installed, and the mock-router regression suite:

```bash
make check
```

The integration suite exercises challenge authentication, client filtering, policy mutation and verification, selectors, JSON output, guided configuration, exit codes, narrow-terminal rendering, and PTY keyboard interaction.

## API reference

Authentication and policy endpoints follow the implementation in [Toxblh/Keenetic-Manager](https://github.com/Toxblh/Keenetic-Manager/blob/master/src/api/keenetic_router.py).

## License

MIT. See [LICENSE](LICENSE).
