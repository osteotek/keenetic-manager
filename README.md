# Keenetic Manager

A Bash CLI for Keenetic routers. Inspect status, clients, Wi-Fi, traffic, and VPN, run router-side diagnostics, and manage connection policies through the router's RCI API.

![Interactive client selector](docs/demo.svg)

## Features

- **Router overview.** KeenDNS name and access mode, connected-client counts, and every interface with status, IPv4/IPv6 addresses, and traffic totals.
- **Interfaces.** List interfaces, inspect MAC/MTU/gateways/counters, sample live RX/TX rates with in-terminal graphs, and connect or disconnect interfaces interactively.
- **Wi-Fi.** Access-point networks with band, channel, security, and client counts; associated stations with signal and link rates; nearby network surveys; channel utilization per radio.
- **Traffic ranking.** Top clients by received and sent bytes over the router's 3-minute, 1-hour, 3-hour, or 1-day Traffic Monitor windows.
- **Network state.** WAN health and DNS servers, DHCP leases and reservations, IPv4/IPv6 routing table, mesh members and backhaul, live NAT connections, and port-forwarding rules.
- **Clients.** List online and offline clients, inspect connection, policy, and traffic details, and rename devices.
- **Connection policies.** Assign clients to policies with `policy assign CLIENT POLICY`, block or unblock Internet access, batch changes with dry runs, undo verified changes, and inspect policy interface order.
- **VPN.** WireGuard peers with endpoints, handshake age, counters, and status.
- **System.** Model, firmware, uptime, CPU, memory, and connection-table usage; pending configuration changes; save configuration; reboot.
- **Diagnostics.** Router-side ping and traceroute, iPerf3 throughput tests, and recent logs with filtering.
- **Wake-on-LAN** for known clients, including offline ones.
- **Live views.** Refresh any read-only view in place with `--watch`, or stream NDJSON snapshots for scripts.
- **Scripting.** `--json` on every view, stable exit codes, `--quiet` and `--verbose`, and Bash and zsh completion.
- **Multiple routers.** Named profiles, password files or commands, private CA trust, and default-gateway discovery.

All read-only views make no configuration changes. Mutations verify the router's state after writing and support `--dry-run`.

## Quick start

Requirements:

- Bash 4.3 or newer (macOS ships Bash 3.2; run `brew install bash` and `keenetic` re-executes under it automatically)
- `curl`
- `jq` 1.6 or newer
- `md5sum` and `sha256sum`, or the macOS `md5` and `shasum` equivalents
- Optional: `fzf` for searchable interactive selection
- Python 3 and OpenSSL for the regression suite

Install from a checkout and create a configuration:

```bash
git clone https://github.com/osteotek/keenetic-manager.git
cd keenetic-manager
make install
keenetic config init
```

The default installation path is `~/.local/bin/keenetic`. Ensure it is in `PATH`. Bash completion installs to `~/.local/share/bash-completion/completions/` and zsh completion to `~/.local/share/zsh/site-functions/`; add that directory to `fpath` before `compinit` if it is not already there. `make uninstall` removes the executable and both completions.

Tagged releases publish a standalone `keenetic` executable, `SHA256SUMS`, and a source archive. Packaging definitions live under `packaging/` for Arch/AUR, Homebrew, and Debian.

Then try:

```bash
keenetic                 # router status
keenetic client list         # connected clients
keenetic wifi            # Wi-Fi networks
keenetic traffic         # top clients by traffic
keenetic --help          # command overview
```

Mistyped commands get a suggestion, for example `keenetic clinets` answers with `Did you mean 'keenetic clients'?`.

## Command overview

Commands name a resource and take a verb; the first verb is the default, so `keenetic client` equals `keenetic client list`. Targets are client names, IP addresses, or MAC addresses, interface IDs, or policy names or IDs.

| Command | Verbs | Purpose |
|---|---|---|
| `keenetic` / `keenetic status` | | [Router status](#router-status): KeenDNS, client counts, interfaces, traffic totals |
| `keenetic client` | `list`, `show`, `rename`, `wake`, `block`, `unblock`, `assign`, `nat` | [Clients](#client-details): details, [Wake-on-LAN](#wake-on-lan), [Internet blocks and policies](#clients-and-connection-policies), [NAT connections](#active-connections-and-port-forwarding) |
| `keenetic policy` | `list`, `show`, `assign`, `block`, `unblock`, `undo` | [Connection policies](#clients-and-connection-policies) and the clients that use them |
| `keenetic interface` | `list`, `show`, `rates`, `up`, `down` | [Interfaces](#interfaces): status, details, live rates, [enable or disable](#interface-control) |
| `keenetic wifi` | `list`, `clients`, `scan`, `load` | [Wi-Fi](#wi-fi): networks, stations, nearby survey, channel load |
| `keenetic vpn peers` | | [WireGuard peers](#vpn-peers) |
| `keenetic traffic` | | [Traffic](#traffic): rank clients by recent traffic |
| `keenetic wan`, `dhcp`, `routes`, `mesh`, `nat`, `forwards` | | [WAN health](#wan-health), [DHCP leases](#dhcp-leases), [Routing table](#routing-table), [Mesh topology](#mesh-topology), [NAT and port forwarding](#active-connections-and-port-forwarding) |
| `keenetic system` | `show`, `changes`, `save`, `reboot` | [System health](#system-health), [configuration persistence](#client-names-and-configuration-persistence), [reboot](#reboot) |
| `keenetic logs` | | [Logs](#logs-and-diagnostics): recent router log lines |
| `keenetic diagnose HOST` | | [Diagnostics](#logs-and-diagnostics): router-side ping and traceroute |
| `keenetic speedtest` | | [Throughput test](#router-throughput-test) with iPerf3 |
| `keenetic config` | `init`, `discover` | [Configuration](#configuration) and router discovery |

Add `--json` to any read-only view for machine-readable output and `--watch SECONDS` to refresh it in place. See [Live views](#live-views) and [Global options](#global-options).

Earlier spellings keep working: `clients inspect X` is `client show X`, `policy set` is `policy assign`, `interfaces --rates` is `interface rates`, `wifi monitor` is `wifi load`, `connections` is `nat`, `wake` is `client wake`, `--init` and `--discover` are `config init` and `config discover`, and the flag form `policy --client X --policy Y` still applies policies. One change in meaning: bare `keenetic policy` now lists policies; use `keenetic client list` for clients.

### Interactive pickers

`-i` / `--interactive` replaces typed names and IDs with a picker: searchable with fzf when installed, arrow keys otherwise. Where a command can act on several targets, fzf's Tab or the arrow menu's Space marks more than one.

| Command | What the picker does |
|---|---|
| `keenetic -i` | Menu of commands; runs the chosen one, interactively where that exists |
| `policy -i` | Pick one or more clients, then a policy or Block Internet for all of them |
| `policy undo -i` | Pick which recorded change to restore instead of the newest |
| `policy show -i` | Pick a policy to inspect |
| `client wake -i` | Pick one or more known clients, including offline ones |
| `client -i`, `client show -i` | Pick a client to inspect |
| `client rename -i` | Pick a client, then type the new name |
| `interface -i` | Pick an interface, then Connect, Disconnect, or Inspect |
| `interface show -i` | Pick an interface to inspect |
| `nat -i` | Pick the client whose NAT connections to show |
| `logs -i` | Pick a log source from the retrieved entries |
| `wifi scan -i` | Pick the radio to survey |
| `diagnose HOST -i`, `speedtest -i` | Pick the source interface; `speedtest` also picks the server from known clients |

Cancelling any picker leaves the router unchanged. `--dry-run` works with the pickers that perform actions.

Text output colors status words when writing to a terminal: green for online, connected, or passing states, yellow for offline, disconnected, or not-ready states, red for errors and blocks, and dim for unknown values. Detail views fold fields the router did not report into a single dim `Not reported:` line so real data stands out; JSON keeps every field with `null` values. Colors follow `--color`, `--no-color`, and `NO_COLOR`.

## Configuration

Create and test the default configuration interactively:

```bash
keenetic config init
```

The prompts ask for the router URL, username, and password. Leave the password blank to store a password file path or a password command instead. HTTPS URLs then ask for a trusted CA file.

Configuration and history retain the `keenetic-policy` directory name for compatibility with existing installations.

The default path is `~/.config/keenetic-policy/config`. Override it with `KEENETIC_CONFIG`.

```ini
ROUTER_URL=https://router.example.keenetic.pro
ROUTER_USERNAME=admin
ROUTER_PASSWORD=replace-with-router-password
ROUTER_INSECURE=false
```

The generated file has mode `0600`. Values are literal; shell syntax is not evaluated.

Plain `http://` URLs print a warning on every run because the authenticated session is unprotected. `--init` shows the warning once and writes `ROUTER_ALLOW_HTTP=true` to acknowledge it. Add that line to an existing configuration to silence the warning.

### Password sources

Set exactly one of these:

```ini
ROUTER_PASSWORD=replace-with-router-password
ROUTER_PASSWORD_FILE=/home/user/.config/keenetic-policy/password
ROUTER_PASSWORD_COMMAND=secret-tool lookup service keenetic-policy
```

A password file must contain exactly one non-empty line. A password command is parsed as a space-separated executable and arguments. Pipelines, expansion, and shell quoting are intentionally unsupported. Other useful commands include `pass show routers/keenetic` and `keepassxc-cli show -q -a Password ~/Passwords.kdbx Keenetic`.

### Named routers

Store named profiles as separate configuration files:

```text
~/.config/keenetic-policy/routers/home
~/.config/keenetic-policy/routers/office
```

Select one with:

```bash
keenetic --router home policy --json
keenetic config init --router office
```

`--router` cannot be combined with `KEENETIC_CONFIG`.

### Router discovery

To probe only the active default gateway for a compatible `/auth` endpoint, without scanning the subnet:

```bash
keenetic config discover
```

### HTTPS trust

Trust a private router CA in the configuration:

```ini
ROUTER_CA_FILE=/home/user/.local/share/keenetic/router-ca.pem
```

Or for one invocation:

```bash
keenetic --ca-file router-ca.pem policy --json
```

`--insecure` and `ROUTER_INSECURE=true` disable certificate verification and print a warning. Prefer a trusted CA or valid KeenDNS certificate. Plain HTTP also warns because it does not protect the authenticated session or API traffic.

### Global options

`--router`, `--ca-file`, `--insecure`, `--quiet`, `--verbose`, `--color`, `--no-color`, `--help`, and `--version` work before or after a subcommand:

```bash
keenetic --router home policy --json
keenetic policy --router home --json
keenetic --verbose client wake --client Desktop
keenetic client wake --help
```

`--help` shows help for the selected subcommand even when placed before it. Client selectors, listing filters, actions, and `--dry-run` follow their subcommand.

## Monitoring

### Router status

Without a subcommand, `keenetic` shows the router's KeenDNS name, access mode, and connected-client counts (wired/wireless), then VPN/proxy interfaces followed by other interfaces, with their descriptions, status, IPv4/IPv6 addresses, and received/sent traffic totals:

```bash
keenetic
keenetic --router home
keenetic --all
keenetic --json
keenetic --all --json
```

```text
ROUTER INFO        VALUE
Router             https://router.example.keenetic.pro
KeenDNS            home.keenetic.link (direct)
Connected clients  4 (2 wired / 2 wireless)

VPN / proxy interfaces
INTERFACE / NAME                      STATUS     IP ADDRESS                              RX       TX
Wireguard0 Work VPN [Wireguard]       connected  10.0.0.2                             5 GiB  120 MiB

Other interfaces
INTERFACE / NAME                      STATUS     IP ADDRESS                              RX       TX
Bridge0 Home [Bridge]                 connected  192.168.1.1, fe80::1/64              1 GiB    2 MiB
```

Basic router details use a borderless label/value table sized to its content. Long values wrap within their column; below 40 columns, values appear beneath their labels. Connected-client counts stay together as one summary value.

By default, only connected interfaces and ports with an active link are shown. Use `--all` to include disabled, disconnected, link-down, and unknown interfaces. The same filter applies to `--json`, and traffic statistics are requested only for displayed interfaces. Interface output uses borderless, aligned rows like the fzf client list. At 72 columns or wider, each interface occupies one row with its ID/name/type, status, IP addresses, and RX/TX totals. Fields that do not fit end in `…`; missing addresses display as `-`. On narrower screens, each interface has a name/status row followed by indented IP and traffic details. It uses `COLUMNS` when set, otherwise detects terminal width or defaults to 80 columns (minimum 20). Use `--json` for complete names, types, addresses, and counters regardless of screen width.

Status reflects the router's administrative and connection/link state, not an end-to-end Internet or VPN reachability test. The command reads `/rci/show/interface` and `/rci/show/ndns` after authentication, then sends a batch of read-only `show interface NAME stat` queries to `/rci/`. It makes no configuration changes.

`keenetic --json` returns an object with `router` and `interfaces`. Each interface includes `id`, `description`, `type`, `vpn`, `status`, `state`, `link`, `connected` (boolean or null when unknown), `ipv4`, `mask`, and an `ipv6` array of `{address, prefix_length}` objects. IPv4 and mask are null when absent. Use `keenetic client list --json` for client output.

The top-level `keendns` object contains `hostname` and `access`; it is null if unavailable, with a null hostname when unconfigured. Each interface's `traffic` object contains `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets`, `rx_errors`, `tx_errors`, `rx_dropped`, and `tx_dropped`. Missing counters are null, and an unavailable statistics response produces `traffic: null` plus a warning while preserving the interface listing.

The top-level `clients` object contains `connected`, `wired`, and `wireless` counts, or null when unavailable. Counts come from `/rci/show/ip/hotspot/host`: clients with an active local or mesh link are counted once per MAC address. Wi-Fi access-point/SSID metadata identifies wireless clients; other online clients are counted as wired. `--all` does not include offline clients in this summary. These counts reflect connections visible to the router; clients behind a separate access point may appear wired.

Traffic values are cumulative counters reported by the router, not live rates or monthly usage. They can reset when the router or interface restarts. RX/TX are relative to each router interface; totals from LAN, WAN, and VPN interfaces can count the same traffic, so they are not added together. Human-readable byte totals use binary units (KiB, MiB, GiB); JSON retains byte counts.

### Interfaces

Show the same interface tables as `keenetic`, including VPN/proxy grouping, status, IP addresses, and RX/TX totals:

```bash
keenetic interface list
keenetic interface list --all
keenetic interface list --json
keenetic interface list --all --json
```

The default list hides inactive interfaces; `--all` includes them. This command omits the router summary and only fetches interface data and traffic counters. JSON contains `router` and `interfaces`, using the same interface fields as the default status command.

Inspect one interface or sample live rates:

```bash
keenetic interface show GigabitEthernet1
keenetic interface show Wireguard0 --json
keenetic interface rates
keenetic interface rates --sample 2 --watch 2
keenetic interface rates --all --json
```

Inspection includes inactive interfaces and requires an exact interface ID. It adds MAC, MTU, priority, default gateways, uptime, Ethernet speed/duplex and physical port details where reported, plus packet/error/drop counters. Missing values remain unknown. IPv6 gateway data is optional; an unsupported IPv6 endpoint does not discard IPv4 results.

`--rates` samples cumulative counters twice, waiting one second initially (`--sample` accepts 1–60 seconds). RX/TX speeds use the actual elapsed interval, measured in whole seconds, and are relative to the router interface. Text displays decimal Mbps; JSON preserves bytes per second, the sample interval, and up to 20 samples per direction. Its `sampled_at` value is elapsed seconds since this CLI process started. With `--watch`, subsequent frames use the previous frame's counters and keep a small history in memory/temp files for that session. The graph scales to each direction's own recent maximum. Counter decreases, newly appearing interfaces, and changes in state/address produce unknown rates and reset that interface's history. `--rates` cannot be combined with inspection or interactive control.

Connecting and disconnecting interfaces is described under [Interface control](#interface-control).

### Wi-Fi

List the router's own Wi-Fi access-point networks:

```bash
keenetic wifi
keenetic wifi --all
keenetic wifi --json
keenetic --router home wifi --all --json
```

The compact table shows SSID, band, channel, channel width in MHz, security mode, connected-client count, and status. Each access point gets its own row, including SSIDs shared across multiple bands. Narrow screens show SSID/status rows with radio, security, and client details beneath. The default shows active networks; `--all` includes disabled, link-down, and unknown networks. This command does not scan neighbouring networks or change Wi-Fi settings.

Radio details come from `/rci/show/interface`. Reported bands or frequencies take priority. When those fields are absent, the conventional `WifiMaster0` = 2.4 GHz and `WifiMaster1` = 5 GHz mapping is used, as described in [Keenetic's channel-width documentation](https://destek.keenetic.com.tr/starter/kn-1121/en/45473-setting-the-wireless-channel-width-to-20-40-mhz.html); other unknown radio bands remain null. Parent radio state is included when deciding whether a network is active.

Client counts use `/rci/show/ip/hotspot/host`, counting unique MAC addresses with active local or mesh links and an access-point ID matching the network. Counts are not inferred from SSID alone. Unavailable client data is shown as `-`, rather than zero.

JSON contains `router` and `networks`. Each network includes `id`, `radio_id`, `ssid`, `description`, `bssid`, `state`, `link`, `status`, `band`, `band_source`, `channel`, `channel_width_mhz`, `authentication`, `encryption`, and `clients`. Missing data is null; `band_source` identifies reported, frequency-derived, or radio-ID-derived bands. Authentication fields describe the mode only: passwords and keys are excluded from text and JSON output.

#### Wi-Fi client details and surveys

```bash
keenetic wifi clients
keenetic wifi clients --watch 2 --json
keenetic wifi scan
keenetic wifi scan --radio WifiMaster1 --json
```

`wifi clients` lists associated stations with access point, RSSI, TX link rate, Wi-Fi standard, channel width, and spatial streams. JSON adds RX link rate when available, MCS, security, authentication state, connection uptime, and byte counters. Device names/IPs are supplementary; unavailable inventory does not discard station telemetry.

`wifi scan` surveys nearby networks and shows SSID, BSSID, radio, channel, signal, and security. Hidden SSIDs are retained. It surveys enabled radios by default; `--all` includes disabled radios, `--radio ID` selects one exact radio, and `--interactive` picks the radio from a list. A scan may briefly affect Wi-Fi traffic, and `--watch` is unavailable for scans. Survey responses are whitelisted and exclude keys/passwords.

#### Wi-Fi channel utilization

```bash
keenetic wifi load
keenetic wifi load --all --watch 3
keenetic wifi load --json
```

Shows current, average, and peak channel utilization for each radio, plus channel, width, and state. The window contains available samples from the last 180 seconds relative to the newest router sample; JSON includes the sample count. Missing samples display as unknown. `--all` includes disabled radios. This reports channel load, rather than scanning neighboring SSIDs.

### Traffic

Show clients ranked by combined received and sent bytes. The default is the top five over the last three minutes:

```bash
keenetic traffic
keenetic traffic --top 10 --period 1h
keenetic traffic --top 3 --period 1d --json
keenetic --router home traffic --period 3h
```

`--top` accepts a positive integer. `--period` selects one of the router's stored windows:

| Period | Window |
|---|---|
| `3m` | Last 3 minutes (default) |
| `1h` | Last hour |
| `3h` | Last 3 hours |
| `1d` | Last day |

Results come from the router's existing Traffic Monitor history and return immediately. The compact table shows name, IP address, RX, TX, total bytes, and current online/offline status. Status is `unknown` when current link information is unavailable. Columns fit their content; narrow screens move addresses and RX/TX beneath each row, and screens below 32 columns also move totals beneath the row to keep status visible. Fewer rows appear when fewer clients have recorded history. Clients with recent traffic remain eligible even if they are now offline.

Keenetic's [Traffic Monitor](https://support.keenetic.com/orbiter-pro/kn-2810/en/13915-traffic-monitor.html) records registered-device Internet traffic, excluding local traffic. This command excludes the aggregate Other devices, unregistered, and multicast categories from the client ranking. RX/TX are bytes received/sent by the client within the selected window, not live rates or lifetime counters.

The command reads `/rci/show/ip/hotspot/summary` with `attribute=sumbytes`, the requested `count`, and `detail=0/1/2/3` for the four periods. It enriches addresses from `/rci/show/ip/hotspot/host`; unavailable addresses appear as `-`. Unsupported or malformed history produces an error rather than substituting lifetime counters.

JSON contains `router`, `period`, `window_seconds`, `limit`, and a ranked `clients` array. Each client has `rank`, `name`, `mac`, `ip`, `online`, `rx_bytes`, `tx_bytes`, and `total_bytes`. `online` reflects current local or mesh links and is null when unknown. Missing addresses or directional counters are null; full names and exact byte totals are preserved regardless of terminal width.

### WAN health

```bash
keenetic wan
keenetic wan --watch 5
keenetic wan --json
```

Shows Internet reachability, the last check time, active gateway/interface, global connection priorities and states, DNS servers, and ping-check results. `active` identifies the reported gateway interface or an interface marked as a default gateway; other global interfaces are `alternate`. This is the router's global connection view, rather than a prediction of which interface every client policy will use. DNS entries include plain, TLS, and HTTPS servers when available. HTTPS URLs are reduced to hostnames, excluding credentials, paths, and query parameters.

### DHCP leases

```bash
keenetic dhcp
keenetic dhcp --watch 5 --json
```

Lists IP/MAC mappings, device names, lease expiry, and static/dynamic assignments. Static assignments are matched against configured reservations, including reservations without a current lease. A lease's presence does not establish that its device is online. Infinite leases have `infinite: true` and a null expiry in JSON.

### Routing table

```bash
keenetic routes
keenetic routes --json
```

Shows IPv4 and IPv6 destinations, gateways, outgoing interfaces, metrics, flags, and protocols. JSON also includes rejecting, floating, and static flags. If IPv6 routing is unavailable, `ipv6_available` is false and IPv4 routes remain visible. These commands inspect the existing IP routing table.

### Mesh topology

```bash
keenetic mesh
keenetic mesh --watch 5 --json
```

Shows mesh members, IP addresses, client counts, backhaul uplinks, parent bridge IDs, signal levels, and controller update settings. JSON also includes firmware, uptime, root bridge ID, backhaul TX rate, and Internet availability. Parent/root values retain the router's bridge identifiers. `responding` means the member reports zero RCI errors; `API errors` reports nonzero errors. Missing status remains unknown. An empty member inventory is valid, including the `{}` response used by routers without extenders.

### Active connections and port forwarding

```bash
keenetic nat
keenetic client nat Laptop --watch 2
keenetic client nat 192.168.1.10 --json
keenetic forwards
keenetic forwards --json
```

`connections` shows the router's live NAT table, with source/destination addresses and ports, protocol, and directional counters. The optional client selector searches known clients by name, IP, or MAC, including offline clients; ambiguous names require an IP or MAC. `--interactive` picks the client from a list instead. Filtering matches original and translated addresses in both directions. JSON preserves translated addresses/ports and packet counters. The NAT table is not a complete list of every LAN or IPv6 connection.

`forwards` lists configured static forwarding rules, including external port ranges, target host/port, interface, protocol, comment, and enabled state. These are configured rules, independent of whether a corresponding live NAT connection exists.

### Client details

```bash
keenetic client list
keenetic client list --all --json
keenetic client show Laptop
keenetic client show 192.168.1.10 --json
keenetic client show aa:bb:cc:dd:ee:ff
keenetic client --interactive
keenetic client -i --all
keenetic client rename --interactive
```

`clients` uses the same listing as `policy`. `--interactive` opens the same client picker as `policy --interactive`, searchable with fzf when installed, and shows the chosen client's details; `--all` and `--offline` widen the pick list, and cancelling prints `No client selected.` without contacting the router again. `client rename --interactive` picks the client and then prompts for the new name, with the current name as the default. Inspection searches online and offline clients by case-insensitive name, exact IP, or MAC. Ambiguous names require an IP or MAC. Details include policy/block state, connection type, access point, SSID, band/channel, signal, reported RX/TX link rates, connection uptime, and stored traffic over three minutes. Missing optional data is `unknown` in text and null in JSON; unsupported traffic history does not discard the client details. Link rates are Mbps and memory/traffic byte totals use binary display units.

### System health

```bash
keenetic system
keenetic system --json
```

Shows model, firmware, hostname, uptime, CPU load, RAM, swap, and connection-table usage from `show system` and `show version`. The router's memory counters are KiB and are converted to bytes in JSON. Used RAM follows the router's reported `memory` value. Unavailable firmware metadata produces a warning while preserving health data.

Configuration changes, saving, and reboot are described under [Management](#management).

### VPN peers

```bash
keenetic vpn peers
keenetic vpn peers --json
```

Lists WireGuard peers with interface, peer description, remote endpoint, handshake age, RX/TX totals, and online/offline/disabled/unknown status. `last-handshake` is interpreted as an age in seconds. Byte counters are cumulative and may reset. Status comes from the router; it does not establish end-to-end reachability. JSON includes public keys when supplied but excludes private and preshared keys. Use `interfaces` for other VPN types.

### Logs and diagnostics

```bash
keenetic logs
keenetic logs --limit 100 --filter wireguard
keenetic logs --limit 50 --json
keenetic diagnose example.com
keenetic diagnose 1.1.1.1 --interface Wireguard0 --json
```

Logs retrieve a bounded recent snapshot (20 lines by default, maximum 1000). `--filter` applies a case-insensitive literal match to message/source after retrieving that snapshot; it does not search the router's full history. `--interactive` lists the sources present in that snapshot and keeps only the chosen one. Text rows abbreviate long messages; JSON preserves them.

`diagnose HOST` runs ping and traceroute **from the router**, optionally through an existing interface (`--interface ID`, or `--interactive` to pick one), then includes relevant entries from the latest 20 log lines. Ping sends four probes; traceroute uses at most 12 hops, one probe per hop, and a one-second probe wait. IPv6 literals select `ping6`. Each tool has a 60-second polling limit; interruption or a polling failure cancels the active router tool. `completed` in JSON means the tool finished: inspect its output for packet loss and routing failures. Logs are supplementary and can be unavailable without discarding probe output.

These features use the router's RCI system, interface, channel-utilization, log, and diagnostic endpoints. Their availability depends on firmware/components. See the [Keenetic CLI reference](https://storage.googleapis.com/docs.help.keenetic.com/cli/4.1/en/cli_manual_kn-2410.pdf) and [RCI diagnostic request/poll/cancel implementation](https://github.com/hexqnt/keenetic-rci/blob/master/src/client.rs). They do not save or restore router configuration.

### Router throughput test

```bash
keenetic speedtest --server 192.168.1.10
keenetic speedtest --server 192.168.1.10 --reverse --duration 15
keenetic speedtest --server example.net --port 5202 --interface Wireguard0 --json
keenetic speedtest --server 192.168.1.10 --dry-run
```

The target must run an iPerf3 server. `--interactive` picks the server from known clients and the source interface from a list. This tests TCP throughput from the router to the chosen server; `--reverse` measures server-to-router download. Defaults are port 5201 and ten seconds, with a duration range of 1–30 seconds. IPv6 literals select IPv6. `--interface` selects an existing router interface, while `--dry-run` previews the request without starting traffic. No public test server is selected automatically.

The command polls the router's iPerf3 tool and cancels it on interruption or polling failure, using the same bounded lifecycle as `diagnose`. It cannot be watched. JSON includes server, direction, duration, and the tool's output lines. `completed` means the tool finished; examine the output for throughput results or errors.

### Live views

Add `--watch SECONDS` to a read-only view to refresh it in place:

```bash
keenetic --watch 2
keenetic interface list --all --watch 2
keenetic traffic --top 10 --period 1h --watch 5
keenetic wifi --watch 3
keenetic system --watch 2
keenetic vpn peers --watch 5
keenetic client show Laptop --watch 3
keenetic policy show VPN --watch 5
keenetic logs --watch 5
```

The interval is an integer from 1 to 3600 seconds, measured after each completed refresh. Terminal output uses an alternate screen with a header showing the interval, the last refresh time, and the exit key. It adapts to width changes and restores the screen/cursor on Ctrl-C. For scripts, `keenetic system --watch 2 --json` emits one complete JSON snapshot per line (NDJSON), suitable for pipes. Authentication is reused between refreshes. Watch cannot be combined with interactive actions or diagnostics. Watched logs are repeated recent snapshots, so entries can appear in multiple frames.

## Management

### Clients and connection policies

List connected clients:

```bash
keenetic client list
```

```text
NAME                         IP ADDRESS    POLICY   STATUS
Laptop                       192.168.1.10  Default  online
* Workstation (this device)  192.168.1.20  VPN      online
```

The list uses the same compact, borderless style as router status. Columns fit their content instead of stretching across the screen. Long fields are abbreviated to fit the terminal; on narrow screens, IP addresses appear below each row, followed by policy details on screens below 32 columns. `STATUS` shows `online` or `offline` and stays visible at every supported width. `*` marks this device. Use `--json` for full values.

Include known offline clients, or show only offline clients:

```bash
keenetic client list --all
keenetic client list --offline
```

Offline rows are marked explicitly and are never the default interactive selection.

Machine-readable output includes the stable MAC needed by mutation and Wake-on-LAN workflows:

```bash
keenetic client list --all --json
```

```json
[
  {
    "name": "Living Room TV",
    "ip": "192.168.1.20",
    "mac": "aa:bb:cc:dd:ee:ff",
    "online": true,
    "blocked": false,
    "policy": "VPN",
    "policy_id": "Policy1"
  }
]
```

#### Interactive use

```bash
keenetic policy --interactive
keenetic policy --interactive --all --dry-run
keenetic policy "Living Room TV"
```

When `fzf` is available, both client and policy menus are searchable, and client fields use aligned name, IP, policy, and status columns. Otherwise the built-in menu uses Up/Down arrows, Enter, and Esc or `q`. The native menu redraws after terminal resizing and conservatively truncates double-width Unicode. The current device and current policy are initially selected. Interactive policy choices include **Block Internet**, which requires confirmation.

`--interactive` accepts several clients: press Tab in fzf or Space in the arrow menu to mark them, then Enter. One policy is then chosen for all marked clients and applied as a batch with the same plan output, sequential verification, and history recording as the flag form.

#### Assigning policies and blocking

The verb forms take one or more clients by name, IP address, or MAC address and detect which was given:

```bash
keenetic policy assign "Living Room TV" VPN
keenetic policy assign 192.168.1.20 aa:bb:cc:dd:ee:ff Policy1
keenetic client block Tablet
keenetic client unblock Tablet
```

The equivalent flag forms use explicit selectors, which can be mixed in one batch:

```bash
keenetic policy --client "Living Room TV" --policy VPN
keenetic policy --ip 192.168.1.20 --policy Policy1
keenetic policy --mac aa:bb:cc:dd:ee:ff --policy Default
keenetic policy --client Tablet --block
keenetic policy --client Tablet --unblock
```

Policy descriptions and IDs are matched case-insensitively. The CLI retries read-back verification at 0, 250, 500, and 1000 milliseconds before reporting verification failure. When a name matches several clients, the error lists a ready-to-run command for each candidate using its IP address.

#### Batch changes and dry runs

Repeat selectors to preflight every target before the first mutation:

```bash
keenetic policy \
  --client Laptop \
  --ip 192.168.1.25 \
  --mac aa:bb:cc:dd:ee:ff \
  --policy VPN
```

Targets are deduplicated by MAC address. A batch is sequential, not atomic. If one mutation fails, the error identifies its position and how many earlier clients completed.

Preview resolution and the complete plan without sending a POST:

```bash
keenetic policy --client Laptop --client Phone --policy VPN --dry-run
keenetic client wake --client Desktop --dry-run
```

#### Undo

Verified policy, block, and unblock changes are recorded in a bounded 20-entry history at `${XDG_STATE_HOME:-~/.local/state}/keenetic-policy/history.json`. Entries contain the router URL, client name and MAC, before/after state, action, and timestamp; no passwords, challenge hashes, or session cookies are stored.

Restore and verify the newest entry for the selected router, or pick an older one:

```bash
keenetic policy undo
keenetic policy undo --dry-run
keenetic policy undo --interactive
```

`--interactive` lists the recorded changes for this router, newest first, with the state each one would restore. A successful undo consumes that history entry.

#### Policy list and details

```bash
keenetic policy
keenetic policy list --json
keenetic policy show VPN
keenetic policy show Policy1 --json
keenetic policy show default
keenetic policy show --interactive
```

`policy list` shows every policy with its ID, permitted-interface count, and client count, plus a Blocked row for clients without Internet access. `policy show` adds the permitted interfaces in their configured order, enabled state, priority, connection status, and assigned clients, including offline clients. `ORDER` follows the policy's permit list. `PRIORITY` uses a policy-specific value when supplied, otherwise the interface's global priority; JSON identifies this as `priority_source`. Global priorities alone do not define a custom policy's interface order. The default policy lists global interfaces in descending priority order.

### Wake-on-LAN

Send Wake-on-LAN to a known client, including an offline client:

```bash
keenetic client wake --client Desktop
keenetic client wake --interactive
```

The router's Wake-on-LAN response is included in the success message. Repeat selectors to wake multiple clients, or add `--dry-run` to preview. `--interactive` lists every known client, including offline ones, and accepts several at once. Wake-on-LAN is not recorded in undo history.

### Interface control

Enable or disable an interface by ID, or pick one interactively:

```bash
keenetic interface up Wireguard0
keenetic interface down OpenVPN0 --dry-run
keenetic interface --interactive
keenetic interface -i --dry-run
keenetic --router home interface -i
```

`up` and `down` check that the interface exists, apply the state, and verify it the same way the interactive path does.

The interactive selector includes inactive interfaces so you can reconnect them. It uses fzf when installed, with an arrow-key fallback that adapts when the terminal is resized. The action menu offers Connect, Disconnect, Inspect, and Cancel; Inspect shows the same details as `interface show ID`, and `interface show --interactive` goes straight to that. Cancel either selector to leave the router unchanged. `--dry-run` previews the selected action without writing to the router.

Connect enables the selected interface; Disconnect disables it. The command checks the interface still exists, applies the requested state, and verifies it with up to four reads over one second. It reports the resulting connection status separately: an enabled interface can still be disconnected while waiting for a VPN peer or physical link. Disabling the interface carrying your router connection can interrupt access and prevent verification. Changes affect the running configuration; this command does not explicitly save the startup configuration.

The implementation uses structured RCI `interface up` / `no up` commands, preserving interface IDs containing `/` as a single JSON key. See the [Keenetic command reference, section 3.29.213](https://storage.googleapis.com/docs.help.keenetic.com/cli/4.1/en/cli_manual_kn-2410.pdf#page=293) and the [RCI request examples](https://github.com/salatmaster/keenetic-mcp/blob/main/docs/rci-api.md#interfaces).

### Client names and configuration persistence

```bash
keenetic client rename Laptop "Work laptop" --dry-run
keenetic client rename 192.168.1.10 "Work laptop"
keenetic system changes
keenetic system changes --watch 2 --json
keenetic system save --dry-run
keenetic system save
```

Rename resolves one client by name/IP/MAC, sends a structured name update, and verifies the name by MAC with up to four reads. Names may contain spaces and Unicode; control characters and names longer than 255 characters are rejected. An unchanged name produces no write. Rename affects the running configuration; use `system save` to persist it.

`system changes` reports the last change's date, agent/user, unsaved flag, and fail-safe status. `system save` sends one save request and verifies that `unsaved` becomes false, with up to four checks over three seconds. An already-saved configuration produces no write. If save state is unavailable, it fails rather than claiming persistence. Saving persists all currently pending router configuration changes. Rename and save support `--dry-run` and `--quiet`; they reject `--watch` and `--json`.

The status, mesh, station, route, and iPerf3 schemas follow the [RCI request reference](https://docs.rs/keenetic-rci/latest/keenetic_rci/request/index.html). Survey and forwarding requests are also documented in the [network](https://github.com/st412m/keenetic-mcp/blob/main/tools_network.py) and [configuration](https://github.com/st412m/keenetic-mcp/blob/main/tools_config.py) implementations. Configuration persistence and rename verification follow these [RCI notes](https://github.com/salatmaster/keenetic-mcp/blob/main/docs/rci-api.md#configuration-persistence). Endpoint availability varies with firmware and installed components.

### Reboot

```bash
keenetic system reboot
keenetic system reboot --dry-run
keenetic system reboot --yes
keenetic --router home system reboot
```

Reboot requests an immediate restart of the selected router, interrupting network access. In a terminal it first asks `Reboot ... now? [y/N]`; `--yes` (`-y`) or `--quiet` skips the question, and scripts without a terminal are not prompted. `--dry-run` authenticates and previews the target without sending the reboot request. `--quiet` also suppresses the success message. Reboot rejects `--watch` and `--json`.

The command sends one structured RCI `system reboot` request and checks the response for errors. It does not retry or wait for the router to come back. If the connection closes before a response arrives, it reports an uncertain outcome with a nonzero exit code; the router may already be rebooting. It does not explicitly save pending configuration changes before restarting.

See the [Keenetic CLI reboot command](https://support.keenetic.com/explorer/kn-1613/en/18480-command-line-interface--cli-.html) and [RCI reboot request implementation](https://github.com/st412m/keenetic-mcp/blob/main/tools_system.py).

## Automation

Suppress successful mutation output:

```bash
keenetic policy --quiet --client Laptop --policy Direct
```

Print sanitized connection, endpoint, client-count, policy-count, authentication-path, and verification diagnostics to stderr:

```bash
keenetic policy --verbose --json
```

Verbose output never includes the configured password, challenge digest, response hash, or session cookie.

### Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success, cancellation, or requested state already active |
| 1 | Configuration, authentication, connection, API, or action failure |
| 2 | Invalid command-line arguments |
| 3 | Client not found or ambiguous |
| 4 | Policy not found or ambiguous |
| 5 | Router accepted a mutation but the bounded read-back verification failed |

## Development

Run syntax checks, ShellCheck when installed, and the HTTP/HTTPS mock-router regression suite:

```bash
make check
```

Run the opt-in, read-only contract check against a real router:

```bash
KEENETIC_CONFIG=~/.config/keenetic-policy/config make check-router
```

The contract check only calls listing endpoints and validates the public JSON schema. It never sends a client mutation.

Build deterministic release artifacts (requires GNU `tar`, GNU `gzip`, and `sha256sum`; on macOS, `brew install gnu-tar gzip coreutils`):

```bash
make release
```

Tags matching `v*` run the full suite, verify that the tag matches the script version, and publish the generated artifacts through GitHub Actions.

## API reference

Authentication and client-policy endpoints follow the implementation in [Toxblh/Keenetic-Manager](https://github.com/Toxblh/Keenetic-Manager/blob/master/src/api/keenetic_router.py).

## License

MIT. See [LICENSE](LICENSE).
