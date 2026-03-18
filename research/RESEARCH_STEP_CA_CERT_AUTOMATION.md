# Research Task: Step-CA Certificate Automation for Appliances

## Context
You are researching for the McHomeLab Ansible project. The goal is to automate certificate issuance from a private Step-CA server and deploy certs to 4 types of appliances: Synology NAS, HP Printer, Dell iDRAC, and UniFi OS Server. Each appliance has a different API for cert upload.

The Step-CA server runs as a Docker container on `util.example.com` (ca.util.example.com). It currently has:
- A `admin` JWK provisioner with a 24h max cert duration
- An `acme` ACME provisioner
- Password: `<PASSWORD>`

## What We Already Know
- Certs MUST be RSA 2048 (ECC silently fails on Synology and HP)
- Current max duration is 24h — need to increase to 30-90 days
- The `step` CLI can issue certs: `step ca certificate <CN> cert.crt key.key --not-after=2160h --kty RSA --size 2048`
- Cert issuance should happen on the Ansible controller via `delegate_to: localhost`

## Research Questions

### 1. Step-CA Provisioner Configuration
- How do we increase max cert duration on the `admin` provisioner? (`step ca provisioner update admin --x509-max-dur=2160h`)
- Can this be done from a remote machine pointing at the CA URL, or must it be done inside the container?
- Should we create a separate `ansible` provisioner with its own max duration, rather than modifying `admin`?
- What's the best practice for automation — JWK provisioner with a password file, or a different provisioner type?
- How do we make this idempotent? (don't re-issue if cert is still valid and >7 days from expiry)

### 2. Ansible Cert Issuance Pattern
- What Ansible modules exist for step-ca cert issuance? (`community.crypto`? `ansible.builtin.command` with `step`?)
- How to check if an existing cert is still valid before re-issuing?
- How to handle the cert + key files on the controller (temp dir? registry?)
- Best pattern for "issue cert on controller, then push to appliance via API"

### 3. Synology DSM Certificate API
- Research the `SYNO.Core.Certificate` REST API thoroughly
- How to authenticate (session-based? API key?)
- How to upload a cert (multipart form upload)
- How to set the uploaded cert as the default/active cert
- How to handle the self-signed cert on first connection (DSM ships with self-signed)
- Can `ansible.builtin.uri` handle multipart file upload, or must we use `curl`?
- DSM 7.x vs 7.2 API differences?
- Provide example `curl` commands for the full flow (login → upload → set default → logout)

### 4. HP Printer EWS Certificate API
- Research the HP EWS (Embedded Web Server) certificate upload
- Known upload URL: `/Security/DeviceCertificates/NewCertWithPassword/Upload?fixed_response=true`
- Must use IP address, not hostname (firmware quirk)
- PFX/PKCS12 format required — leaf cert + key only, no CA chain
- How to convert PEM cert+key to PFX in Ansible (`openssl pkcs12` or `community.crypto.openssl_pkcs12`)
- Does the printer need a reboot/power cycle after cert upload?
- How to verify the cert was applied?
- What HTTP method and content type for the upload?

### 5. Dell iDRAC Certificate Management
- Research `dellemc.openmanage.idrac_certificates` module
- How to upload a custom SSL cert to iDRAC8 (R630)
- Certificate format requirements (PEM? PFX? DER?)
- Does iDRAC need a restart after cert change?
- Any iDRAC8-specific limitations vs iDRAC9?
- Can we do this without Enterprise license?

### 6. UniFi OS Server Certificate
- Research how UniFi OS Server manages custom SSL certs
- Where are certs stored? (`/data/unifi-core/config/` ?)
- What format? (PEM? Combined cert+key?)
- File naming conventions?
- Does the service need a restart after cert change?
- Can this be done via API, or must it be file-based?
- Does Podman (not Docker) affect anything here?

## Deliverable
Write findings to `/home/mmcdonnell/workspace/McHomeLab/RESEARCH_STEP_CA_CERT_FINDINGS.md` with:
1. Step-CA provisioner setup commands and Ansible automation pattern
2. Per-appliance cert deployment: exact API calls, formats, authentication
3. A proposed Ansible role structure (shared cert issuance + per-type deployment)
4. Idempotency strategy (check expiry before re-issue)
5. Any gotchas or blockers discovered
