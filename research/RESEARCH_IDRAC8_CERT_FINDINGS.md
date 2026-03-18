# iDRAC8 Certificate Automation — Live Test Findings

**Date**: 2026-03-17
**Target**: Dell PowerEdge R630, iDRAC8 firmware 2.83.83.83
**Tested by**: Claude Code (automated research)

---

## 1. iDRAC IP

**192.168.255.9** — discovered via subnet scan of MGMT-P (192.168.255.0/27).

---

## 2. Firmware Version and Redfish API

| Property | Value |
|---|---|
| Firmware Version | 2.83.83.83 (build 05) |
| Model | 13G Monolithic (PowerEdge R630) |
| Redfish Version | 1.4.0 |
| Manager Type | BMC |

Redfish is available at `/redfish/v1/` and supports session-based auth (X-Auth-Token) and Basic Auth for GET requests.

---

## 3. What Works and What Doesn't

### Methods TESTED and CONFIRMED on firmware 2.83.83.83

| Method | Status | Notes |
|---|---|---|
| **Remote racadm `sslkeyupload`** | **WORKS** | Uploads private key to iDRAC |
| **Remote racadm `sslcertupload`** | **WORKS** | Uploads PEM certificate |
| **Redfish `Manager.Reset`** | **WORKS** | Reboots iDRAC (HTTP 204), requires X-Auth-Token |
| **WSMAN `ImportSSLCertificate`** | Works (action supported) | But fails with LC011 unless key already matches |
| **WSMAN `ExportSSLCertificate`** | **WORKS** | SSLCertType=1 for server cert |
| **WSMAN `SetAttribute`** | **WORKS** | Can set iDRAC.Security.* properties |
| **Racadm SSH `sslcsrgen -g`** | **WORKS** | Generates CSR on iDRAC |
| **Racadm SSH `sslcertview`** | **WORKS** | Views current cert details |

### Methods TESTED and CONFIRMED NOT WORKING

| Method | Status | Error |
|---|---|---|
| Redfish OEM `DelliDRACCardService.UploadSSLKey` | **405 Method Not Allowed** | Path exists but action not implemented |
| Redfish OEM `DelliDRACCardService.ImportSSLCertificate` | **405 Method Not Allowed** | Path exists but action not implemented |
| Redfish `CertificateService` | **400 Invalid URI** | Endpoint does not exist on this firmware |
| WSMAN `UploadSSLKey` | **CMPI_RC_ERR_NOT_SUPPORTED** | Action not implemented |
| WSMAN `SSLCSRGenerate` | **CMPI_RC_ERR_NOT_SUPPORTED** | Action not implemented |
| `ansible.builtin.uri` for cert upload | **N/A** | No working REST endpoint — must use racadm CLI |
| iDRAC8 web GUI cert APIs | **Not functional** | HTML GUI files return 404, API endpoints return null |

### Key Correction to Pre-Existing Research

The pre-existing research (`RESEARCH_IDRAC8_CERT_API.md`) stated that `ansible.builtin.uri` works for cert upload via the Dell OEM Redfish endpoints. **This is INCORRECT for firmware 2.83.83.83.** The Dell OEM cert management actions (`DelliDRACCardService`) return HTTP 405 on this firmware version. These endpoints may exist on newer iDRAC8 firmware or iDRAC9, but they are not functional on our R630.

---

## 4. The Exact Working Sequence (Tested)

### Step 1: Upload private key
```bash
racadm -r <IDRAC_IP> -u <USER> -p '<PASSWORD>' \
  sslkeyupload -f /path/to/key.pem -t 1
```
**Returns**: `SSL key successfully uploaded to the RAC.`

### Step 2: Upload certificate
```bash
racadm -r <IDRAC_IP> -u <USER> -p '<PASSWORD>' \
  sslcertupload -f /path/to/cert.pem -t 1
```
**Returns**: `DH010: Reset iDRAC to apply new certificate...`

### Step 3: Reboot iDRAC via Redfish (requires session token)
```bash
# Create session
TOKEN=$(curl -sk -D- -H "Content-Type: application/json" \
  -X POST "https://<IDRAC_IP>/redfish/v1/Sessions" \
  -d '{"UserName":"<USER>","Password":"<PASSWORD>"}' 2>/dev/null \
  | grep -i x-auth-token | awk '{print $2}' | tr -d '\r')

# Reset
curl -sk -H "X-Auth-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "https://<IDRAC_IP>/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset" \
  -d '{"ResetType":"GracefulRestart"}'
```
**Returns**: HTTP 204

### Step 4: Wait for iDRAC to come back (~3.5 min)
```bash
# Poll until responsive
until curl -sk --connect-timeout 5 "https://<IDRAC_IP>/redfish/v1/" >/dev/null 2>&1; do
  sleep 10
done
```

### Step 5: Verify
```bash
openssl s_client -connect <IDRAC_IP>:443 </dev/null 2>&1 \
  | openssl x509 -noout -subject -issuer
```

---

## 5. Whether `ansible.builtin.uri` Works

**No — not for cert upload on this firmware.**

The Dell OEM Redfish cert endpoints (`DelliDRACCardService.UploadSSLKey`, `DelliDRACCardService.ImportSSLCertificate`) return HTTP 405 (Method Not Allowed) on firmware 2.83.83.83.

The task file uses `ansible.builtin.command` with `racadm` CLI instead. The Redfish API IS used for:
- Creating a session (for the auth token)
- Rebooting iDRAC (`Manager.Reset`)
- Polling for iDRAC readiness

**Prerequisite**: The `srvadmin-idracadm8` package must be installed on the Ansible controller. Install via:
```bash
echo "deb [trusted=yes] https://linux.dell.com/repo/community/openmanage/11100/jammy jammy main" \
  | sudo tee /etc/apt/sources.list.d/dell-openmanage.list
sudo apt-get update && sudo apt-get install -y srvadmin-idracadm8
```

---

## 6. Reboot Timing

| Metric | Value |
|---|---|
| Test 1 (test cert) | 198 seconds (~3 min 18 sec) |
| Test 2 (Step-CA cert) | 206 seconds (~3 min 26 sec) |
| **Average** | **~3.5 minutes** |

---

## 7. Does iDRAC Reboot Affect ESXi VMs?

**No.** The iDRAC reboot only restarts the BMC controller. The host server (ESXi) continues running independently.

---

## 8. Sample Ansible Task File

See `provision_appliance_idrac.yml` below. Follows the existing appliance task pattern:
- Loads `appliance.yml` vars
- Calls `step-ca-cert` role
- Uses `ansible.builtin.command` with `racadm` (retries for session flakiness)
- Reboots via Redfish session + `Manager.Reset`
- Polls for readiness with `ansible.builtin.uri`

**New variables needed** (for `vars/main.yml`):
```yaml
# iDRAC appliance credentials
idrac_user: "{{ hostvars[inventory_hostname].credentials.user | default(ansible_user) }}"
idrac_password: "{{ hostvars[inventory_hostname].credentials.password | default(ansible_become_pass) }}"
```

**New defaults needed** (for `defaults/main.yml`):
```yaml
# iDRAC appliance defaults
host_idrac_racadm_retries: 5
host_idrac_racadm_retry_delay: 5
host_idrac_reboot_retries: 30
host_idrac_reboot_poll_delay: 15
```

---

## 9. Gotchas

### Session concurrency (CRITICAL)
iDRAC8 has **severe session limits** (4-6 max concurrent sessions across all interfaces — web GUI, Redfish, racadm, SSH). When limits are hit:
- Remote racadm returns `ERROR: Login failed - invalid username or password` (misleading)
- Web GUI returns `authResult: 5` ("maximum number of user sessions has been reached")
- Redfish returns HTTP 401

**Mitigation**: The Ansible task uses `retries` + `delay` on racadm commands. In testing, commands typically succeed within 1-3 attempts.

### Remote racadm is REQUIRED
The `srvadmin-idracadm8` package must be pre-installed on the Ansible controller. This is an external dependency not present by default. The package is ~50MB with dependencies from Dell's APT repository.

### Redfish POST requires session auth
Redfish write operations (POST, PUT, DELETE) require session-based auth with `X-Auth-Token`. Basic Auth only works for GET. The Ansible task creates a Redfish session, captures the token, and uses it for the `Manager.Reset` POST.

### CSR-based flow is impractical
While the iDRAC can generate CSRs (via racadm `sslcsrgen -g`), there's **no programmatic way to download the CSR content** on firmware 2.83.83.83.

The key+cert upload flow is the only viable approach.

### Certificate format
- Private key: PEM format, RSA, no passphrase
- Certificate: PEM format (X.509 Base64 encoded)
- Type flag `-t 1` = server certificate

### iDRAC reboot is mandatory
The new certificate does NOT take effect until iDRAC is rebooted. The `sslcertupload` command explicitly states this.

### racadm security warning
Remote racadm prints `Security Alert: Certificate is invalid - self-signed certificate` on every invocation. This is expected (we're replacing the very cert being validated). The `-S` flag would suppress execution on cert errors — do NOT use it.

---

## 10. Decision: Deferred

This implementation was **deferred** as of 2026-03-17. The risk/reward ratio is poor:
- Requires installing Dell-specific packages (`srvadmin-idracadm8`) on the controller
- 3.5-minute iDRAC reboot for a cert change on a rarely-used BMC
- The R630 is powered off most of the time to save power
- Self-signed cert on iDRAC is acceptable for BMC management

The research and sample Ansible task are preserved here for future reference if the decision is revisited.
