# Upstream API research

Researched 2026-09-15 against [Toxblh/Keenetic-Manager at a415b52](https://github.com/Toxblh/Keenetic-Manager/tree/a415b521bfc53460a5a11fb083bf86adfd4b2f23), whose latest master commit was dated 2026-06-25. Compared with the current local working tree, including its existing uncommitted changes.

This document preserves the initial source-code inventory and proposal, before the v1.2.0 implementation. The inventory itself used source inspection only. Subsequent work added interface/KeenDNS status, WireGuard peers, traffic, Wi-Fi, client/policy inspection, live views, and diagnostics; see README.md for the current commands. Domain-based routing remains deferred.

## Main findings

The current CLI already implements upstream's authentication, client listing, policy assignment/reset, Internet blocking, and Wake-on-LAN. It also adds batch preflight, dry runs, read-back verification, undo history, and explicit TLS controls.

The largest missing feature is DNS-based routing: managing domain lists and selecting the VPN interface through which their traffic should travel. Smaller additions are interface status, WireGuard peer inspection, and discovering LAN/KeenDNS addresses.

Upstream is a router API client, not a separate API server. It uses the router's HTTP JSON RCI interface and cookie-based authentication. A second integration downloads community domain lists from GitHub/jsDelivr.

## Router API inventory

### Already used here

| Method | Endpoint | Purpose |
|---|---|---|
| GET, POST | `/auth` | Challenge-response login and session cookies |
| GET | `/rci/show/ip/hotspot/host` | Client inventory and link state |
| GET | `/rci/show/rc/ip/hotspot/host` | Client policy/access assignments |
| GET | `/rci/show/rc/ip/policy` | Existing policy definitions |
| POST | `/rci/ip/hotspot/host` | Assign/reset policy; block/permit a client |
| POST | `/rci/ip/hotspot/wake` | Wake-on-LAN by MAC |

Source: [upstream router adapter](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/api/keenetic_router.py). Local implementation: `keenetic`, functions `authenticate`, `fetch_router_state`, `apply_client_action`, and `wake_client`.

Authentication computes `MD5(username:realm:password)`, then `SHA256(challenge + md5_hex)`, and posts the login and resulting hash to `/auth`. The current implementation already follows this flow.

### Available in upstream, missing here

| Method | Endpoint | Upstream use | Possible CLI addition |
|---|---|---|---|
| GET | `/rci/show/interface` | Interface ID, description, type, connected state; filters VPN types | `keenetic interfaces --json` |
| GET | `/rci/show/interface/Wireguard` | Retrieve WireGuard interface/peer data | `keenetic wireguard peers --json` |
| GET | `/rci/sc/interface/Bridge0/ip/address` | Read the LAN bridge address | `keenetic router info` |
| GET | `/rci/ip/http/ssl/acme/list/certificate` | Extract certificate domain names as KeenDNS address candidates | Router metadata and connection selection |
| GET | `/rci/object-group/fqdn` | Read domain groups and their members | `keenetic routes list --json` |
| GET | `/rci/dns-proxy/route` | Read domain routing rules, interfaces, indices | Route listing/selection |
| POST | `/rci/` | Batch structured show commands, configuration commands, or CLI `parse` commands | Route changes and fewer read round trips |

Sources: [router adapter](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/api/keenetic_router.py), [DNS route adapter](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/api/keenetic_dns.py).

The certificate endpoint is not a comprehensive KeenDNS configuration API. `Bridge0` is an upstream assumption that should be checked on other network layouts. The WireGuard response schema needs a real-router fixture before promising particular peer statistics.

## DNS routing capabilities and request shapes

Upstream implements manual list creation, domain replacement, interface changes, route enable/disable, deletion, community-list sync, and route/metadata repair. The actual feature is exposed through its Routes page. [DNS route UI](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/pages/dns_routes.py)

Its preferred read is one POST to `/rci/` containing three structured commands:

- `show sc object-group fqdn`
- `show sc dns-proxy route` — specifically to retain the configured disable flag
- `show interface details=yes trait=Ip`

These are nested JSON objects, not CLI strings. The adapter accepts list-shaped or merged responses and falls back to individual GET requests. Firmware response variations need fixtures rather than assumed equivalence.

Writes to `/rci/` use two forms:

- Structured JSON under `object-group.fqdn`, `dns-proxy.route`, and `system.configuration.save`.
- Objects with a `parse` string containing a router CLI command.

The implemented operations include:

| Operation | Upstream command or JSON fields |
|---|---|
| Create a list/member | `object-group fqdn NAME`; `object-group fqdn NAME include DOMAIN` |
| Bind a list to an interface | `dns-proxy route object-group NAME INTERFACE auto`; structured route fields `group`, `interface`, `auto: true` |
| Replace members | Clear `include` using `no: true`, then supply an array of `{address: DOMAIN}` |
| Enable/disable a route | `dns-proxy.route.disable` with `index` and `no`; `no: true` removes disable |
| Remove a route | Structured route fields `group`, optionally `interface`, and `no: true` |
| Delete a list | `no object-group fqdn NAME` after removing its route |
| Persist configuration | `system configuration save`, or its structured JSON equivalent |

Upstream splits lists into 300-member groups and sends batches of 50 commands. These are implementation constants, not verified universal router limits. It names groups `rt_N` and encodes source, interface, sync date, and batch in descriptions. [Implementation](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/api/keenetic_dns.py#L264)

Keenetic documents DNS-based routing in KeeneticOS 5.0, with lists targeting an interface or gateway. It automatically includes subdomains. Feature-probe the endpoints before enabling this command family. [Keenetic manual](https://support.keenetic.com/sprinter/kn-3711/en/51150-dns-based-routes.html)

## External domain-list integration

The upstream `v2fly.py` adapter uses:

- jsDelivr's package API to enumerate `v2fly/domain-list-community` data files.
- jsDelivr and GitHub raw URLs to download a selected list.
- GitHub's commits API to check a list's last change date.
- An in-memory 24-hour list-name cache and an intended bundled fallback.

This could support `keenetic routes sources search youtube` and `keenetic routes sync youtube --interface Wireguard0 --dry-run`. These are proposed commands. [Adapter source](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/api/v2fly.py)

The format includes suffix rules, exact-host rules, regular expressions, keywords, and selectively included lists. Upstream skips regex/keyword rules and strips the distinction between `full:` and `domain:`. Because Keenetic includes subdomains, converting exact-host entries can broaden routing. A port should report unsupported or changed semantics and properly handle include filters. [Domain-list format](https://github.com/v2fly/domain-list-community#structure-of-data), [Keenetic matching behavior](https://support.keenetic.com/sprinter/kn-3711/en/51150-dns-based-routes.html)

## Recommended implementation order

| Order | Addition | Value and scope |
|---|---|---|
| 1 | `interfaces --json` and `routes list --json` | Inspect actual VPN connectivity and existing domain routing. Small/medium, read-only work that establishes schemas for later changes. |
| 2 | Manual route add/update/enable/disable/delete | Largest functional expansion: route selected services through a chosen VPN. Medium/large; needs feature detection, full read-back, partial-failure reporting, and configuration-save handling. |
| 3 | Domain-list preview/import/sync | Convenient service lists without hand-maintaining domains. Large; requires parser semantics, caching, deterministic splitting, and change previews. |
| 4 | `router info` and LAN/KeenDNS address selection | Easier local/remote use of named profiles. Small read-only metadata addition; medium connection-selection work. Preserve configured TLS trust and avoid silent HTTPS-to-HTTP downgrades. |
| 5 | `wireguard peers --json` | Useful diagnostics, but upstream provides only a getter and unfinished UI. Validate the schema first. |

Two useful improvements need no additional API:

- Expose existing policy definitions in a dedicated listing command; policy creation/editing is not implemented upstream.
- Include clients found only in the assignment list when building `policy --all` and resolving Wake-on-LAN targets. Upstream merges both lists by MAC; the current CLI only iterates the hotspot inventory. This is a source-observed edge case, not a confirmed failure on the user's router. Upstream also reads access/permit/priority fields that the current normalized output omits. [Upstream merge](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/api/keenetic_router.py#L116)

## Porting details that need different handling

1. **Keep listing read-only.** Upstream invokes route repair while loading/refreshing the Routes page. A CLI should make repair an explicit mutation with a preview. [Page loading](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/pages/dns_routes.py#L56)
2. **Preserve multiple routes and their order.** Upstream's repair assumes one interface per group and may delete alternatives. KeeneticOS 5.0.1 explicitly supports multiple gateways/interfaces for one group, prioritized by input order. Select a specific route for edits. [Official release notes](https://support.keenetic.com/explorer/kn-1613/en/55388-os-5-0.html)
3. **Validate command results, not just HTTP status.** Upstream batch handling logs some `parse.status` errors without failing the operation. Check nested structured errors, handle save failures, and verify the resulting state. A batch is not a transaction. [Batch handling](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/api/keenetic_dns.py#L279)
4. **Reject truncation and incomplete imports.** Manual creation slices input to 300 domains. Sync can delete excess groups when the parsed list shrinks. Resolve and validate the entire source before preparing mutations, and display skipped rules and deletions. [Manual creation](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/pages/dns_routes.py#L599), [Sync](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/api/keenetic_dns.py#L721)
5. **Use an ownership convention for managed lists.** Inspect all lists, but only sync/delete groups explicitly owned by the CLI or selected by the user. Metadata punctuation alone is too weak to establish ownership.
6. **Extend verification and history deliberately.** Existing undo stores only client policy/block state. DNS changes need snapshots of group members, route order, interface bindings, and enable state. Read-only batch POSTs also require distinguishing HTTP method from operation effects in dry-run/contract rules.
7. **Prefer structured JSON for writes.** Where CLI `parse` is needed, validate identifiers and escape router CLI strings; shell quoting alone does not protect the router command parser.

WireGuard peer creation, configuration download, and QR export are empty callbacks, and the corresponding sidebar entry is disabled. Quick Settings is a placeholder. No upstream implementations were found for router reboot, firmware management, Wi-Fi configuration, DHCP reservation changes, port forwarding, or general policy creation. These need separate API research. [Unfinished callbacks](https://github.com/Toxblh/Keenetic-Manager/blob/a415b521bfc53460a5a11fb083bf86adfd4b2f23/src/router_manager.py#L451)

## Validation for a future implementation

Start with sanitized, read-only response fixtures from the target firmware. Extend the existing mock-router suite with unsupported endpoints, batch response variants, nested command errors, configuration-save failures, and multiple ordered routes. For imports, cover selective includes, cycles, unsupported rule types, partial downloads, and empty results. Verify mutations against complete state and keep offline clients resolvable.

This research changed documentation only; application tests and live-router checks were not run.
