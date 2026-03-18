# Research: iDRAC8 SSL Certificate Upload via API

Date: 2026-03-17

## 1. Does iDRAC8 Support Redfish?

**Yes.** iDRAC8 supports the Redfish API starting from firmware version **2.40.40.40**.

- iDRAC8 firmware uses the `2.x.x.x` versioning scheme (e.g., 2.83.83.83, 2.86.86.86).
- iDRAC9 firmware uses a different scheme starting at `3.x` and later `5.x`/`6.x`.
- The Dell iDRAC-Redfish-Scripting repository explicitly lists minimum firmware: **iDRAC 7/8 FW 2.40.40.40**.
- PowerEdge R630 is a 13th-generation server, which uses iDRAC8.

Source: https://github.com/dell/iDRAC-Redfish-Scripting — "Minimum iDRAC 7/8 FW 2.40.40.40, iDRAC9 FW 3.00.00.00"

## 2. Does iDRAC8 Redfish Include Certificate Management Endpoints?

**Yes.** iDRAC8 supports certificate management via Dell OEM Redfish extensions. The endpoints live under the Dell OEM namespace, not the standard DMTF CertificateService (though iDRAC8 does support the standard CertificateService for some operations like ReplaceCertificate and GenerateCSR).

### Available certificate endpoints on iDRAC8:

**Dell OEM endpoints** (primary method for import/export):
- `POST /redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.ImportSSLCertificate`
- `POST /redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.ExportSSLCertificate`
- `POST /redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.UploadSSLKey`
- `POST /redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.DeleteSSLCertificate`
- `POST /redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.SSLResetCfg`

**Standard Redfish endpoints** (also supported on iDRAC8):
- `GET /redfish/v1/CertificateService`
- `GET /redfish/v1/CertificateService/CertificateLocations?$expand=*($levels=1)`
- `POST /redfish/v1/CertificateService/Actions/CertificateService.ReplaceCertificate`
- `POST /redfish/v1/CertificateService/Actions/CertificateService.GenerateCSR`

## 3. Exact Endpoints and Methods for Uploading a Custom SSL Cert + Key

### Method A: PEM cert + separate private key (two-step)

**Step 1 — Upload the private key:**

```bash
curl -sk -u root:calvin \
  -H "Content-Type: application/json" \
  -X POST "https://<IDRAC_IP>/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.UploadSSLKey" \
  -d '{
    "SSLKeyString": "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAK...(key content)...\n-----END RSA PRIVATE KEY-----"
  }'
```

**Step 2 — Import the certificate:**

```bash
curl -sk -u root:calvin \
  -H "Content-Type: application/json" \
  -X POST "https://<IDRAC_IP>/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.ImportSSLCertificate" \
  -d '{
    "CertificateType": "Server",
    "SSLCertificateFile": "-----BEGIN CERTIFICATE-----\nMIIDxTCCAq2gAwIBAgI...(cert content)...\n-----END CERTIFICATE-----"
  }'
```

**Step 3 — Reboot iDRAC (required on iDRAC8):**

```bash
curl -sk -u root:calvin \
  -H "Content-Type: application/json" \
  -X POST "https://<IDRAC_IP>/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset/" \
  -d '{"ResetType": "GracefulRestart"}'
```

### Method B: PKCS12 bundle (single step)

```bash
# First base64-encode the .p12 file
P12_B64=$(base64 -w0 server.p12)

curl -sk -u root:calvin \
  -H "Content-Type: application/json" \
  -X POST "https://<IDRAC_IP>/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.ImportSSLCertificate" \
  -d "{
    \"CertificateType\": \"Server\",
    \"SSLCertificateFile\": \"$P12_B64\",
    \"Passphrase\": \"your-p12-passphrase\"
  }"

# Then reboot iDRAC
curl -sk -u root:calvin \
  -H "Content-Type: application/json" \
  -X POST "https://<IDRAC_IP>/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset/" \
  -d '{"ResetType": "GracefulRestart"}'
```

### Method C: Standard Redfish ReplaceCertificate (CSR-signed cert only)

This replaces a certificate that was generated from a CSR. On iDRAC8, the payload uses a **plain string** for CertificateUri (not the `@odata.id` object format used on newer iDRAC9):

```bash
curl -sk -u root:calvin \
  -H "Content-Type: application/json" \
  -X POST "https://<IDRAC_IP>/redfish/v1/CertificateService/Actions/CertificateService.ReplaceCertificate" \
  -d '{
    "CertificateType": "PEM",
    "CertificateUri": "/redfish/v1/Managers/iDRAC.Embedded.1/NetworkProtocol/HTTPS/Certificates/SecurityCertificate.1",
    "CertificateString": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----"
  }'
```

### Supported CertificateType values

The exact values vary by firmware; query them dynamically:

```bash
curl -sk -u root:calvin \
  "https://<IDRAC_IP>/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService" \
  | python3 -m json.tool
```

Look for `SSLCertType@Redfish.AllowableValues` (export) and `CertificateType@Redfish.AllowableValues` (import) in the Actions section. Common values:

| Value | Purpose |
|---|---|
| `Server` | iDRAC web interface HTTPS certificate |
| `CA` | Certificate Authority cert |
| `CustomCertificate` | Custom/user-provided certificate |
| `CSC` | Crypto Service Container |
| `ClientTrustCertificate` | Client trust certificate |

### Authentication

- **Basic Auth**: `-u username:password`
- **Session/Token**: Use `X-Auth-Token` header
- **SSL verification**: Typically disabled (`-k` / `verify=False`) since you're replacing the very certificate being validated

### Important: iDRAC8 requires reboot after cert import

On iDRAC8, the new certificate does not take effect until iDRAC is rebooted. This is different from iDRAC9 6.00.02+ and iDRAC10, where reboot is no longer required.

## 4. Differences from iDRAC9 Redfish Cert Management

| Aspect | iDRAC8 | iDRAC9 (6.00.02+) |
|---|---|---|
| OEM Import/Export endpoints | Same paths, same payloads | Same paths, same payloads |
| ReplaceCertificate payload | `CertificateUri` is a **plain string** | `CertificateUri` is an **object**: `{"@odata.id": "/redfish/v1/..."}` |
| GenerateCSR payload | `CertificateCollection` is a **plain string** | `CertificateCollection` is an **object**: `{"@odata.id": "/redfish/v1/..."}` |
| Reboot after import | **Required** | **Not required** (6.00.02+) |
| Firmware version scheme | `2.x.x.x` | `3.x` / `5.x` / `6.x` |
| Dell OEM namespace | Supported | Supported |
| Standard CertificateService | Supported (with string URIs) | Supported (with object URIs) |

The OEM Dell endpoints (`DelliDRACCardService.ImportSSLCertificate`, etc.) use the **same payload format** across both generations. The difference is only in the standard DMTF endpoints (`CertificateService.ReplaceCertificate`, `CertificateService.GenerateCSR`), where iDRAC8 uses plain string URIs and iDRAC9 5.10+ uses `@odata.id` object wrappers.

## 5. WS-Man (WSMAN) SOAP API for Certificate Upload

WS-Man is also supported on iDRAC8 and was the primary programmatic interface before Redfish. The relevant WS-Man class is `DCIM_iDRACCardService` with these methods:

- `ImportSSLCertificate` — import a certificate
- `ExportSSLCertificate` — export a certificate
- `SSLResetCfg` — reset SSL config to factory defaults

### WS-Man ImportSSLCertificate example

```bash
# Using wsmancli
wsman invoke -a ImportSSLCertificate \
  "http://schemas.dell.com/wbem/wscim/1/cim-schema/2/DCIM_iDRACCardService?SystemCreationClassName=DCIM_ComputerSystem&CreationClassName=DCIM_iDRACCardService&SystemName=DCIM:ComputerSystem&Name=DCIM:iDRACCardService" \
  -h <IDRAC_IP> -P 443 -u root -p calvin \
  -c dummy.cert -y basic -V -v -j utf-8 \
  -k "CertificateType=1" \
  -k "SSLCertificateFile=$(base64 -w0 cert.pem)"
```

CertificateType values for WS-Man:
- `1` = Server certificate
- `2` = CA certificate
- `3` = Custom certificate

**However, for this project Redfish is strongly preferred over WS-Man** because:
1. Redfish uses simple REST/JSON (easy with `ansible.builtin.uri`).
2. WS-Man uses SOAP/XML, which is cumbersome to construct in Ansible.
3. WS-Man is deprecated by Dell in favor of Redfish.
4. The Redfish endpoints are confirmed working on iDRAC8 2.40.40.40+.

## 6. The "7" in `idracadm7` / `srvadmin-idracadm7`

**The "7" does NOT mean it only works with iDRAC7.** Here is the package breakdown:

| Package | Description | Supports |
|---|---|---|
| `srvadmin-idracadm7` | "Install Racadm for iDRAC7" | iDRAC7 and later (iDRAC8 included) |
| `srvadmin-idracadm8` | "Install Racadm for iDRAC8 and above" | iDRAC8 and later |

The naming reflects the **minimum** iDRAC generation, not the maximum. `srvadmin-idracadm7` was the original remote racadm package that worked with iDRAC7+ (including iDRAC8). Dell later released `srvadmin-idracadm8` as the preferred package for iDRAC8+.

The Docker image `dell/idracadm7` (if it exists on Docker Hub — the registry returned 404 at time of research) would follow the same convention: the "7" indicates the original racadm7 tool, which supports iDRAC7 and iDRAC8.

**For a PowerEdge R630 (iDRAC8), either package works.** Use `srvadmin-idracadm8` if available, fall back to `srvadmin-idracadm7`.

### racadm commands for certificate management (for reference)

```bash
# Upload server certificate
racadm -r <IDRAC_IP> -u root -p calvin sslcertupload -t 1 -f server.pem

# Upload CA certificate
racadm -r <IDRAC_IP> -u root -p calvin sslcertupload -t 2 -f ca.pem

# Upload custom certificate
racadm -r <IDRAC_IP> -u root -p calvin sslcertupload -t 3 -f custom.pem

# Download/export current server certificate
racadm -r <IDRAC_IP> -u root -p calvin sslcertdownload -t 1 -f current_cert.pem

# Certificate type values for -t flag:
#   1 = Server certificate (web interface HTTPS)
#   2 = CA certificate
#   3 = Custom signing certificate
```

## 7. Using `ansible.builtin.uri` for iDRAC8 Cert Upload

**Yes, `ansible.builtin.uri` works perfectly for this.** The Redfish API is standard HTTPS + JSON, which is exactly what `ansible.builtin.uri` is designed for.

### Ansible example: Upload PEM cert + key to iDRAC8

```yaml
# Step 1: Upload the private key
- name: "Upload SSL private key to iDRAC"
  ansible.builtin.uri:
    url: "https://{{ idrac_ip }}/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.UploadSSLKey"
    method: POST
    user: "{{ idrac_user }}"
    password: "{{ idrac_password }}"
    force_basic_auth: true
    validate_certs: false
    headers:
      Content-Type: "application/json"
    body_format: json
    body:
      SSLKeyString: "{{ lookup('file', '/path/to/server.key') }}"
    status_code: 200
  no_log: true

# Step 2: Import the certificate
- name: "Import SSL certificate to iDRAC"
  ansible.builtin.uri:
    url: "https://{{ idrac_ip }}/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.ImportSSLCertificate"
    method: POST
    user: "{{ idrac_user }}"
    password: "{{ idrac_password }}"
    force_basic_auth: true
    validate_certs: false
    headers:
      Content-Type: "application/json"
    body_format: json
    body:
      CertificateType: "Server"
      SSLCertificateFile: "{{ lookup('file', '/path/to/server.crt') }}"
    status_code: 200

# Step 3: Reboot iDRAC to apply (required on iDRAC8)
- name: "Reboot iDRAC to apply new certificate"
  ansible.builtin.uri:
    url: "https://{{ idrac_ip }}/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset/"
    method: POST
    user: "{{ idrac_user }}"
    password: "{{ idrac_password }}"
    force_basic_auth: true
    validate_certs: false
    headers:
      Content-Type: "application/json"
    body_format: json
    body:
      ResetType: "GracefulRestart"
    status_code: [200, 204]

# Step 4: Wait for iDRAC to come back online
- name: "Wait for iDRAC to restart"
  ansible.builtin.uri:
    url: "https://{{ idrac_ip }}/redfish/v1/Managers/iDRAC.Embedded.1"
    method: GET
    user: "{{ idrac_user }}"
    password: "{{ idrac_password }}"
    force_basic_auth: true
    validate_certs: false
    status_code: 200
  register: idrac_status
  until: idrac_status.status == 200
  retries: 30
  delay: 10
```

### Why `ansible.builtin.uri` is ideal for this use case

1. **No external dependencies** — no need to install `srvadmin-idracadm7/8`, Dell OpenManage Ansible collection, or Python Redfish libraries.
2. **Portable** — works on any Ansible controller without Dell-specific packages.
3. **Simple** — REST + JSON maps directly to `uri` module parameters.
4. **No version lock-in** — the `dellemc.openmanage` collection v10.0.0 dropped iDRAC8 support entirely. Using `ansible.builtin.uri` avoids this dependency.

## 8. Dell OpenManage Ansible Collection Compatibility Warning

The `dellemc.openmanage` collection (which includes `idrac_certificates`) **dropped iDRAC8 support in version 10.0.0** (confirmed via GitHub issue #1008). The last version supporting iDRAC8 is **v9.x**. The `idrac_certificates` module documentation states a minimum firmware of "6.10.80.00," which is an iDRAC9 firmware version number — further confirming iDRAC8 is not a target for that module.

**Recommendation: Use `ansible.builtin.uri` with the Dell OEM Redfish endpoints directly.** This avoids the Dell Ansible collection entirely and works reliably on iDRAC8 firmware 2.40.40.40+.

## Summary

| Question | Answer |
|---|---|
| Does iDRAC8 support Redfish? | Yes, firmware 2.40.40.40+ |
| Cert management via Redfish? | Yes, via Dell OEM `DelliDRACCardService` actions |
| Reboot required after import? | Yes (iDRAC8 always requires reboot) |
| Different from iDRAC9? | Minor: string vs object URI format in standard DMTF endpoints; OEM endpoints are identical |
| WS-Man alternative? | Available but deprecated; SOAP/XML is painful in Ansible |
| `idracadm7` works with iDRAC8? | Yes, the "7" is the minimum, not the maximum generation |
| `ansible.builtin.uri` viable? | Yes, strongly recommended over Dell Ansible collection for iDRAC8 |