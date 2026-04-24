# Forwarding Linux VM syslog to Synology Log Center

**Target**: `synology.michaelpmcd.com:514/UDP` (RFC 3164 BSD, Log Center default)
**Scope**: Ubuntu / Debian VMs running rsyslog (default on Ubuntu 24.04)

## Architecture

Each VM's rsyslog service forwards all syslog traffic over UDP/514 to the Synology, which runs Log Center's "Log Receiving" service. Logs land as SQLite databases under `/volume4/Backups/logs/<hostname>/SYNOSYSLOGDB_<hostname>.DB` and are readable from any NFS client that mounts `/volume4/Backups`. The laptop already has that mount at `/media/Backups/`.

## Prerequisites (Synology side — verified 2026-04-15, already in place)

- Log Center package installed — `LogCenter 1.3.1-2016`
- Log Receiving rule with:
  - Transport: UDP
  - Port: 514
  - Format: RFC 3164 (BSD)
  - Archive location: `/volume4/Backups/logs/`
- Synology firewall allows UDP/514 from management + server VLANs

No Synology-side changes required for new VMs.

## Per-VM configuration

On each Ubuntu/Debian VM:

1. Create `/etc/rsyslog.d/90-synology.conf`:
   ```
   # Forward all syslog to Synology Log Center (UDP, RFC 3164)
   *.* @synology.michaelpmcd.com:514
   ```
   **Important**: one `@` = UDP, two `@@` = TCP. We use UDP because Log Center's default receiver is UDP.

2. Restart rsyslog:
   ```
   sudo systemctl restart rsyslog
   sudo systemctl status rsyslog --no-pager
   ```

3. Generate a test log entry:
   ```
   logger -t test "forwarding test from $(hostname) at $(date -Is)"
   ```

4. From the laptop, confirm the new directory appears within ~30 seconds:
   ```
   ls /media/Backups/logs/<hostname>/
   ```
   You should see `SYNOSYSLOGDB_<hostname>.DB` and the test entry inside.

## Hostname consistency

rsyslog uses the kernel's hostname (from `hostname -f`) as the source field in syslog packets. Log Center creates the log directory based on that field — NOT DNS. If the VM's hostname doesn't match its canonical DNS name, the log directory will have the mismatched name.

**Fix**: either set `/etc/hostname` to the canonical FQDN, or override in rsyslog only by adding to `/etc/rsyslog.d/01-local.conf`:

```
$LocalHostname <correct-fqdn>
```

The rsyslog override is preferred when other services on the VM depend on the current hostname and you don't want to disturb them.

## TLS (optional, recommended long-term)

Synology Log Center supports TLS over TCP/6514. Benefits: authenticated, encrypted, tamper-evident transport. Requires both sides to trust the same CA — you already have step-ca, so cert issuance is cheap.

### Synology side

1. Log Center → Log Receiving → Create Rule
2. Transport: TCP
3. Port: 6514
4. Enable "Secure connection (SSL/TLS)"
5. Upload the step-ca-issued cert for `synology.michaelpmcd.com` (or let Synology use its existing one)
6. Archive location: same path
7. Save

### VM side

```bash
sudo apt install rsyslog-gnutls
```

Then replace `/etc/rsyslog.d/90-synology.conf` with:

```
# TLS-encrypted forward to Synology Log Center
$DefaultNetstreamDriverCAFile /etc/ssl/certs/mchomelab-root.pem
$DefaultNetstreamDriver gtls
$ActionSendStreamDriverMode 1
$ActionSendStreamDriverAuthMode x509/name
$ActionSendStreamDriverPermittedPeer synology.michaelpmcd.com

*.* @@(o)synology.michaelpmcd.com:6514
```

Notes:
- `@@(o)` = TCP with octet-framed transport (the robust mode for TLS)
- `mchomelab-root.pem` must be the step-ca root CA that signed the Synology cert
- `ActionSendStreamDriverPermittedPeer` pins the expected server name — prevents MITM by a different cert signed by the same CA

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No directory appears under `/media/Backups/logs/<hostname>/` | UDP packet dropped upstream, Log Center receiver not active, or firewall | Check Synology Log Center UI, firewall rules, and `tcpdump -i any udp port 514` on Synology |
| Directory appears but timestamps wrong | VM clock drift (unlikely — chrony role handles NTP fleet-wide) | Verify with `timedatectl` on the VM |
| Hostname mismatch | See "Hostname consistency" above | Set `$LocalHostname` in rsyslog |
| Logs arrive but aren't indexed in Log Center UI | Index rebuild in progress | Wait 5-10 min; check Log Center → Log Search after |
| UDP packets visible on Synology but no rows in DB | Log Center parser rejected the format | Check VM rsyslog format — some non-standard senders need RFC 5424 instead; switch Log Center receiver to "IETF" |

## References

- `/etc/rsyslog.conf` man page (`man rsyslog.conf`)
- Synology Log Center user guide: https://kb.synology.com/en-global/DSM/help/LogCenter
- RFC 3164 (BSD syslog format)
- RFC 5424 (structured syslog)
