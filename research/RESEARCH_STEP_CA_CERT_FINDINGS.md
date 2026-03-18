# Step-CA Certificate Automation — Research Findings

## Table of Contents

1. [Step-CA Provisioner Setup & Automation Pattern](#1-step-ca-provisioner-setup--automation-pattern)
2. [Ansible Cert Issuance Pattern](#2-ansible-cert-issuance-pattern)
3. [Per-Appliance Cert Deployment](#3-per-appliance-cert-deployment)
   - [3a. Synology DSM](#3a-synology-dsm-certificate-api)
   - [3b. HP Printer EWS](#3b-hp-printer-ews-certificate-upload)
   - [3c. Dell iDRAC8](#3c-dell-idrac8-certificate-management)
   - [3d. UniFi OS](#3d-unifi-os-certificate-management)
4. [Proposed Ansible Role Structure](#4-proposed-ansible-role-structure)
5. [Idempotency Strategy](#5-idempotency-strategy)
6. [Gotchas & Blockers](#6-gotchas--blockers)

---

## 1. Step-CA Provisioner Setup & Automation Pattern

### Create a Dedicated `ansible` JWK Provisioner

**Recommendation**: Do NOT modify the `admin` provisioner. Create a separate `ansible` provisioner with its own credentials and duration limits. This provides audit trail separation, scoped duration limits, and independent key rotation.

Since the step-ca container was likely initialized without `--remote-management`, provisioner changes must be run **inside the container** (or on the CA server with access to `ca.json`):

```bash
# Inside the step-ca container:
step ca provisioner add ansible --type JWK --create \
  --x509-max-dur=2160h \
  --x509-default-dur=720h \
  --ca-config=/home/step/config/ca.json
```

This creates a new JWK provisioner with:
- Max cert duration: 2160h (90 days)
- Default cert duration: 720h (30 days)
- Its own encrypted key + password

**Save the provisioner password** to a file on the Ansible controller and encrypt it with Ansible Vault. The `step ca certificate` command accepts `--provisioner-password-file` for fully non-interactive use.

If remote management were enabled (`--remote-management` at `step ca init`), provisioner config would be stored in the CA database and manageable remotely via admin certs. But for a homelab, local config file management is simpler.

### Duration Flags Reference

| Flag | Purpose |
|------|---------|
| `--x509-min-dur` | Minimum allowed cert duration |
| `--x509-default-dur` | Default when client doesn't specify |
| `--x509-max-dur` | Maximum allowed cert duration |

Duration format: Go duration strings — `2160h` (90 days), `8760h` (1 year), `720h` (30 days).

### Bootstrapping Trust

On the Ansible controller (one-time setup):

```bash
# Get the fingerprint (run on the CA server / inside container):
step certificate fingerprint /home/step/certs/root_ca.crt

# Bootstrap trust on the controller:
step ca bootstrap \
  --ca-url https://ca.util.example.com \
  --fingerprint <FINGERPRINT> \
  --install \
  --force
```

The `--install` flag adds the root cert to the system trust store. The `--force` flag makes it idempotent.

---

## 2. Ansible Cert Issuance Pattern

### Recommended Approach: `step` CLI via `ansible.builtin.command`

There is a third-party Ansible collection (`maxhoesel.smallstep`) but it hasn't been updated since late 2023 and version-locks to specific step-cli releases. The `step` CLI itself is stable and well-documented — wrapping it in `ansible.builtin.command` is more portable and maintainable.

### Cert Issuance Command

```bash
step ca certificate <subject> <crt-file> <key-file> \
  --kty RSA --size 2048 \
  --not-after=2160h \
  --provisioner ansible \
  --provisioner-password-file /path/to/provisioner-password.txt \
  --san <additional-san> \
  --force
```

Key flags:
- `--kty RSA --size 2048` — Required. ECC silently fails on Synology and HP.
- `--not-after=2160h` — Must not exceed the provisioner's `--x509-max-dur`.
- `--provisioner ansible` — Uses the dedicated automation provisioner.
- `--provisioner-password-file` — Non-interactive auth (Vault-encrypted on controller).
- `--san` — Repeatable for additional SANs (IPs, hostnames).
- `--force` — Overwrites existing cert/key files without prompting.

### Idempotency Check Before Issuance

```yaml
- name: "Check if certificate needs renewal"
  ansible.builtin.command:
    cmd: >-
      step certificate needs-renewal
      {{ cert_path }}
      --expires-in 168h
  register: cert_renewal_check
  failed_when: cert_renewal_check.rc == 255
  changed_when: false
  delegate_to: "localhost"

# Exit codes: 0 = needs renewal, 1 = still valid, 2 = file missing
- name: "Issue certificate from Step-CA"
  ansible.builtin.command:
    cmd: >-
      step ca certificate {{ common_name }}
      {{ cert_path }} {{ key_path }}
      --provisioner ansible
      --provisioner-password-file {{ provisioner_password_file }}
      --kty RSA --size 2048
      --not-after=2160h
      --san {{ common_name }}
      --force
  delegate_to: "localhost"
  when: cert_renewal_check.rc in [0, 2]
```

The `--expires-in 168h` (7 days) threshold means certs are re-issued when less than 7 days remain. Adjust as needed.

### Alternative: `community.crypto.x509_certificate_info`

For pure-Ansible inspection without requiring `step` CLI on the controller:

```yaml
- name: "Check existing certificate"
  community.crypto.x509_certificate_info:
    path: "{{ cert_path }}"
    valid_at:
      renewal_threshold: "+7d"
  register: cert_info
  ignore_errors: true
  delegate_to: "localhost"

- name: "Issue certificate when needed"
  ansible.builtin.command:
    cmd: "step ca certificate ..."
  delegate_to: "localhost"
  when: >-
    cert_info is failed
    or cert_info.expired
    or not cert_info.valid_at.renewal_threshold
```

### Cert + Key File Handling

Certs are issued on the controller via `delegate_to: localhost`. Store them in a temp directory scoped to the playbook run, then push to each appliance via its specific API. Clean up temp files at the end.

Alternatively, store issued certs under `{{ export_root }}/<appliance_hostname>/` and register them in the registry for future reference — this fits the existing McHomeLab pattern.

---

## 3. Per-Appliance Cert Deployment

### 3a. Synology DSM Certificate API

**API**: `SYNO.Core.Certificate` REST API via `/webapi/entry.cgi`

#### Authentication Flow

```bash
# Step 1: Login — get session ID + CSRF token
curl -sk 'https://SYNOLOGY_IP:5001/webapi/entry.cgi?api=SYNO.API.Auth&version=7&method=login&format=sid&account=USERNAME&passwd=PASSWORD&enable_syno_token=yes'
```

Response:
```json
{
  "data": {
    "sid": "SESSION_ID",
    "synotoken": "CSRF_TOKEN"
  },
  "success": true
}
```

The `sid` is passed as `_sid=` query parameter. The `synotoken` must be sent as **both** `SynoToken=` query parameter **and** `X-SYNO-TOKEN` HTTP header.

#### Certificate Upload (Multipart Form)

```bash
curl -sk -X POST \
  "https://SYNOLOGY_IP:5001/webapi/entry.cgi?api=SYNO.Core.Certificate&method=import&version=1&SynoToken=${TOKEN}&_sid=${SID}" \
  -H "X-SYNO-TOKEN: ${TOKEN}" \
  -F "key=@privkey.pem;type=application/x-x509-ca-cert" \
  -F "cert=@cert.pem;type=application/x-x509-ca-cert" \
  -F "inter_cert=@chain.pem;type=application/x-x509-ca-cert" \
  -F "id=" \
  -F "desc=Step-CA Managed" \
  -F "as_default=true"
```

- `id=""` creates a new cert entry. Pass an existing cert ID to replace it.
- `as_default=true` (string, not boolean) sets it as the default cert.
- `inter_cert` is the CA chain (intermediate/root). Optional but recommended.
- DSM auto-restarts nginx/httpd after successful import.

#### Listing Existing Certs

```bash
curl -sk -H "X-SYNO-TOKEN: ${TOKEN}" \
  -d "api=SYNO.Core.Certificate.CRT&method=list&version=1&_sid=${SID}" \
  "https://SYNOLOGY_IP:5001/webapi/entry.cgi"
```

Returns array of certs with `id`, `desc`, `is_default`, `subject`, `valid_from`, `valid_till`.

#### Logout

```bash
curl -sk "https://SYNOLOGY_IP:5001/webapi/entry.cgi?api=SYNO.API.Auth&version=7&method=logout&_sid=${SID}"
```

#### Ansible Implementation

The `ansible.builtin.uri` module supports `body_format: form-multipart`, but there's a critical bug: file content is base64-encoded by default. **Fix requires ansible-core >= 2.16** which added `multipart_encoding: 7or8bit`.

```yaml
- name: "Upload certificate to Synology"
  ansible.builtin.uri:
    url: "https://{{ synology_host }}:5001/webapi/entry.cgi?api=SYNO.Core.Certificate&method=import&version=1&SynoToken={{ syno_token }}&_sid={{ sid }}"
    method: "POST"
    validate_certs: false
    headers:
      X-SYNO-TOKEN: "{{ syno_token }}"
    body_format: "form-multipart"
    body:
      key:
        filename: "privkey.pem"
        mime_type: "application/x-x509-ca-cert"
        content: "{{ lookup('file', key_path) }}"
        multipart_encoding: "7or8bit"
      cert:
        filename: "cert.pem"
        mime_type: "application/x-x509-ca-cert"
        content: "{{ lookup('file', cert_path) }}"
        multipart_encoding: "7or8bit"
      inter_cert:
        filename: "chain.pem"
        mime_type: "application/x-x509-ca-cert"
        content: "{{ lookup('file', ca_cert_path) }}"
        multipart_encoding: "7or8bit"
      id: ""
      desc: "Step-CA Managed"
      as_default: "true"
```

**Fallback for older Ansible**: Shell out to `curl` via `ansible.builtin.command`.

#### Synology Gotchas

- **CSRF token is mandatory** for write operations — must pass `enable_syno_token=yes` during login.
- **2FA/OTP**: If the admin account has 2FA, login returns error 403. Use a dedicated service account without 2FA, or use the `device_id` mechanism after first auth.
- **Session limits**: Always logout to free session slots.
- **DSM 7.0–7.2**: The certificate APIs (`SYNO.Core.Certificate`, version 1) are stable across all DSM 7.x releases. Auth API version 6 works on 7.0/7.1, version 7 on 7.2+.
- **HTTPS port 5001** by default. Use `validate_certs: false` for self-signed.

---

### 3b. HP Printer EWS Certificate Upload

**Endpoint** (newer LaserJet Pro models — M479, M404, M283, etc.):
```
POST https://<PRINTER_IP>/Security/DeviceCertificates/NewCertWithPassword/Upload?fixed_response=true
```

Older models use `/hp/device/Certificate.pfx` — verify against your specific model.

#### Format Requirements

- **PFX/PKCS12 format** — PEM not accepted at this endpoint.
- **Leaf cert + private key ONLY** — do NOT include CA chain. Including chain causes "corrupted or unsupported file format" error.
- **RSA keys only** — ECDSA causes immediate reboot with no cert installed.
- **PFX must have a password** — even a throwaway random one.

#### PEM-to-PFX Conversion

```bash
PFX_PASSWORD=$(openssl rand -base64 32)

# Leaf cert + key only, NO chain
openssl pkcs12 -export \
  -out cert.pfx \
  -inkey privkey.pem \
  -in cert.pem \
  -passout "pass:${PFX_PASSWORD}"
```

For OpenSSL 3.x compatibility with older printer firmware, add legacy flags:
```bash
openssl pkcs12 -export \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -out cert.pfx \
  -inkey privkey.pem \
  -in cert.pem \
  -passout "pass:${PFX_PASSWORD}"
```

Ansible module alternative:
```yaml
- name: "Create PFX for printer"
  community.crypto.openssl_pkcs12:
    action: "export"
    path: "/tmp/printer_cert.pfx"
    privatekey_path: "{{ key_path }}"
    certificate_path: "{{ cert_path }}"
    # Do NOT set other_certificates — leaf only
    passphrase: "{{ pfx_password }}"
    friendly_name: "printer-cert"
    state: "present"
```

#### Upload

```bash
curl -v --insecure \
  -u "admin:${EWS_PASSWORD}" \
  --form "certificate=@cert.pfx" \
  --form "password=${PFX_PASSWORD}" \
  "https://${PRINTER_IP}/Security/DeviceCertificates/NewCertWithPassword/Upload?fixed_response=true"
```

- **Authentication**: HTTP Basic Auth — `admin:<EWS_PASSWORD>`. Default password is often the WPS PIN (found on the Network Configuration Report printout).
- **Must use IP address**, not hostname — firmware quirk causes hostname-based uploads to fail silently.
- **`--insecure` required** — existing cert is self-signed.
- **`?fixed_response=true`** — bypasses JavaScript SPA framework, returns plain HTTP response for automation.

#### Post-Upload Behavior

- **Many models auto-reboot** after successful PFX upload. No user action needed.
- **No EWS endpoint exists to trigger a restart.** Physical power cycle is the only manual option.
- **Verification** (wait ~60 seconds for reboot):
  ```bash
  openssl s_client -connect ${PRINTER_IP}:443 < /dev/null 2>/dev/null \
    | openssl x509 -noout -subject -dates -issuer
  ```

#### HP EWS Gotchas

- **Including CA chain in PFX** is the #1 failure cause.
- **OpenSSL 3.x default encryption** (AES-256-CBC for PKCS12) may not be parseable by older firmware — use `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES` or `-legacy`.
- **Firmware updates can reset certs** back to self-signed and sometimes refuse new uploads (known bug in certain firmware builds).
- **Wrong PFX password** can cause the printer to delete its current keypair and then reject the new one, leaving it broken.
- **This endpoint is undocumented** — reverse-engineered from browser dev tools. It can change with firmware updates.

---

### 3c. Dell iDRAC8 Certificate Management

#### Critical Finding: `dellemc.openmanage.idrac_certificates` Does NOT Work With iDRAC8

The `idrac_certificates` module requires iDRAC firmware **5.10.10.00+** — this is **iDRAC9 only**. iDRAC8 (R630) firmware maxes out around **2.8x.8x.8x**. Confirmed in Dell GitHub issue #589: HTTP 405 errors on iDRAC8. The maintainer closed it as "not planned."

#### Recommended Approach: RACADM Commands

RACADM is the most reliable method for iDRAC8. Remote RACADM requires **Enterprise license** (common on R630s).

**Option A: CSR Flow (Recommended)**

The private key stays on the iDRAC — you only upload the signed certificate:

```bash
# 1. Generate CSR on iDRAC
racadm -r <IDRAC_IP> -u root -p <PASSWORD> sslcsrgen -g -f /tmp/idrac.csr

# 2. Sign CSR with Step-CA
step ca sign /tmp/idrac.csr /tmp/idrac_signed.pem \
  --provisioner ansible \
  --provisioner-password-file /path/to/password.txt \
  --not-after=2160h

# 3. Upload signed cert
racadm -r <IDRAC_IP> -u root -p <PASSWORD> sslcertupload -t 1 -f /tmp/idrac_signed.pem

# 4. Optionally upload CA cert for trust
racadm -r <IDRAC_IP> -u root -p <PASSWORD> sslcertupload -t 2 -f /tmp/root_ca.pem

# 5. Reset iDRAC (REQUIRED — takes 2-5 minutes)
racadm -r <IDRAC_IP> -u root -p <PASSWORD> racreset
```

Certificate type codes for `-t`:
- `1` = Server (web server SSL cert)
- `2` = CA certificate
- `3` = Custom Signing Certificate
- `4` = Client Trust Certificate

**Option B: Direct Cert + Key Import**

Newer iDRAC8 firmware may support `sslkeyupload`, but this is unreliable on older builds. Stick with the CSR flow.

#### Signing a CSR with Step-CA

Note: `step ca certificate` generates a new key pair. To sign an existing CSR (from iDRAC), use `step ca sign` instead:

```bash
step ca sign <csr-file> <crt-file> \
  --provisioner ansible \
  --provisioner-password-file /path/to/password.txt \
  --not-after=2160h
```

#### Certificate Format

- **PEM format** (base64-encoded X.509) for all RACADM cert operations.
- If you have DER: `openssl x509 -inform DER -in cert.der -out cert.pem`

#### iDRAC Reset

**Always required after cert import on iDRAC8.** The iDRAC web interface will be unavailable for 2-5 minutes during reset. Build wait/retry logic into automation.

#### License Requirements

| Feature | Express | Enterprise |
|---------|---------|------------|
| SSL cert management (CSR gen, cert import/export) | Yes | Yes |
| Web UI for cert management | Yes | Yes |
| Remote RACADM (over network) | **No** | Yes |
| Local RACADM (from host OS) | Yes | Yes |

#### Alternative: Dell WS-Man Role

Dell maintains a WS-Man-based role at `github.com/dell/redfish-ansible-module/tree/master/roles/idrac_certificate` that explicitly supports iDRAC 7/8 (firmware 2.50.50.50+). Uses SOAP/XML over WS-Man. Supports `ImportSSLCertificate`, `ExportSSLCertificate`, `GenerateSSLCSR`, `SSLResetCfg`.

#### iDRAC8 Gotchas

- **`dellemc.openmanage.idrac_certificates` will NOT work.** Don't waste time.
- **racreset takes 2-5 minutes** — connection drops during reset.
- **CSR generation invalidates old cert** — don't generate a CSR unless you're ready to complete the signing + upload flow.
- **SAN support in CSR** may not be available via RACADM on iDRAC8. If SANs are needed, generate the cert externally and attempt key+cert upload (risky on older firmware).
- **Remote RACADM file operations**: the `-f` flag reads from the machine running RACADM, not the iDRAC. For Ansible, run RACADM on the controller.
- **iDRAC8 is end-of-life** — Dell has stopped active development. Latest firmware ~2.83-2.86.

---

### 3d. UniFi OS Certificate Management

#### Critical Finding: No API for Certificate Management

UniFi OS has **no API endpoint** for uploading or managing SSL certificates. All community solutions are **file-based**: copy PEM files to the correct location, then restart the service.

#### File Locations

| Service | Cert File | Key File |
|---------|-----------|----------|
| Web frontend (unifi-core) | `/data/unifi-core/config/unifi-core.crt` | `/data/unifi-core/config/unifi-core.key` |
| RADIUS | `/data/udapi-config/raddb/certs/server.pem` | `/data/udapi-config/raddb/certs/server-key.pem` |
| Captive Portal | `/usr/lib/unifi/data/keystore` (Java Keystore) | (inside keystore) |

For the web management interface, only the first two files matter.

#### Deployment Procedure

```bash
# Copy cert files (fullchain = server cert + intermediate CA)
cp fullchain.pem /data/unifi-core/config/unifi-core.crt
cp privkey.pem /data/unifi-core/config/unifi-core.key

# Set permissions
chmod 644 /data/unifi-core/config/unifi-core.crt
chmod 644 /data/unifi-core/config/unifi-core.key

# Restart service
systemctl restart unifi-core
```

#### YAML Override (Firmware 3.2.7+)

Instead of replacing the cert files directly, create a config override pointing to your cert location:

```yaml
# /data/unifi-core/config/overrides/custom_ssl.yaml
ssl:
  crt: '/data/custom-certs/fullchain.pem'
  key: '/data/custom-certs/privkey.pem'
```

The directory `/data/unifi-core/config/overrides/` may need to be created. Still requires `systemctl restart unifi-core`.

#### Format Requirements

- **PEM format** — separate cert and key files.
- `unifi-core.crt` should contain **fullchain** (server cert + intermediate/root CA cert).
- RSA 2048 is the standard. ECDSA works but requires extra cipher config in `/usr/lib/unifi/data/system.properties`.
- Ownership: `root:root` (default).
- Permissions: `644` for both files.

#### Ansible Implementation

```yaml
- name: "Deploy certificate to UniFi OS"
  ansible.builtin.copy:
    src: "{{ cert_fullchain_path }}"
    dest: "/data/unifi-core/config/unifi-core.crt"
    mode: "0644"

- name: "Deploy key to UniFi OS"
  ansible.builtin.copy:
    src: "{{ key_path }}"
    dest: "/data/unifi-core/config/unifi-core.key"
    mode: "0644"

- name: "Restart unifi-core"
  ansible.builtin.systemd:
    name: "unifi-core"
    state: "restarted"
```

#### Podman vs Docker

Not relevant for modern firmware. UniFi OS 3.x+ removed Podman — all services run natively. Certificate file paths are the same regardless.

#### UniFi OS Gotchas

- **No official API** — everything is reverse-engineered. Ubiquiti can change paths/behavior in any firmware update.
- **WiFiMan breaks with custom certs on hotspot/captive portal** (firmware 3.2.7+). Only apply custom certs to the web frontend unless you're willing to lose WiFiMan.
- **Firmware upgrades may reset certificates** — certs in `/data/` generally survive, but major version jumps have been reported to reset them.
- **The `/data/` partition persists across reboots and most firmware updates** — safe location for cert storage.
- **YAML override directory** may need to be created manually.
- **Java Keystore** for captive portal uses hardcoded password `aircontrolenterprise` — but this is only needed if deploying certs to the captive portal, not just the web frontend.
- **`ubios-cert` project was archived** (March 2025) — maintainer cited "undocumented black magic" in newer firmware versions.

---

## 4. Proposed Ansible Role Structure

### Fitting Into the McHomeLab Architecture

Appliances would be defined in `hosts.yml` with `provision.type: appliance` and `provision.manager: <type>`. The BTF dispatch system would route to type-specific task files.

Cert issuance is a shared concern across all appliance types — it should be a separate role or a shared task file that runs on the controller (via `delegate_to: localhost`), with per-type deployment tasks.

### Proposed Structure

```
ansible/roles/
├── step-ca-cert/                    # Shared cert issuance role
│   ├── tasks/
│   │   └── main.yml                 # Check expiry → issue cert if needed
│   ├── vars/
│   │   └── main.yml                 # step-ca connection details
│   └── defaults/
│       └── main.yml                 # Default duration, renewal threshold, key type
│
├── host/tasks/
│   ├── configure_appliance_synology.yml    # Synology DSM cert deployment
│   ├── configure_appliance_hp_printer.yml  # HP EWS cert deployment
│   ├── configure_appliance_idrac.yml       # iDRAC8 RACADM cert deployment
│   └── configure_appliance_unifi.yml       # UniFi OS cert deployment
```

### `step-ca-cert` Role — Shared Cert Issuance

```yaml
# roles/step-ca-cert/defaults/main.yml
step_ca_cert_duration: "2160h"
step_ca_cert_renewal_threshold: "168h"
step_ca_cert_key_type: "RSA"
step_ca_cert_key_size: 2048
step_ca_cert_provisioner: "ansible"

# roles/step-ca-cert/vars/main.yml
step_ca_cert_url: "https://ca.util.example.com"
step_ca_cert_provisioner_password_file: "{{ export_root }}/step-ca-provisioner-password.txt"
step_ca_cert_dir: "{{ export_root }}/{{ inventory_hostname }}"

# roles/step-ca-cert/tasks/main.yml
# 1. Ensure cert directory exists
# 2. Check if cert needs renewal (step certificate needs-renewal)
# 3. Issue cert if needed (step ca certificate), delegate_to: localhost
# 4. Register cert/key paths as facts for the deployment task to consume
```

### BTF Configure Tasks — Per-Appliance Deployment

Each `configure_appliance_<type>.yml` would:
1. Include the `step-ca-cert` role to issue/refresh the cert
2. Deploy the cert using the appliance-specific method
3. Verify deployment

The BTF dispatch would route based on `provision.type: appliance` + `provision.manager: synology|hp_printer|idrac|unifi`.

### Example hosts.yml Entries

```yaml
synology:
  priority: 5
  ansible_host: "synology.example.com"
  provision:
    type: "appliance"
    manager: "synology"
    validate:
      port: 5001
    hardware:
      dns:
        domain: "example.com"
    cert:
      common_name: "synology.example.com"
      sans:
        - "synology.example.com"
      # Synology-specific
      dsm_port: 5001
      dsm_user: "admin"         # or vault reference
      dsm_password: "!vault |"  # encrypted
      set_default: true

hp_printer:
  priority: 50
  ansible_host: "192.168.20.50"
  provision:
    type: "appliance"
    manager: "hp_printer"
    validate:
      port: 443
    cert:
      common_name: "printer.example.com"
      sans:
        - "printer.example.com"
        - "192.168.20.50"
      ews_password: "!vault |"  # encrypted

esxi_idrac:
  priority: 5
  ansible_host: "idrac.example.com"
  provision:
    type: "appliance"
    manager: "idrac"
    validate:
      port: 443
    cert:
      common_name: "idrac.example.com"
      sans:
        - "idrac.example.com"
      idrac_user: "root"
      idrac_password: "!vault |"
      use_csr_flow: true         # iDRAC8 CSR-based flow

unifi_appliance:
  priority: 5
  ansible_host: "unifi.example.com"
  provision:
    type: "appliance"
    manager: "unifi"
    validate:
      port: 443
    cert:
      common_name: "unifi.example.com"
      sans:
        - "unifi.example.com"
      deploy_method: "file"      # file-based, no API
      use_yaml_override: false   # or true for firmware 3.2.7+
```

---

## 5. Idempotency Strategy

### Per-Phase Idempotency

**Phase 1 — Cert Issuance (shared)**:
- Use `step certificate needs-renewal --expires-in <threshold>` before issuing.
- Exit codes: `0` = needs renewal, `1` = still valid, `2` = file missing.
- Only issue when `rc in [0, 2]`.

**Phase 2 — Cert Deployment (per-appliance)**:

| Appliance | Idempotency Check |
|-----------|-------------------|
| Synology | List certs via API → check if cert with matching description exists and has the same expiry. Upload only if different. |
| HP Printer | Connect to port 443 → check served cert subject/expiry with `openssl s_client`. Deploy only if cert doesn't match. |
| iDRAC | `racadm sslcertview -t 1` → compare subject/expiry. Deploy only if different. |
| UniFi | `stat` the cert file → read with `community.crypto.x509_certificate_info` → compare. Deploy only if different. |

### Renewal Timeline

```
Day 0          Day 83         Day 90
|── cert valid ──|── renew ──|── expiry
                 ^
                 renewal threshold (7 days before expiry)
```

---

## 6. Gotchas & Blockers

### Cross-Cutting

1. **RSA 2048 is mandatory** — ECC silently fails on Synology and HP. Use `--kty RSA --size 2048` everywhere.
2. **Step-CA provisioner max duration defaults to 24h** — must be increased before automation will work. The `ansible` provisioner needs `--x509-max-dur=2160h` or higher.
3. **Cert issuance on the controller** — all `step ca certificate` commands run via `delegate_to: localhost`. The controller needs `step-cli` installed and bootstrapped.
4. **`--not-after` must not exceed provisioner max** — if you request `2160h` but the provisioner max is `24h`, the CA rejects the request.

### Per-Appliance

| Appliance | Blocker/Risk | Mitigation |
|-----------|-------------|------------|
| **Synology** | `ansible.builtin.uri` base64-encodes multipart files in ansible-core < 2.16 | Use `multipart_encoding: 7or8bit` (core >= 2.16) or fall back to `curl` |
| **Synology** | 2FA on admin account blocks API login | Use dedicated service account without 2FA |
| **HP Printer** | Undocumented endpoint — can change with firmware updates | Test after every firmware update |
| **HP Printer** | Including CA chain in PFX causes "corrupted format" error | Always use leaf cert only, never fullchain |
| **HP Printer** | OpenSSL 3.x default encryption may not be parseable by older firmware | Use `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES` |
| **HP Printer** | Auto-reboot after upload — 30-90 second downtime | Build wait/retry into verification |
| **iDRAC8** | `dellemc.openmanage.idrac_certificates` module does NOT work | Use RACADM commands or Dell WS-Man role |
| **iDRAC8** | Remote RACADM requires Enterprise license | Verify license on the R630 |
| **iDRAC8** | `racreset` takes 2-5 minutes, connection drops | Build wait/retry logic (5 min timeout) |
| **iDRAC8** | CSR generation invalidates current cert immediately | Don't start CSR flow unless ready to complete it |
| **iDRAC8** | SAN support may not be available via RACADM CSR | May need external cert+key upload (risky on older firmware) |
| **UniFi** | No API — file-based only, needs SSH access | Ensure SSH is enabled and accessible |
| **UniFi** | `ubios-cert` project archived due to firmware instability | Test on each firmware update |
| **UniFi** | Firmware upgrades may reset certificates | Automated re-deployment via scheduled playbook runs |

### Open Questions

1. **Which HP printer model exactly?** The endpoint differs between generations. Need to verify against the specific model.
2. **iDRAC8 firmware version on the R630?** Determines which RACADM commands are available and whether `sslkeyupload` works.
3. **UniFi OS firmware version?** Determines whether YAML override is available (3.2.7+).
4. **Is remote management enabled on the Step-CA container?** If not, provisioner setup must be done inside the container.
5. **Is the `step` CLI already installed on the Ansible controller?** If not, that's a prerequisite.
6. **Ansible core version?** Determines whether `multipart_encoding: 7or8bit` is available for Synology uploads.
