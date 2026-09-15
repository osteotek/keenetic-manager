# Changelog

## 1.2.0 - 2026-09-15

- Add refreshable read-only views with `--watch SECONDS`, terminal cleanup, and NDJSON snapshots.
- Add `clients inspect` with policy, Wi-Fi link details, and recent traffic.
- Add `system` with firmware, uptime, CPU, memory, and connection-table usage.
- Add `vpn peers` with WireGuard status, handshake age, endpoints, and counters; exclude private keys.
- Add `wifi monitor` with three-minute radio channel utilization.
- Add `policy inspect` with ordered interfaces, priorities, state, and assigned clients.
- Add bounded `logs` snapshots and router-side `diagnose` ping/traceroute with cancellation.

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
