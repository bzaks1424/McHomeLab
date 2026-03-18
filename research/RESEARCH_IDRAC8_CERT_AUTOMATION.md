# Research Brief: iDRAC8 (Dell R630) Certificate Automation via Redfish API

## Ground Rules

You may create scratch scripts, test apps, sample Ansible playbooks, and any other files you like in `/tmp/` or a new scratch directory.

**You may NOT modify any existing files in this repository (`/home/mmcdonnell/workspace/McHomeLab/`) or the inventory repo (`/home/mmcdonnell/workspace/McHomeLab-Inventory/`).**

---

## Current State

We have a working Step-CA certificate automation pipeline for two appliances:
- **Synology NAS** — cert upload via DSM REST API (import-by-ID, curl)
- **HP OfficeJet 8710** — cert upload via EWS PFX upload (curl)

Now we need to extend it to the Dell R630's iDRAC8 BMC.

---

## Pre-Existing Research

**Read this file first — it has extensive research already done:**

`/home/mmcdonnell/workspace/McHomeLab/RESEARCH_IDRAC8_CERT_API.md`

Key findings from that research:
- iDRAC8 supports Redfish at firmware 2.40.40.40+
- Dell OEM endpoints for cert management: `DelliDRACCardService.UploadSSLKey` + `DelliDRACCardService.ImportSSLCertificate`
- Two-step process: upload key first, then import cert (Method A — PEM)
- iDRAC8 **requires reboot** after cert import (2-5 min downtime)
- `ansible.builtin.uri` works perfectly (JSON body, no multipart needed — no CRLF bug!)
- Default credentials: `root` / `calvin`
- Enterprise license confirmed on this R630
- The `dellemc.openmanage` collection dropped iDRAC8 support in v10 — use `ansible.builtin.uri` directly

**VERIFY all of the above against the live iDRAC.**

---

## Environment

- **Controller**: localhost (Ubuntu, runs Ansible)
- **Ansible version**: ansible-core 2.19
- **Target**: Dell PowerEdge R630 iDRAC8
- **iDRAC IP**: **UNKNOWN** — see Phase 1 below. The R630 is `esxi04` in the VMware cluster. The iDRAC has its own management IP on the MGMT-P network (192.168.255.0/27). Future planned IP is `192.168.255.9`.
- **Default credentials**: `root` / `calvin` (may have been changed)
- **Tools available**: `curl`, `python3`, `openssl`, `step` CLI

The ESXi hosts on MGMT-P are:
- esxi01, esxi02, esxi03 (NUC), esxi04 (R630 — this is the one with iDRAC)
- MGMT-P subnet: 192.168.255.0/27

Step-CA cert files will be issued by the existing `step-ca-cert` Ansible role. For testing, generate your own certs.

---

## Research Mission

### Phase 1 — Find the iDRAC

The iDRAC IP is unknown. Find it:

1. **Scan the MGMT-P subnet** for iDRAC web interfaces:
   ```bash
   # Look for HTTPS on common ports in the MGMT-P range
   # iDRAC defaults to port 443
   for ip in 192.168.255.{1..30}; do
     curl -sk --connect-timeout 2 "https://$ip/redfish/v1/" 2>/dev/null | grep -q "Dell" && echo "iDRAC found at $ip"
   done
   ```
2. Or check `nmap` if available
3. Or check the ESXi host's IPMI/BMC network settings via SSH to esxi04

Record the iDRAC IP for all subsequent steps.

### Phase 2 — Reconnaissance

1. **Verify Redfish is available**: `curl -sk -u root:calvin https://<IDRAC_IP>/redfish/v1/`
2. **Get firmware version**: `curl -sk -u root:calvin https://<IDRAC_IP>/redfish/v1/Managers/iDRAC.Embedded.1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('FirmwareVersion'))"`
3. **Check current cert**: `openssl s_client -connect <IDRAC_IP>:443 </dev/null 2>&1 | grep -E "subject=|issuer="`
4. **Verify cert management endpoints exist**: Check the Dell OEM service document at `/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService`
5. **Check allowable cert types**: Look for `CertificateType@Redfish.AllowableValues`

### Phase 3 — Test Certificate Upload

**Save the current cert first** (in case we need to understand what was there):
```bash
openssl s_client -connect <IDRAC_IP>:443 </dev/null 2>&1 | openssl x509 > /tmp/idrac_original_cert.pem
```

**Generate a test cert:**
```bash
openssl req -x509 -newkey rsa:2048 -keyout /tmp/idrac_test_key.pem -out /tmp/idrac_test_cert.pem \
  -days 30 -nodes -subj "/CN=idrac.example.com" \
  -addext "subjectAltName=DNS:idrac.example.com,IP:<IDRAC_IP>"
```

**Test the two-step upload (Method A from the research):**

1. Upload the private key via `DelliDRACCardService.UploadSSLKey`
2. Import the certificate via `DelliDRACCardService.ImportSSLCertificate`
3. Reboot iDRAC via `Manager.Reset`
4. Wait for iDRAC to come back (poll `/redfish/v1/Managers/iDRAC.Embedded.1`)
5. Verify the test cert is being served

**Key questions to answer from testing:**
- Does `ansible.builtin.uri` work for this? (It should — JSON body, no multipart)
- What status codes does the key upload return? (200? 202?)
- What status codes does the cert import return?
- How long does the iDRAC reboot take? (Research says 2-5 min)
- Does the reboot affect ESXi VMs? (It should NOT — iDRAC reboot only restarts the BMC, not the host)
- What happens if you upload a cert without uploading the key first?
- What happens if the cert and key don't match?

### Phase 4 — Restore the Working Cert

After confirming the test flow works, upload the Step-CA cert using the real cert files:

```bash
KEY=/home/mmcdonnell/.mhl/idrac/key.pem     # Will exist after step-ca-cert role runs
CERT=/home/mmcdonnell/.mhl/idrac/cert.pem
```

Note: these files won't exist yet — you'll need to issue a cert first via the step CLI:
```bash
mkdir -p /home/mmcdonnell/.mhl/idrac
step ca certificate idrac.example.com \
  /home/mmcdonnell/.mhl/idrac/cert.pem /home/mmcdonnell/.mhl/idrac/key.pem \
  --provisioner ansible \
  --provisioner-password-file /dev/stdin \
  --ca-url https://ca.util.example.com \
  --kty RSA --size 2048 \
  --not-after=43800h \
  --san idrac.example.com \
  --san <IDRAC_IP> \
  --force <<< "<PASSWORD>"
```

Upload this cert to iDRAC and verify it's being served with the correct issuer.

### Phase 5 — Write the Sample Ansible Task File

Write `/tmp/provision_appliance_idrac.yml` following the exact pattern of the existing appliance tasks. Reference these files for the conventions:

- `/home/mmcdonnell/workspace/McHomeLab/ansible/roles/host/tasks/provision_appliance_synology.yml`
- `/home/mmcdonnell/workspace/McHomeLab/ansible/roles/host/tasks/provision_appliance_printer.yml`
- `/home/mmcdonnell/workspace/McHomeLab/ansible/roles/host/vars/appliance.yml`
- `/home/mmcdonnell/workspace/McHomeLab/ansible/roles/host/vars/main.yml`
- `/home/mmcdonnell/workspace/McHomeLab/ansible/roles/host/defaults/main.yml`

The task file should:
1. Load appliance vars and issue the cert (shared pattern)
2. Upload private key via Redfish (`ansible.builtin.uri` — JSON body, should work without CRLF issues)
3. Import certificate via Redfish (`ansible.builtin.uri`)
4. Reboot iDRAC via Redfish
5. Wait for iDRAC to come back online (poll with retries)
6. The validate check (`community.crypto.get_certificate`) will handle verification

Use variables that match existing conventions:
- Credentials from `hostvars[inventory_hostname].credentials.user` / `.password`
- Cert paths from `host_cert_path`, `host_cert_key_path` (in `appliance.yml`)
- Any iDRAC-specific vars prefixed `idrac_` and noted for addition to `vars/main.yml` and `defaults/main.yml`

Also produce a sample inventory entry for the iDRAC host at `/tmp/idrac_inventory_entry.yml`.

---

## Deliverable

Write `/tmp/idrac_cert_findings.md` containing:

1. **The iDRAC IP** discovered in Phase 1
2. **Firmware version** and Redfish API availability
3. **The exact working curl sequence** — key upload, cert import, reboot, verify (tested)
4. **Whether `ansible.builtin.uri` works** (expected: yes, since it's JSON not multipart)
5. **Reboot timing** — how long does iDRAC take to come back?
6. **Does iDRAC reboot affect ESXi VMs?** (expected: no)
7. **The sample Ansible task file** at `/tmp/provision_appliance_idrac.yml`
8. **The sample inventory entry** at `/tmp/idrac_inventory_entry.yml`
9. **Gotchas** — auth issues, cert format requirements, error codes, etc.

Be aggressive. Test everything against the live iDRAC. Leave no open questions. The output should be directly mergeable into the McHomeLab codebase.