# Research Brief: HP OfficeJet 8710 Certificate Upload via EWS

## Ground Rules

You may create scratch scripts, test apps, sample Ansible playbooks, and any other files you like in `/tmp/` or a new scratch directory.

**You may NOT modify any existing files in this repository (`/home/mmcdonnell/workspace/McHomeLab/`) or the inventory repo (`/home/mmcdonnell/workspace/McHomeLab-Inventory/`).**

---

## Current State

We have a working Step-CA certificate automation pipeline for Synology NAS appliances. Now we need to extend it to an HP OfficeJet 8710 printer.

The printer is on the IoT VLAN and accessible from the controller (localhost/Ansible workstation). No cross-VLAN firewall issues are expected — if you hit connectivity problems, note them and work around them.

---

## Environment

- **Controller**: localhost (Ubuntu, runs Ansible)
- **Ansible version**: ansible-core 2.19
- **Target**: HP OfficeJet 8710 at `192.168.3.253`
- **EWS ports**: 80 (HTTP) and 443 (HTTPS) — verify which are actually open
- **EWS credentials**: Unknown — check if default (no auth, or admin/blank). The printer may have a configured admin password. Try common defaults first.
- **Tools available on controller**: `curl`, `python3`, `openssl`, `step` CLI

Step-CA cert files will be issued by the existing `step-ca-cert` Ansible role. For testing, you'll generate your own certs. The LIVE cert files (once issued) would be at:
- Leaf cert: `/home/mmcdonnell/.mhl/printer/cert.pem`
- Private key: `/home/mmcdonnell/.mhl/printer/key.pem`
- Root CA: `/home/mmcdonnell/.mhl/util/root_ca_cert`
- Intermediate CA: `/home/mmcdonnell/.mhl/util/intermediate_ca_cert`

---

## What We Think We Know (From Earlier Research — VERIFY ALL OF THIS)

These findings are from earlier research and may be wrong. Verify each one against the actual printer:

1. **Upload URL**: `/Security/DeviceCertificates/NewCertWithPassword/Upload?fixed_response=true`
2. **MUST use IP address** (not hostname) in the URL — known firmware quirk
3. **PFX/PKCS12 format required** — leaf cert + key only, NO CA chain in the PFX
4. **ECC certs silently ignored** — must use RSA
5. **Printer may need power cycle** to activate the new cert
6. **No documented public API** — community-discovered endpoint

---

## Research Mission

### Phase 1 — Reconnaissance

Before touching the printer, gather information:

1. **Port scan**: What ports are actually open on 192.168.3.253? (80, 443, 631/IPP, 9100/RAW, etc.)
2. **EWS access**: Can you reach the EWS web interface? `curl -sk https://192.168.3.253/` and `curl -s http://192.168.3.253/`
3. **Authentication**: Does the EWS require a password? Try accessing pages without auth. Check `/DeviceStatus/DeviceStatusSummary` or similar status pages.
4. **Current cert**: What cert is the printer currently serving? `openssl s_client -connect 192.168.3.253:443 </dev/null 2>&1 | grep -E "subject=|issuer="`
5. **Firmware version**: Find the printer's firmware version from the EWS status page
6. **EWS API exploration**: Spider the security/certificate pages to find the actual upload endpoint. Try:
   - `https://192.168.3.253/Security/DeviceCertificates/`
   - `https://192.168.3.253/hp/device/DeviceCertificates`
   - `https://192.168.3.253/Security/DeviceCertificates/NewCertWithPassword/Upload`
   - Check for any CSR generation endpoint too

### Phase 2 — Research (Web Sources)

Search aggressively for:
- `HP OfficeJet 8710 EWS certificate upload curl`
- `HP printer EWS SSL certificate API PKCS12`
- `HP EWS DeviceCertificates Upload automation`
- `HP printer certificate renewal ansible`
- Any GitHub repos/gists that automate HP printer cert management
- HP EWS documentation (official or community-reverse-engineered)

Key questions to answer:
- What is the exact multipart form POST format for cert upload?
- What field names does the form use? (`file`? `certificate`? `pfx_file`?)
- Does it need a PFX password or can it be empty?
- What Content-Type does the upload expect?
- Does the printer auto-restart its web server after cert upload, or does it need a reboot?
- Is there an API to trigger a reboot? Or does it happen automatically?
- Can you UPDATE/REPLACE an existing cert, or must you delete the old one first?
- Is there an API to list installed certs?
- Is there an API to set a cert as the "active" cert for HTTPS?

### Phase 3 — Generate Test Cert and Upload

**Do NOT touch the production Step-CA cert files.** Generate a fresh self-signed cert in `/tmp/`:

```bash
# Generate RSA 2048 test cert (the printer requires RSA, not ECC)
openssl req -x509 -newkey rsa:2048 -keyout /tmp/printer_test_key.pem -out /tmp/printer_test_cert.pem \
  -days 30 -nodes -subj "/CN=192.168.3.253" \
  -addext "subjectAltName=DNS:printer.example.com,IP:192.168.3.253"

# Convert to PFX (PKCS12) — leaf + key only, no chain
openssl pkcs12 -export -out /tmp/printer_test.pfx \
  -inkey /tmp/printer_test_key.pem -in /tmp/printer_test_cert.pem \
  -passout pass:""
# If empty password doesn't work, try: -passout pass:changeit
```

Then figure out the correct curl command to upload it. Test thoroughly:
- Try with and without PFX password
- Try with IP in URL vs hostname
- Try different field names in the multipart form
- Try with and without authentication headers
- Check the response codes and body for success/error indicators

### Phase 4 — Verify and Restore

After uploading the test cert:
1. Check if the printer auto-restarts its web server
2. If not, find out how to trigger a restart (reboot API? manual power cycle?)
3. Verify the test cert is being served: `openssl s_client -connect 192.168.3.253:443 </dev/null 2>&1 | grep "subject="`
4. If it works, upload the ORIGINAL cert back (save it first!) or just note that the printer will get the Step-CA cert from Ansible

**IMPORTANT**: Save the printer's current certificate before overwriting it, in case we need to restore:
```bash
# Save current cert
openssl s_client -connect 192.168.3.253:443 </dev/null 2>&1 | openssl x509 > /tmp/printer_original_cert.pem
```

### Phase 5 — Write the Sample Ansible Task File

Write a sample Ansible task file at `/tmp/provision_appliance_printer.yml` that implements the complete flow. It should follow the exact pattern of the Synology task:

```yaml
---
# BTF: provision_appliance_printer.yml
# Issues a Step-CA cert and uploads it to HP EWS via REST API.

- name: "Load appliance vars"
  ansible.builtin.include_vars: "vars/appliance.yml"

- name: "Issue certificate for {{ inventory_hostname }}"
  ansible.builtin.include_role:
    name: step-ca-cert

# ... PFX conversion, upload, verify ...
```

The task should:
1. Load appliance vars and issue the cert (shared pattern)
2. Convert PEM cert+key to PFX format (using `openssl pkcs12` via `ansible.builtin.command`)
3. Upload the PFX to the printer's EWS
4. Handle any reboot/restart needed
5. Verify the new cert is being served

Use variables that match the existing project conventions:
- `ansible_host` for the printer IP
- `host_cert_path`, `host_cert_key_path` for the cert files
- Any printer-specific vars should be prefixed `printer_` and noted for addition to `vars/main.yml` and `defaults/main.yml`

**Ansible CRLF warning**: We discovered that `ansible.builtin.uri` with `body_format: form-multipart` corrupts binary files (converts `\n` to `\r\n`). If the printer upload needs multipart form data with a binary PFX file, use `ansible.builtin.command` with `curl` instead. Test both approaches.

---

## Deliverable

Write `/tmp/hp_printer_cert_findings.md` containing:

1. **Printer reconnaissance results** — ports, firmware, EWS auth, current cert
2. **The exact working curl command** for cert upload (tested against the live printer)
3. **PFX format requirements** — password, chain inclusion, key type
4. **Post-upload behavior** — auto-restart? reboot needed? API to trigger?
5. **How to list/delete existing certs** (if the EWS supports it)
6. **The sample Ansible task file** at `/tmp/provision_appliance_printer.yml`
7. **Gotchas** — IP-only quirk confirmed? auth requirements? timing issues?
8. **Whether the Ansible `uri` module works** or if curl is needed (test both)

Be aggressive. Test everything against the live printer at 192.168.3.253. Leave no open questions.