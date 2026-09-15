# Changelog

## 1.1.3 - 2026-09-15

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
