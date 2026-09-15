# Changelog

## 1.4.0 - 2026-09-15

- Reorganize commands around resources and verbs: `client list|show|rename|wake|block|unblock|assign|nat`, `policy list|show|assign|block|unblock|undo`, `interface list|show|rates|up|down`, `wifi list|clients|scan|load`, `system show|changes|save|reboot`, `nat`, `status`, and `config init|discover`. Earlier spellings keep working.
- Bare `keenetic policy` now lists policies with IDs and client counts; use `client list` for clients.
- Add non-interactive `interface up ID` and `interface down ID` with the same verification as the interactive path.
- Color status words in tables and detail views: green for online/connected/pass, yellow for offline/disconnected/not ready, red for errors and blocks, dim for unknown values.
- Fold fields the router did not report into one dim `Not reported:` line in detail views; JSON is unchanged.
- Add `policy set CLIENT... POLICY`, `policy block CLIENT...`, and `policy unblock CLIENT...` verb forms that detect names, IPs, and MACs.
- List ready-to-run commands when a client name is ambiguous, and suggest the closest command for typos.
- Ask for the password first in `--init`, with file and command sources as fallbacks; acknowledge plain HTTP once via `ROUTER_ALLOW_HTTP=true` instead of warning on every run.
- Add hints to empty views, a header row to interactive menus, and an interval/refresh-time header to `--watch`.
- Regroup `--help` by task, trim trailing spaces from table rows, capitalize narrow-screen labels, and dim `--verbose` debug lines.
- Add zsh completion (`completions/_keenetic`), installed by `make install` and the packaging definitions.
- Add `clients --interactive` to pick a client with fzf or arrow keys and show its details.
- Add pickers to `wake`, `connections`, `logs`, `wifi scan`, `diagnose`, `speedtest`, `clients rename`, `policy inspect`, `interfaces inspect`, and `policy --undo`, plus a top-level `keenetic --interactive` command menu.
- Allow `policy --interactive` and `wake --interactive` to select several clients (Tab in fzf, Space in the arrow menu) and apply one action as a batch.
- Add an Inspect action to the `interfaces --interactive` menu.
- Ask for confirmation before `system reboot` in a terminal; `--yes` or `--quiet` skips it.

## 1.3.1 - 2026-09-15

- Run on macOS: re-execute under Homebrew Bash when the system Bash is older than 4.3, fall back to `ifconfig` for local device detection, and use `route` for `--discover` when `ip` is unavailable.
- Make `make install` work with BSD `install` on macOS by creating directories with `install -d` instead of GNU-only `-D`.
- Make `make release` work on macOS by using GNU `gtar` and `gsha256sum` when installed, and refuse non-GNU tar so archives stay reproducible.
- Make the regression suite portable to macOS by using the platform `TIOCSWINSZ` ioctl and `ifconfig` for the local MAC.

## 1.3.0 - 2026-09-15

- Add WAN health with plain/encrypted DNS servers, global connection status, and reachability checks.
- Add interface inspection and sampled RX/TX rates with per-session history graphs.
- Add DHCP leases/reservations, IPv4/IPv6 routes, mesh members/backhaul, NAT connections, and forwarding rules.
- Add detailed Wi-Fi station listings and nearby network surveys.
- Add bounded router-side iPerf3 throughput tests with preview and cancellation.
- Add client renaming and configuration change/save commands with dry runs and bounded verification.
- Add `keenetic system reboot` with dry-run previews, single-request execution, and reboot response validation.

## 1.2.0 - 2026-09-15

- Add refreshable read-only views with `--watch SECONDS`, terminal cleanup, and NDJSON snapshots.
- Add `clients inspect` with policy, Wi-Fi link details, and recent traffic.
- Add `system` with firmware, uptime, CPU, memory, and connection-table usage.
- Add `vpn peers` with WireGuard status, handshake age, endpoints, and counters; exclude private keys.
- Add `wifi monitor` with three-minute radio channel utilization.
- Add `policy inspect` with ordered interfaces, priorities, state, and assigned clients.
- Add bounded `logs` snapshots and router-side `diagnose` ping/traceroute with cancellation.
- Cover jq 1.6 compatibility and responsive output with 44 integration checks.

- Add `keenetic wifi` with SSID, band, channel/width, security, client counts, and status; support compact responsive tables, `--all`, and password-free JSON.
- Show current online/offline/unknown status in traffic lists and expose nullable `online` in traffic JSON.
- Add `keenetic traffic` to rank clients by stored RX/TX totals, defaulting to the top five over three minutes; support `--top`, `--period 3m|1h|3h|1d`, compact tables, and JSON.
- Add `keenetic interfaces` with the shared interface display, JSON/all filters, and fzf or arrow-key Connect/Disconnect actions with dry runs and state verification.
- Show basic router details in a compact, responsive table above the interface lists.
- Add an online/offline status column to non-interactive policy lists, including narrow-screen layouts.
- Use the same compact, borderless formatting for non-interactive policy lists, with Unicode-aware columns and IP details below rows on narrow screens.
- Show interfaces in compact, borderless columns like the fzf client list, abbreviating long fields to terminal width and placing IP/traffic details below each row on very narrow screens.
- Show connected-client totals with wired/wireless counts in the default status view and JSON.
- Hide inactive interfaces in the default status view; add `keenetic --all` to include every interface in text or JSON output.
- Include KeenDNS hostname/access mode and per-interface received/sent traffic totals in the default view; expose packet/error/drop counters in JSON.
- Show router VPN/interface status and IPv4/IPv6 addresses when `keenetic` is run without a subcommand; support `keenetic --json` for automation.
- Add a dedicated `keenetic wake` command and shared global options before or after subcommands.
- Move client and policy operations under `keenetic policy`, keeping setup (`--init`) and discovery (`--discover`) at the top level.

- Rename the project and repository to `keenetic-manager`.
- Rename the Bash script, installed command, and standalone release executable to `keenetic`.
- Preserve existing configuration and history paths for compatibility.

## 1.1.2 - 2026-09-13

- Rename the project, local checkout, and GitHub repository to `keenetic-policy`.

## 1.1.1 - 2026-09-13

- Align name, IP, policy, and status columns in the interactive `fzf` client selector.

## 1.1.0 - 2026-09-13

- Add bounded verification retries, dry-run plans, multi-client preflight, and rollback history.
- Add client block, unblock, offline listing, and Wake-on-LAN actions.
- Use `fzf` for searchable interaction when available, with a resize-aware Unicode-safe native fallback.
- Add named router profiles, default-gateway discovery, password files, and sanitized verbose diagnostics.
- Test real HTTPS trust paths and add an opt-in read-only real-router contract check.
- Automate tagged release artifacts and add Arch, Homebrew, and Debian packaging definitions.

## 1.0.0 - 2026-09-11

- List connected Keenetic clients and their active policies.
- Select clients and policies interactively with arrow-key navigation.
- Apply verified policy changes by client name, IP address, or MAC address.
- Support JSON output, quiet automation, stable exit codes, and shell completion.
- Support plaintext or command-provided passwords and configurable HTTPS trust.
- Detect the current device by router-facing IP or local interface MAC address.
- Add secure guided configuration, installation targets, and regression tests.
