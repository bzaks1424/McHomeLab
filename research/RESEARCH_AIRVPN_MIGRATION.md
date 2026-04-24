# Research Brief: AirVPN Migration for Media Host VPN Stack

## Ground Rules

Scratch scripts and test configs are fine in `/tmp/` or a new scratch directory.
Inventory and framework changes land in `ansible/` per the plan at the bottom of this doc.
No changes to unrelated hosts/services.

---

## Current State (2026-04-20)

**Provider:** NordVPN (WireGuard) via Gluetun `v3` on `media.michaelpmcd.com`.
**Scope behind VPN:** qBittorrent only.
**Port forwarding:** disabled — NordVPN does not support PF at all, never has, never will.

**Observed consequences:**

- `docker exec compose-gluetun-1 cat /tmp/gluetun/forwarded_port` → file does not exist. Gluetun reports `{"port":0}` on `/v1/openvpn/portforwarded`.
- qBittorrent listening on 6881 internally with no inbound exposure via the tunnel.
- In a sample of 204 Seedpool torrents in qBit, **40 are stuck in `stalledDL` at 0.0% progress**, up to 5 days old. Neither side of the peer connection can initiate — both NATted.
- Those 40 register to Seedpool's tracker as "leeching" and after ~10 days get counted as **unsatisfied** (hit-and-run). Counter sits at **78**.
- Seedpool's H&R penalty ramps max-download-slots from unlimited (0 unsat) to the 1-slot floor (≥20 unsat). We are floored at 1.
- New `/torrent/download/{id}.{passkey}` requests 302-redirect to the details page → login, instead of serving a .torrent. Valid grabs from Sonarr/Prowlarr fail upstream in Prowlarr with *"Invalid torrent file contents"* because it's actually receiving the HTML login redirect.

**Paid-through:** NordVPN auto-renew is cancelled. Current contract runs until **Jan 7, 2027**; next (final) charge skipped.

**Target:** migrate to AirVPN before Jan 2027. Expand VPN scope to cover the rest of the tracker-facing container stack while we're in there.

---

## Provider Review: AirVPN

### Company / Jurisdiction

- **Operator:** Air Srl (Perugia, Italy), active since 2010. Activist-run, self-funded.
- **Jurisdiction:** Italy. Not a formal 5/9/14-eyes member; EU data-retention directive does not apply to VPN operators there.
- **Public posture:** Italian regulator (AGCOM) Piracy Shield order in 2024 — AirVPN blocked Italian customers from buying new subscriptions in protest rather than comply with site-block demands.

### Privacy Posture

- No-logs self-declaration. **No independent audit** (unlike ProtonVPN's Securitum cadence).
- 15+ years operating history. No publicly disclosed instance of user data handed to law enforcement.
- Warrant canary at https://airvpn.org/aircanary/ — updated monthly. Absence of update is the signal.

### Protocol Support

- WireGuard (preferred, default).
- OpenVPN (fallback if a Gluetun bug affects WG; see known issues).

### Port Forwarding (deep dive — the reason we're here)

- **20 static ports per account.** User-assigned via Client Area → Forwarded Ports.
- Ports are keyed to your AirVPN account, valid on any server — but **only "alive" on the server you are currently connected to**.
- Static means the port does not rotate on reconnect. One `qbittorrent.listen_port` value, set once.
- **Gluetun does not automate PF for AirVPN.** It does for PIA/Proton/PerfectPrivacy/PrivateVPN; attempting `VPN_PORT_FORWARDING_PROVIDER=airvpn` errors out. This is confirmed in gluetun-wiki issue #104.
- Manual flow: assign port in AirVPN UI → set `FIREWALL_VPN_INPUT_PORTS=<port>` in Gluetun env → point `qbittorrent.listen_port` at the same number.

### Speed

Gigabit-capable WireGuard endpoints. US coverage concentrated on east coast + Chicago + Phoenix + Miami. Expect ~500–800 Mbps single-stream on a pinned good server; real-world torrent throughput tends to be peer-bound, not VPN-bound.

### Pricing (2026)

| Term    | Price   | Effective / mo |
|---------|---------|----------------|
| 1 mo    | €7      | €7.00          |
| 3 mo    | €15     | €5.00          |
| 6 mo    | €29     | €4.83          |
| 1 yr    | €54     | €4.50          |
| 2 yr    | €79     | €3.29          |
| 3 yr    | €99     | €2.75          |

Payment: cards, PayPal, crypto (BTC/LTC/monero via BTCPay).

### Config Generation Flow

1. airvpn.org → Client Area → **Config Generator**.
2. Protocol: **WireGuard**.
3. Device: create a dedicated device (each has its own keypair — rotating the device invalidates all Gluetun env secrets).
4. Server: pick a country or a specific server. Since the forwarded port is only live on the currently-connected server, we pin one server in Gluetun regardless.
5. Advanced: leave port at default; disable IPv6 (host has no IPv6).
6. Click Generate → download `.conf`.

Map:

| `.conf` field              | Gluetun env var         |
|----------------------------|-------------------------|
| `[Interface] PrivateKey`   | `WIREGUARD_PRIVATE_KEY` |
| `[Interface] Address`      | `WIREGUARD_ADDRESSES`   |
| `[Peer] PresharedKey`      | `WIREGUARD_PRESHARED_KEY`|
| `[Peer] Endpoint` host     | not used — Gluetun picks from bundled server list via `SERVER_NAMES` / `SERVER_COUNTRIES` |

`PublicKey`, `AllowedIPs`, `DNS`, `MTU` are **not** consumed by Gluetun.

### Known Gluetun + AirVPN Issues (open as of 2026-04)

- **gluetun-wiki #104** — AirVPN PF not auto-implemented. Documented, intentional.
- **gluetun #3003** — WireGuard + AirVPN PF reported failing end-to-end for some users on certain servers, while OpenVPN works. No merged fix. Mitigation: if PF appears closed after setup, swap `VPN_TYPE` to `openvpn`.
- **gluetun #2719** — multi-port `FIREWALL_VPN_INPUT_PORTS` (comma-separated) silently breaks. Use a single port.
- **gluetun #2667** — `SERVER_COUNTRIES` / `SERVER_CITIES` filter has had AirVPN-specific connect failures in the past. Safer to pin with `SERVER_NAMES`.

---

## Architectural Decisions

### Containers behind Gluetun (expand from current qBit-only)

| Service      | Role                              | Reason for VPN |
|--------------|-----------------------------------|----------------|
| qbittorrent  | torrent client                    | peer payload hidden from ISP (same as today) |
| qbit-manage  | qBit maintenance cron             | co-located with qBit; needs qBit API access |
| qbitrr       | Sonarr/Radarr queue cleanup       | needs qBit + Arr API; stall cleanup requires live qBit conn |
| cross-seed   | private-tracker cross-seed finder | tracker API calls should come from same IP as qBit for fingerprint consistency |
| sonarr       | TV library manager                | Prowlarr proxy calls trackers; consistent IP helps |
| radarr       | movie library manager             | same as sonarr |
| prowlarr     | indexer aggregator                | **primary tracker-facing service** — same IP as qBit is the biggest single win |
| bazarr       | subtitle puller                   | mostly public APIs; co-location convenience only |
| recyclarr    | TRaSH-Guides sync                 | outbound-only to GitHub; either side fine, behind Gluetun for simplicity |

### Containers staying on host network

- **traefik** — owns host 80/443; must be host-network to reverse-proxy everything.
- **plex** — remote access, relay auth, DLNA, LAN discovery all assume a consistent public IP matching the plex.tv handshake. VPN breaks remote access.

### Server Selection

Pin a single US East-Coast server via `SERVER_NAMES` (exact name TBD at migration — pick from AirVPN's current list). Pinning is forced by PF semantics: the forwarded port is only live on one server at a time.

Do **not** use `SERVER_COUNTRIES` for AirVPN (issue #2667 + PF liveness is per-server).

### Port Allocation

Assign exactly **one** forwarded port in AirVPN Client Area. Wire it in three places:

1. `FIREWALL_VPN_INPUT_PORTS=<port>` on Gluetun.
2. `qbittorrent.listen_port=<port>` — set via qBit WebUI Preferences or qbit-manage on first boot.
3. `WEBUI_PORT` for qBit stays at 8080 (separate, WebUI-only).

Do **not** use `FIREWALL_VPN_INPUT_PORTS=<port1>,<port2>` — issue #2719 breaks silently.

### WireGuard vs OpenVPN

**Default: WireGuard.** Fallback to OpenVPN if issue #3003 manifests (port appears closed despite config correct). WireGuard is markedly faster, lower CPU, faster reconnect.

### Secrets Handling

`WIREGUARD_PRIVATE_KEY` and `WIREGUARD_PRESHARED_KEY` are sensitive. In McHomeLab, place them in Ansible Vault-encrypted `group_vars/` or pass via `ansible-vault`-encrypted `host_vars/media.michaelpmcd.com.yml`. The `test.yml` inventory carries fake literals for linting.

---

## Framework Changes Required

The existing `ansible/roles/service/templates/gluetun.yml.j2` template supports only:

- `VPN_SERVICE_PROVIDER`, `VPN_TYPE`, `WIREGUARD_PRIVATE_KEY` (if WG), `OPENVPN_USER`/`OPENVPN_PASSWORD` (if OpenVPN), `SERVER_COUNTRIES`, `FIREWALL_OUTBOUND_SUBNETS`.

It must be extended to support (all optional, emitted only when defined):

- `WIREGUARD_PRESHARED_KEY` — AirVPN requirement.
- `WIREGUARD_ADDRESSES` — AirVPN requirement.
- `SERVER_NAMES` — preferred over `SERVER_COUNTRIES` for AirVPN per issue #2667.
- `FIREWALL_VPN_INPUT_PORTS` — needed to open the forwarded port inside Gluetun's firewall.

Changes are additive and optional — existing NordVPN entries keep working unchanged.

---

## Migration Plan

### Pre-migration (manual, one-time)

1. Purchase AirVPN 1-yr or 2-yr subscription.
2. AirVPN Client Area → create device "mhl-media-gluetun" → Config Generator → WireGuard → download `.conf`.
3. AirVPN Client Area → Forwarded Ports → request one port (record the number).
4. Extract `PrivateKey`, `PresharedKey`, `Address` from the `.conf`; note the target server name (from the `Endpoint` host or pick a pinned server).

### Inventory / Ansible changes

5. Update `ansible/roles/service/templates/gluetun.yml.j2` (additive; see patch in commits).
6. Update media host entry in `ansible/inventory/test.yml` (and the real production inventory):
   - Swap `gluetun.config` block to AirVPN WireGuard fields.
   - Add `sonarr`, `prowlarr`, `bazarr`, `qbit-manage`, `qbitrr`, `cross-seed`, `recyclarr` with `network_mode: "service:gluetun"` and `depends_on: gluetun: { condition: service_healthy }`.
   - Keep `plex` (not present in test.yml) and `traefik` on host network.
7. Store AirVPN secrets in Vault; reference via `{{ vault_airvpn_private_key }}` etc.

### Apply

8. `ansible-playbook site.yml --limit media --tags services`.
9. `docker compose ... up -d --force-recreate gluetun` restarts the tunnel; dependent containers reconnect.

### Validation

Run against `media.michaelpmcd.com`:

```bash
# 1. Public IP is AirVPN, not NordVPN
docker exec compose-gluetun-1 wget -qO- http://localhost:8000/v1/publicip/ip

# 2. Tunnel up, forwarded port set
docker exec compose-qbittorrent-1 curl -s http://gluetun:8000/v1/openvpn/status
# expect: {"status":"running"}

# 3. qBit's own perceived listen port matches
curl -s -u mmcdonnell:<pw> http://qbt.media.michaelpmcd.com/api/v2/app/preferences | jq .listen_port
# expect: <the AirVPN-assigned port>

# 4. Kick a test torrent — expect transition metaDL → downloading within 2 min
# (add any well-seeded public torrent to the tv-sonarr category)

# 5. Watch stalled count drop
ssh media 'docker exec compose-sonarr-1 curl -s -b /tmp/qcookie http://gluetun:8080/api/v2/torrents/info' \
  | jq '[.[] | select(.state=="stalledDL")] | length'
```

### Backout

- Revert inventory commit, re-run ansible. NordVPN contract is still active until Jan 2027 — old config works on arrival.
- Alternately keep `nordvpn` branch of the gluetun config accessible via Git revert.

---

## Post-migration Effects Expected

- New Sonarr grabs from Seedpool: peer connections establish → download completes → torrent seeds normally → satisfies 10-day rule.
- Existing 78 unsatisfied entries: actively-seeding ones (~38) age out over the next 10 days. The stalled-0% ones (~40) are already cleaned from qBit by qbitrr (15-min StalledDelay); they stop getting re-created once new grabs actually download.
- Slot penalty easing expected ~14–21 days post-cutover, once unsatisfied drops under 20.
- Prowlarr → Seedpool: download endpoint should resume serving .torrent files (same AirVPN IP + active seeding on account = no tracker-side blocks).

---

## Cost Comparison

| Provider | Annual | PF? | Per-account ports | Audit | Note |
|----------|--------|-----|-------------------|-------|------|
| NordVPN (current) | ~$60 | ❌ | — | Deloitte 2022/2024 | Can't torrent private |
| **AirVPN** | ~$60 (€54) | ✅ static | 20 | none | The fit for this use case |
| ProtonVPN Plus | ~$72 ($50 on 2yr) | ✅ dynamic | 1 | Securitum × 4 | Port rotates → hook needed |
| PIA | ~$40 (3yr) | ✅ dynamic | 1 | Deloitte 2022/2024 | Kape-owned; fine for torrent-only scope |

---

## Sources

- gluetun-wiki setup/providers/airvpn.md — https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/airvpn.md
- gluetun-wiki setup/advanced/vpn-port-forwarding.md — https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md
- gluetun-wiki issue #104 — AirVPN PF support
- gluetun issue #3003 — AirVPN WG PF not working (open)
- gluetun issue #2719 — multi-port `FIREWALL_VPN_INPUT_PORTS` bug (open)
- gluetun issue #2667 — AirVPN `SERVER_COUNTRIES` failure (open)
- AirVPN Config Generator — https://airvpn.org/generator/
- AirVPN warrant canary — https://airvpn.org/aircanary/
- AirVPN forum: WireGuard + Gluetun discussion — https://airvpn.org/forums/topic/58214-airvpn-wireguard-through-gluetun/
