# Research: Ansible uri Module form-multipart and PEM File Upload

**Date:** 2026-03-17
**Context:** Uploading PEM certificate files to Synology DSM API. curl works with `-F "key=@file.pem"` but Ansible `uri` module with `body_format: form-multipart` and `multipart_encoding: 7or8bit` returns `upload_err: -5` (invalid format).

---

## Summary of Findings

The root cause is almost certainly the **`content:` key path in `prepare_multipart`**. When `content:` is supplied, `multipart_encoding` is silently ignored and the payload is sent raw with no `Content-Transfer-Encoding` header. This behavior combined with PEM content being a string (not raw bytes) creates a mismatch with what the Synology DSM API expects.

The correct fix is to use the **`filename:` key without `content:`**, pointing to the actual file path on disk. This triggers the file-read code path that properly applies `multipart_encoding: 7or8bit` (encoding_7or8bit sets CTE to `7bit` or `8bit` without payload transformation), which closely matches what curl sends.

---

## Q1: Is there a `filepath:` or `file:` key instead of `content:`?

**No.** The `prepare_multipart` function in `ansible.module_utils.urls` supports exactly these keys for a mapping-type part:

- `filename` — path to a file on disk to read, OR just a filename hint when used with `content`
- `content` — literal string content
- `mime_type` — MIME type override
- `multipart_encoding` — `"base64"` (default) or `"7or8bit"` (added in ansible-core 2.16 via PR #80566, shipped in 2.19)

There is no `path:`, `file:`, or `filepath:` key. The `filename:` key doubles as both the disk path (when `content` is absent) and the `filename=` hint in the `Content-Disposition` header.

---

## Q2: Does `lookup('file', ...)` strip trailing newlines or alter PEM content?

**Yes — it strips trailing whitespace by default.**

The `ansible.builtin.file` lookup plugin has two relevant options:
- `rstrip`: defaults to `true` — strips trailing whitespace including newlines
- `lstrip`: defaults to `false`

Internally it calls `DataLoader.get_text_file_contents()`, which decodes bytes as UTF-8 and returns a Python string. For PEM files this means:

1. The final `-----END CERTIFICATE-----\n` trailing newline is stripped
2. The content is a Python string, not bytes

PEM format requires the trailing newline after the `-----END ...-----` line. Some servers/parsers are strict about this. Synology DSM may be among them.

To preserve the trailing newline when using `content:`:

```yaml
content: "{{ lookup('file', host_cert_key_path, rstrip=false) }}"
```

However, this only partially solves the problem — see Q3 and Q5 for the complete picture.

---

## Q3: Is there a lookup plugin that reads raw file bytes without modification?

**`ansible.builtin.slurp` is the closest option**, but it runs on the remote host and returns base64-encoded content:

```yaml
- name: Slurp the cert file
  ansible.builtin.slurp:
    src: "{{ host_cert_key_path }}"
  register: cert_slurp

# Then use: cert_slurp.content | b64decode
```

The `slurp` module returns `{ "content": "<base64>", "encoding": "base64" }`. The `b64decode` filter gives back the original bytes as a Python bytes object, but when injected into a YAML string value it becomes a Python string anyway.

**The `ansible.builtin.file` lookup** (`lookup('file', ...)`) is a text-oriented plugin. It uses `get_text_file_contents()` (UTF-8 decode, returns string). PEM files are ASCII so UTF-8 decode is lossless, but rstrip behavior is a concern.

**There is no lookup plugin in ansible-core that returns raw bytes for use in a template.** For binary files this matters; for PEM (ASCII text) the encoding itself is not the issue — the rstrip and the `content` vs `filename` code path are.

---

## Q4: Known issues with `ansible.builtin.uri` form-multipart and PEM/binary files

**There is a long history of encoding problems with the uri module and multipart uploads:**

| Issue | Status | Core Problem |
|-------|--------|--------------|
| #73621 | Closed, won't fix | Binary files base64-encoded by default; RFC-compliant but servers reject it |
| #81048 | Closed, not Ansible bug | ZIP upload corrupted; proxy was cause but base64 CTE is the underlying issue |
| #81523 | Closed, won't fix | `Content-Transfer-Encoding` deprecated in HTTP (RFC 7578); servers reject base64 CTE |
| #83884 | Closed, duplicate | BMC Redfish API rejected base64 CTE; Ansible maintainers declined to fix |
| PR #80566 | Merged 2024-12-10 | Added `multipart_encoding: 7or8bit` option to bypass base64 (released in 2.16+) |

**The core problem:** Python's `email` standard library, which Ansible uses to build multipart bodies, defaults to base64 encoding for binary parts. The `Content-Transfer-Encoding: base64` header is valid per RFC 2045 (MIME) but was deprecated in HTTP multipart by RFC 7578 (2015). Most HTTP servers that handle file uploads do not decode base64-encoded parts because curl and browsers never send them that way.

PR #80566 specifically addressed this: "curl successfully handles these uploads using 8bit encoding, which Ansible previously couldn't replicate."

---

## Q5: The correct way in Ansible 2.19 to replicate `curl -F "key=@file"`

### The critical code path distinction

`prepare_multipart` has two branches:

```python
if not content and filename:
    # FILE PATH: reads file from disk with open(..., 'rb')
    # Applies multipart_encoding (base64 or 7or8bit)
    multipart_encoding = set_multipart_encoding(multipart_encoding_str)
    with open(to_bytes(filename, errors='surrogate_or_strict'), 'rb') as f:
        part = email.mime.application.MIMEApplication(f.read(), _encoder=multipart_encoding)
else:
    # CONTENT PATH: set_payload(to_bytes(content))
    # multipart_encoding IS COMPLETELY IGNORED in this branch
    part = email.mime.nonmultipart.MIMENonMultipart(main_type, sub_type)
    part.set_payload(to_bytes(content))
```

**`multipart_encoding` is only applied in the `filename` (no `content`) branch.**

When `content:` is provided — even alongside `multipart_encoding: 7or8bit` — the encoding option is silently ignored. No `Content-Transfer-Encoding` header is set, and the payload bytes are sent as-is without any encoder being applied.

### What curl -F "key=@file.pem" actually sends

curl sends:
```
--boundary
Content-Disposition: form-data; name="key"; filename="privkey.pem"
Content-Type: application/octet-stream

-----BEGIN PRIVATE KEY-----
<raw PEM content>
-----END PRIVATE KEY-----
```

No `Content-Transfer-Encoding` header. Raw bytes. No base64.

This is exactly what `multipart_encoding: 7or8bit` produces via the **filename path** (not content path). The `encode_7or8bit` encoder sets CTE to `7bit` or `8bit` but does **not** transform the payload bytes. So the raw file content is preserved.

### The correct Ansible task

```yaml
- name: Upload certificate to Synology DSM
  ansible.builtin.uri:
    url: "{{ synology_api_url }}/webapi/entry.cgi"
    method: POST
    body_format: "form-multipart"
    body:
      key:
        filename: "{{ host_cert_key_path }}"
        mime_type: "application/octet-stream"
        multipart_encoding: "7or8bit"
      cert:
        filename: "{{ host_cert_cert_path }}"
        mime_type: "application/octet-stream"
        multipart_encoding: "7or8bit"
      inter_cert:
        filename: "{{ host_cert_chain_path }}"
        mime_type: "application/octet-stream"
        multipart_encoding: "7or8bit"
```

**Do not include `content:`** — its presence switches to the broken code path where `multipart_encoding` is ignored.

The `filename:` value is an absolute path on the Ansible controller (the machine running the task). The `uri` module runs on the controller by default (`delegate_to: localhost` or when run from the controller).

**If the cert files are on a remote host:** slurp them first, write them to a tempfile on the controller, then run the uri task. Or use `delegate_to: localhost` with fetched files.

---

## Q6: ansible-core changelog and source for form-multipart file upload

### The `filename:` key has always existed

The `filename:` key (without `content:`) as a file path has been supported since `body_format: form-multipart` was introduced in ansible-core 2.10. The integration test confirms this:

```yaml
# file1: read from disk via filename, encoded base64 (default)
file1:
  filename: formdata.txt

# file3: read from disk via filename, encoded 7or8bit (2.16+)
file3:
  filename: formdata.txt
  multipart_encoding: '7or8bit'
```

The test assertion confirms the distinction:
- `file1` (base64): `multipart.json.files.file1 | b64decode == '_multipart/form-data_\n'`
- `file3` (7or8bit): `multipart.json.files.file3 == '_multipart/form-data_\r\n'`  ← raw content, no b64decode needed

### PR #80566 — `multipart_encoding` added (merged 2024-12-10)

- Target version: ansible-core 2.16 (tagged as `affects_2.16`)
- Changelog fragment shows it as a minor feature addition
- The `multipart_encoding` parameter can be set per-part (inside the field mapping) or presumably at the top-level `body` level

**Note:** The PR changelog says 2.16 but it is present in ansible-core 2.19 (current). It was added to `urls.py` which is a module_utils file bundled with ansible-core.

### Source reference

`lib/ansible/module_utils/urls.py` — `prepare_multipart()` and `set_multipart_encoding()`

```python
def set_multipart_encoding(encoding):
    encoders_dict = {
        "base64": email.encoders.encode_base64,
        "7or8bit": email.encoders.encode_7or8bit
    }
    if encoders_dict.get(encoding):
        return encoders_dict.get(encoding)
    else:
        raise ValueError("multipart_encoding must be one of %s." % repr(encoders_dict.keys()))
```

---

## Why upload_err: -5 Specifically

The Synology DSM API error `upload_err: -5` means "invalid format." Based on acme.sh source analysis, Synology expects:

- Fields: `key`, `cert`, `inter_cert` (plus `id`, `desc`, `as_default`)
- Content-Type per field: `application/octet-stream`
- No `Content-Transfer-Encoding` header (raw bytes, no base64)
- Standard PEM format including trailing newline

The current task uses `content: "{{ lookup('file', ...) }}"` which:
1. Strips trailing newlines (rstrip default)
2. Ignores `multipart_encoding: 7or8bit` (content path ignores it)
3. Sets no `Content-Transfer-Encoding` header (potentially OK)
4. Uses `MIMENonMultipart` instead of `MIMEApplication` (may affect Content-Type header)

The combination of stripped trailing newline and possible Content-Type mismatch (`MIMENonMultipart` uses the exact mime_type you provide, so that part is OK) is the most likely cause of `-5`.

---

## Recommended Fix

Replace `content:` with bare `filename:` pointing to the file path on disk:

```yaml
# BEFORE (broken):
body:
  key:
    filename: "privkey.pem"          # <-- used only as Content-Disposition filename hint
    mime_type: "application/x-x509-ca-cert"
    content: "{{ lookup('file', host_cert_key_path) }}"   # <-- triggers wrong code path
    multipart_encoding: "7or8bit"    # <-- silently ignored with content: present

# AFTER (correct):
body:
  key:
    filename: "{{ host_cert_key_path }}"   # <-- absolute path; file is read from disk
    mime_type: "application/octet-stream"  # <-- matches what acme.sh and curl send
    multipart_encoding: "7or8bit"          # <-- now actually applied
```

This replicates `curl -F "key=@/path/to/privkey.pem"` exactly.

**Also change mime_type** from `application/x-x509-ca-cert` to `application/octet-stream` to match the acme.sh reference implementation — Synology DSM may validate this.

---

## Alternative: Use command module with curl

If the `filename:` approach still fails (e.g., due to remaining CTE header differences), fall back to a direct curl invocation:

```yaml
- name: Upload certificate via curl
  ansible.builtin.command:
    cmd: >
      curl -s -b "id={{ synology_sid }}"
      -F "key=@{{ host_cert_key_path }}"
      -F "cert=@{{ host_cert_cert_path }}"
      -F "inter_cert=@{{ host_cert_chain_path }}"
      -F "id={{ cert_id }}"
      -F "desc={{ cert_desc }}"
      "{{ synology_api_url }}/webapi/entry.cgi?api=SYNO.Core.Certificate&method=import&version=1"
  register: cert_upload_result
  no_log: true
```

This is the most reliable approach as it exactly replicates the working curl invocation with no Python MIME library involved.