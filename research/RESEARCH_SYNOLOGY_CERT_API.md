# Research Brief: Synology DSM 7 Certificate Automation via API

## Ground Rules

You may create scratch scripts, test apps, sample Ansible playbooks, and any other files you like in `/tmp/` or a new scratch directory.

**You may NOT modify any existing files in this repository (`/home/mmcdonnell/workspace/McHomeLab/`) or the inventory repo (`/home/mmcdonnell/workspace/McHomeLab-Inventory/`).**

---

## Current State

**A working Step-CA signed certificate is already installed and active on the Synology.** It was set as default manually through the DSM UI. It is currently being served correctly on port 5001.

The cert details:
- CN: `synology.example.com`
- SANs: `synology.example.com`, `192.168.255.2`
- Issued by: McHomeLab CA (step-ca, two-tier PKI: root → intermediate → leaf)
- Expires: 2031-03-16 (5-year cert)
- Desc in DSM: "Step-CA Managed"

**The goal is NOT to get the cert working — it already works. The goal is to automate renewal so that when this cert expires or needs rotation, an Ansible playbook can replace it end-to-end without any manual DSM UI interaction.**

---

## Environment

- **Controller**: localhost (Ubuntu, runs Ansible)
- **Ansible version**: ansible-core 2.19
- **Target**: Synology DSM at `synology.example.com:5001` (HTTPS)
- **DSM credentials**: `<USER>` / `<PASSWORD>` — confirmed member of the DSM `administrators` group
- **SSH key**: `/home/mmcdonnell/.ssh/mmcdonnell_default`
- **Tools available on controller**: `curl`, `python3`, `openssl`, `step` CLI

Current cert files on disk (the LIVE working cert — do not delete or overwrite these):
- Leaf cert: `/home/mmcdonnell/.mhl/synology/cert.pem`
- Private key: `/home/mmcdonnell/.mhl/synology/key.pem`
- Chain (intermediate + root concatenated): `/home/mmcdonnell/.mhl/synology/chain.pem`
- Root CA only: `/home/mmcdonnell/.mhl/util/root_ca_cert`
- Intermediate CA only: `/home/mmcdonnell/.mhl/util/intermediate_ca_cert`

---

## What We Already Know

### Upload Works via Curl

The following curl sequence successfully imports a cert into DSM (it appears in the Certificate UI):

```bash
# Login
RESP=$(curl -sk "https://synology.example.com:5001/webapi/entry.cgi?api=SYNO.API.Auth&version=7&method=login&format=sid&account=<USER>&passwd=<PASSWORD>&enable_syno_token=yes")
SID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['sid'])")
TOKEN=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['synotoken'])")

# Upload cert
curl -sk -X POST \
  "https://synology.example.com:5001/webapi/entry.cgi?api=SYNO.Core.Certificate&method=import&version=1&SynoToken=${TOKEN}&_sid=${SID}" \
  -H "X-SYNO-TOKEN: ${TOKEN}" \
  -F "key=@/path/to/key.pem;type=application/octet-stream" \
  -F "cert=@/path/to/cert.pem;type=application/octet-stream" \
  -F "inter_cert=@/path/to/chain.pem;type=application/octet-stream" \
  -F "id=" \
  -F "desc=Step-CA Managed" \
  -F "as_default=true"
# Returns: {"data":{"id":"<some_id>"},"success":true}
```

The `as_default=true` flag does NOT appear to automatically apply the cert — DSM kept serving the old cert after upload. The cert appeared in the UI but had to be manually promoted to default.

### What the UI Does That We Don't

When you set a cert as default in the DSM Certificate UI, DSM:
1. Marks the cert as default for all services
2. **Restarts nginx** — takes ~10 seconds

The correct restart command (DSM 7) is:
```bash
sudo synosystemctl restart nginx
```
NOT `synoservicectl` (that's DSM 6).

### Ansible `uri` Module is Broken for This

Ansible's `ansible.builtin.uri` with `body_format: form-multipart` uses Python's `email.policy.HTTP` which converts ALL `\n` to `\r\n` in the multipart body — including inside the PEM cert content. DSM's PEM parser rejects these with `upload_err: -5`. **This is a fundamental Ansible limitation, not a configuration issue.** Curl sends raw `\n` and works fine.

The Ansible task will need to shell out to `curl` via `ansible.builtin.command`.

### DSM `list` Method Returns 103

```bash
curl -sk "https://synology.example.com:5001/webapi/entry.cgi?api=SYNO.Core.Certificate&method=list&version=1&_sid=${SID}" -H "X-SYNO-TOKEN: ${TOKEN}"
# Returns: {"error":{"code":103},"success":false}
```

We don't know why — could be wrong parameters, wrong API version, or a different endpoint.

---

## Research Mission

### Phase 1 — Research (Web + Source Reading)

**Start by reading these sources before touching the Synology:**

1. **acme.sh Synology deploy hook** — the gold standard:
   `https://github.com/acmesh-official/acme.sh/blob/master/deploy/synology_dsm.sh`
   Read it carefully. It solves exactly this problem.

2. Search for: `synology DSM 7 certificate API set default ansible`, `synology certificate import as_default api`, `synology nginx restart api`

3. Look for homelab scripts/gists that automate DSM cert renewal (not just import)

Key questions to answer from research:
- Does `as_default=true` on import work for DSM 7, or does it need a separate API call?
- Is there a `configure` or `set` method for `SYNO.Core.Certificate`?
- Can nginx be restarted via a DSM API, or is SSH required?
- What is the correct way to list existing certs and their IDs?
- How do you UPDATE an existing cert (by ID) vs creating a new one?

### Phase 2 — Build and Test a Self-Signed Cert

**Do NOT touch the live cert files.** Generate a fresh self-signed cert in `/tmp/` for testing:

```bash
# Generate a test self-signed cert
openssl req -x509 -newkey rsa:2048 -keyout /tmp/test_key.pem -out /tmp/test_cert.pem \
  -days 365 -nodes -subj "/CN=synology.example.com" \
  -addext "subjectAltName=DNS:synology.example.com,IP:192.168.255.2"
# For inter_cert, use an empty file or the test cert itself
touch /tmp/test_chain.pem
```

Using this test cert, work out the COMPLETE automation sequence:
1. Import test cert into DSM (capturing the cert ID from the response)
2. Set it as the default (figure out if `as_default=true` works, or if there's a separate API call)
3. Trigger nginx restart (API or SSH — whichever works)
4. Verify the test cert is now being served: `openssl s_client -connect synology.example.com:5001 </dev/null 2>&1 | grep "CN ="`

### Phase 3 — Restore the Live Cert

After confirming the test cert flow works, restore the live cert using the same automation:

```bash
# The live cert is at:
KEY=/home/mmcdonnell/.mhl/synology/key.pem
CERT=/home/mmcdonnell/.mhl/synology/cert.pem
CHAIN=/home/mmcdonnell/.mhl/synology/chain.pem
```

Run the complete sequence again with the live cert files. Confirm via openssl that DSM is back to serving `CN=synology.example.com` signed by the McHomeLab CA.

Also clean up any leftover duplicate "Step-CA Managed" cert entries from earlier testing — there are at least 3 extras in DSM from previous failed attempts. Find and delete them by ID.

### Phase 4 — Write the Sample Ansible Playbook

Write a standalone sample Ansible playbook at `/tmp/synology_cert_upload.yml` that implements the complete flow. It should:

1. Issue/check cert from Step-CA (skip if not needed — the `step certificate needs-renewal` check)
2. Assemble the CA chain file (intermediate + root concatenated)
3. Login to DSM via `ansible.builtin.uri` (JSON response is fine for login)
4. Upload cert via `ansible.builtin.command` with `curl` (because of the CRLF bug)
5. Set cert as default (separate API call if needed, or confirm `as_default=true` suffices)
6. Restart nginx (via `ansible.builtin.command` SSH, or API if possible)
7. Logout from DSM
8. Validate: `ansible.builtin.uri` to `https://synology.example.com:5001/` with `validate_certs: true` — this should now PASS

The playbook should use variables for all credentials and paths (no hardcoding), and include a comment at the top explaining the CRLF issue and why curl is used instead of `ansible.builtin.uri`.

---

## Deliverable

Write `/tmp/synology_cert_findings.md` containing:

1. **The complete working curl sequence** — every step from login → import → set default → restart → verify, tested and confirmed
2. **Whether `as_default=true` works on import** or requires a separate API call (with the exact API call if needed)
3. **How to list certs** by ID (to find and delete old entries)
4. **How to delete a cert** by ID
5. **How to restart nginx** — API URL if available, otherwise SSH command
6. **The sample Ansible playbook** at `/tmp/synology_cert_upload.yml` (reference it from the findings doc)
7. **Gotchas** — anything else discovered

Be aggressive. Test everything. Leave no open questions. The output of this research should be something we can directly implement in the existing McHomeLab Ansible codebase with minimal guesswork.
