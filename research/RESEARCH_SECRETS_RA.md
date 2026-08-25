# RESEARCH R-A: Secrets end-to-end — vault custody, inventory placement, runtime delivery, rotation

Opened by the 2026-08-25 decision record (`RESEARCH_SYSADMIN_AGENT.md` §9 Q3 +
Q13, §11 R-A). Must land before Phase 1 vaulting.

**Date:** 2026-08-25
**Scope:** where the vault password lives on a headless controller; whether
secrets stay inline in `hosts.yml`; how secrets reach containers without
plaintext in a 0644 rendered compose file; rotation; concrete layout; PoC.

**Verification legend used throughout:**

- **[V-live]** — executed this session against the live system or a real
  container/CLI on this machine.
- **[V-docs]** — read in the project's current official documentation or its
  source at the pinned tag.
- **[UNVERIFIED]** — reasoned or inferred; explicitly not checked.

---

## 0. Executive summary (the recommendation, in one page)

1. **Vault password custody → a 0600 file outside both repos, escrowed in
   Mike's password manager.** `~/.mhl/vault/mhl.pass`, read by
   `~/.mhl/bin/mhl-vault-client`. No self-hosted secret store as the *root*:
   every one of them (OpenBao, Vault, Infisical, BWS) is itself infrastructure
   MHL would have to declare, and every one of them has an unseal/bootstrap
   secret that lands right back in a password manager. A store moves the
   problem one hop; it does not remove it. `pass`/gpg is a defensible second
   place and is the upgrade if you ever want the password store revisioned,
   but it costs a GPG key whose passphrase has exactly the same custody
   problem, plus `gpg-agent`/pinentry on a headless box.
   **Recovery root: a password-manager entry containing the `mhl` vault
   password verbatim.** That single string plus the two git repos is a full
   rebuild.
2. **Keep secrets inline in `hosts.yml` as `!vault` scalars.** Verified this
   session: `ansible-inventory --list` parses a vaulted inventory *without the
   password* and emits ciphertext, not plaintext; `ansible-lint --profile
   production` and `yamllint` both pass on it; nested `!vault` values survive
   `dict2items` / `to_json` / `.items()`. A store-lookup inventory would leave
   `ansible-inventory --list` showing unresolved `{{ lookup(...) }}` strings
   (verified) and would make the inventory unreadable without a running
   service that MHL itself provisions.
3. **Runtime delivery → Compose file-sourced `secrets:`**, one file per secret
   under `/opt/docker/compose/secrets/`, mode 0400, owned by the uid that
   actually reads it. All four current secret consumers support a file form
   natively (gluetun `*_SECRETFILE`, LSIO `FILE__*`, WUD `*__FILE`, step-ca
   `DOCKER_STEPCA_INIT_PASSWORD_FILE`), and so do the two side files
   (homepage `{{HOMEPAGE_FILE_X}}`, recyclarr `!file`). `env_file` is the
   fallback only for an image with no file form — it still exposes values in
   `docker inspect`.
4. **Rotation:** `ansible-vault rekey` **cannot** rekey a file containing
   inline `!vault` values — verified, it errors `Input is not vault encrypted
   data`. A ~25-line rekey script closes the gap; a working PoC was built and
   round-tripped this session.
5. **Two hard gotchas found by experiment** that the design must encode:
   - Ansible `copy`/`template` write by **atomic rename**, which replaces the
     inode. A compose file-secret is a **bind mount of that inode**, so the
     running container keeps seeing the *old* secret. `docker compose up -d`
     does **not** notice (config-hash unchanged). A `restart` of the affected
     service is mandatory and sufficient. All verified live.
   - **No trailing newline** in any secret file. gluetun trims one; gluetun
     aside, WUD, LSIO and homepage do **not** (LSIO prints a warning,
     homepage would substitute the newline into YAML and break the file).
     `copy: content=abc` writes exactly 3 bytes — verified.

---

## 1. The actual secret inventory (verified live, values withheld)

This is what R-A has to cover. Nothing below is hypothetical.

### 1.1 In `hosts.yml` (`/home/mmcdonnell/workspace/McHomeLab-Inventory/hosts.yml`)

| Line | Key | Nature |
|---|---|---|
| 31 | `ansible_ssh_private_key_file` | path (not a secret; the key at that path is) |
| 32 | `ext_target_pass` | `$6$` SHA-512 crypt hash (autoinstall identity) |
| 38 | `vmware_vcenter_password` | plaintext |
| 45 | `wud_mqtt_password` | plaintext |
| 49 | `wud_lscr_token` | GitHub PAT |
| 51 | `step_ca_provisioner_password` | plaintext |
| 241 | `services.step-ca.environment.DOCKER_STEPCA_INIT_PASSWORD` | plaintext |
| 429 | `services.gluetun.config.wireguard_private_key` | AirVPN WG key |
| 430 | `services.gluetun.config.wireguard_preshared_key` | AirVPN WG PSK |
| 588 | `services.plex.environment.PLEX_CLAIM` | Plex claim token |
| 843, 861 | `ca_provisioner_password` (×2) | step-ca provisioner password, per-host |

`hosts.yml` is currently **untracked** — the inventory repo's `.gitignore`
says so explicitly: *"hosts.yml is committed ONLY once every secret is an
inline `!vault` value."* [V-live]

### 1.2 Side files in the inventory repo, also untracked for the same reason

- `homepage-services.yaml` — ARR widget `key:` (several), qBittorrent
  `username:` / `password:`.
- `recyclarr.yml` — `api_key:` ×2 (Sonarr, Radarr).

Both are `export`ed from `controller` as `type: file` and land at
`~/.mhl/controller/homepage_services` and `~/.mhl/controller/recyclarr_config`,
**mode 0664**. [V-live] R-A must give these two a story or Phase 1 cannot
"revision the source of truth" — they are 2 of the 6 homepage/recyclarr files
and the only untracked ones.

### 1.3 Plaintext in rendered artifacts, on disk right now

| Path | Mode/owner | Contents |
|---|---|---|
| `util:/opt/docker/compose/docker-compose.yml` | `644 root:root` | `DOCKER_STEPCA_INIT_PASSWORD`, WUD MQTT user/password, WUD LSCR PAT |
| `media:/opt/docker/compose/docker-compose.yml` | `644 root:root` | WG private + preshared key, `PLEX_CLAIM` |
| `media:/opt/docker/compose/docker-compose.yml.bak-2026-07-19` | `644 root:root` | **stale copy of the same secrets, 14 KB** |
| `util:/opt/docker/compose/diun-watch.yml` | `644 root:root` | superseded by WUD; retire |
| `util:/opt/containers/homepage/config/services.yaml` | `644 mmcdonnell` | ARR API keys, qBT credentials |
| `~/.mhl/pxe_staging/<host>/autoinstall/user-data` | `644 root:root` | `$6$` crypt hash, and this directory is served over **unauthenticated HTTP** by netboot.xyz to the provisioning VLAN |
| `~/.mhl/controller/*` | `664 mmcdonnell` | as §1.2 |
| `~/.mhl/registry.json` | `644 mmcdonnell` | today holds only paths — no secret values. Any future `type: var` export of a secret would land here in plaintext. |

All [V-live] this session (`ssh util`, `ssh media`, `stat`, `docker inspect`).

**Incidental finding, not a secret but it will trip the scanner:**
`ansible/inventory/test-key` is a committed OpenSSH **private** key (commit
`7efe033`, comment `test-key-for-lint`, ED25519
`SHA256:hFGFWin0asnXLU73sEfjikSpR/6REyzRz+e78c8+oGE`). It is a purpose-made
lint fixture, not a live credential, but a private key is committed to the
McHomeLab repo. Recommendation: generate it in the test harness instead of
committing it, so the shape-scanner needs no exception at all.

### 1.4 Which uid must be able to read each secret (verified live)

| Service | Host | `Config.User` | Runtime uid |
|---|---|---|---|
| gluetun | media | (empty) | **0** [V-live, `docker run --entrypoint id qmcgaw/gluetun:v3.41.3`] |
| plex (LSIO) | media | (empty) | root at s6 init, drops to PUID 1028 after [V-docs, source] |
| recyclarr | media | — | **1000:1000** [V-live, `docker exec … id`] |
| homepage | util | `root` | **0** [V-live] |
| wud | util | (empty) | **0** [V-live] |
| step-ca | util | `step` | **1000:1000** [V-live] |

This matters because Compose **ignores `uid`/`gid`/`mode` for file-sourced
secrets** (below). The host file's real ownership is what the container gets.

---

## 2. Part 1 — Vault-password custody on a headless controller

### 2.1 How the client-script contract actually works (verified)

- `vault_identity_list = mhl@<path>` in `[defaults]` — config name
  `DEFAULT_VAULT_IDENTITY_LIST`, env `ANSIBLE_VAULT_IDENTITY_LIST`, type
  `list`. [V-live, `ansible-config list`]
- ansible-core invokes an executable whose name ends in `-client` with exactly
  `--vault-id mhl` on argv and reads the password from **stdout**.
  [V-live — logged argv from a real run: `ARGS: --vault-id mhl`]
- **Relative paths in `vault_identity_list` resolve against `cwd`, not against
  the `ansible.cfg` directory.** Verified: running from a subdirectory produced
  `The vault password file …/sub/scripts/mhl-vault-client was not found`.
  `~/` **does** expand correctly. [V-live] → the config must use `~/…` or an
  absolute path, never `scripts/…`.
- Decryption is **lazy**. With no password configured, `ansible-inventory
  --list` still succeeds and a playbook only fails at the moment the value is
  used: `Attempting to decrypt but no vault secrets found`. [V-live]

### 2.2 Options compared

Scores: 1 = poor, 5 = excellent.

| Option | Headless-friendly | Revisioned | Recoverable from a password manager | Complexity (lower = better) | Verdict |
|---|---|---|---|---|---|
| **(a) 0600 file outside repos** | **5** — a `cat`; no agent, no daemon, no D-Bus, no TTY | 1 — the password itself isn't revisioned (the *encrypted inventory* is) | **5** — the file's whole content is one PM entry | **5** | **Recommended** |
| **(b) `pass` (gpg)** | 2 — needs a GPG key, `gpg-agent`, and a pinentry that works with no TTY/session; unattended needs the key passphrase-less or cached, i.e. option (a) wearing a hat | 4 — `pass git` gives real history | 4 — needs the *GPG private key + its passphrase* escrowed, i.e. two artefacts, one of them binary | 2 | Second place; adopt only if you want the store revisioned |
| **(b′) OS keyring (`community.general.keyring`)** | 1 — needs an unlocked keyring and a D-Bus session; a headless VM has neither | 1 | 3 | 3 | **Rejected** for headless |
| **(c) OpenBao** | 3 | 4 | 3 — recovery root becomes the unseal/recovery keys | 2 | Rejected as the *root*; viable later as a layer |
| **(c) HashiCorp Vault** | 3 | 4 | 3 | 2 | Rejected — BUSL, and OpenBao dominates it for this use |
| **(c) Infisical** | 3 | 4 | 3 | 2 | Rejected as the root |
| **(c) Bitwarden Secrets Manager** | 4 | 3 | 3 | 3 | Rejected — see the Vaultwarden trap below |
| **(c) 1Password Connect** | 4 | 3 | 4 | 2 | Rejected — SaaS dependency, paid |
| **(d) `systemd-creds`** | 5 *for a root-run unit* | 1 | 1 — host-bound; a dead controller means an undecryptable blob | 4 | Not a custody root; the right **delivery** mechanism for the deferred Q4 timer |

### 2.3 Detail and evidence per option

**(a) 0600 file.** `~/.mhl/vault/mhl.pass`, mode 0600, owned by the run user,
outside `McHomeLab` and `McHomeLab-Inventory`. The client script is three
lines. Nothing to bootstrap, nothing to unseal, nothing to recover except the
string itself. On the future headless VM, the same file is provisioned by the
`controller` role (Q12: *controller owns its own toolchain*) from a value the
operator pastes once. Threat model that this does **not** cover: an attacker
with the run user's shell on the controller reads the file. That is the same
attacker who can already run `ansible-playbook`, so no store fixes it either.

**(b) `pass`.** Upstream `password-store` is v1.7.4, tagged ~2020; last commit
2025-06-18 [V-docs, git.zx2c4.com]. Packaged in Ubuntu (`1.7.4-6`); **not
currently installed on this controller**; `gpg 2.4.4`, `gpg-agent` and
`pinentry-curses` are [V-live]. `community.general.passwordstore` supports
`backend: pass` (default) and `backend: gopass` — the doc says *"`gopass`
support is incomplete"* — and warns you to add `auto-expand-secmem` to
`~/.gnupg/gpg-agent.conf` when reading multiple secrets at once [V-live,
`ansible-doc`]. The honest objection: the GPG private key's passphrase has
*identical* custody properties to option (a)'s file, so `pass` buys history
and a nicer CLI, not a stronger root.

**(c) Self-hosted stores — the chicken-and-egg, stated plainly.**
MHL's ideology is that infrastructure is declared in `hosts.yml` and built by
`site.yml`. A secret store used to unlock `hosts.yml` would be:
a service declared in `hosts.yml`, rendered into a compose file by the
`service` role, running on a host MHL provisions — and needed *before*
`hosts.yml` can be read. The only escapes are (i) run the store somewhere MHL
doesn't manage, which contradicts the ideology, or (ii) keep the store's own
bootstrap secret in a 0600 file, which *is* option (a) with extra steps.

Store-by-store facts (all [V-live] via Galaxy API / GitHub API today):

| Collection | Latest | Released | Repo last push | Notes |
|---|---|---|---|---|
| `community.hashi_vault` | **7.1.0** | 2025-10-25 | 2026-08-17 | Already present in this venv. README does **not** mention OpenBao. Requires `hvac`. Tests only against HashiCorp Vault. |
| `infisical.vault` | **1.2.2** | 2026-06-09 | 2026-08-14 | Vendor-maintained, steady cadence (1.2.0 2025-12, 1.2.1 2026-02, 1.2.2 2026-06). |
| `bitwarden.secrets` | **1.0.2** | 2026-07-09 | 2026-08-19 | Repo `bitwarden/sm-ansible`. Sparse history: 1.0.0 2024-02, 1.0.1 2024-09, 1.0.2 2026-07. Requires `pip install bitwarden-sdk` and `BWS_ACCESS_TOKEN` [V-docs]. |
| `onepassword.connect` | **2.4.0** | 2026-05-04 | 2026-08-19 | Repo `1Password/ansible-onepasswordconnect-collection`. 2.3.0 was 2024-04 — a two-year gap. |
| `community.general` (`passwordstore`, `keyring`, `bitwarden`, `bitwarden_secrets_manager`, `onepassword*`) | **13.3.0** | 2026-08-10 | — | 11.4.1 installed here. Very much alive. |

- **OpenBao** — MPL-2.0, Linux Foundation, v2.6.2 released 2026-08-18, repo
  pushed 2026-08-24, 7.1k stars [V-live, GitHub API]. Healthy. But
  `community.hashi_vault` does not claim OpenBao support, and no OpenBao-native
  Ansible collection was found. Working against OpenBao via the hashi_vault
  lookup is plausible (OpenBao is an API-compatible fork) but
  **[UNVERIFIED]** — not tested this session.
- **HashiCorp Vault** — `LICENSE` is Business Source License 1.1, licensor
  *International Business Machines Corporation (IBM)*, licensed work "Vault
  Version 1.15.0 or later" [V-live, fetched the LICENSE file]. Not OSI
  open source. Contradicts Q2's stated direction (self-hosted FOSS).
- **Bitwarden Secrets Manager / Vaultwarden — the trap.** Vaultwarden
  implements the Bitwarden **Password Manager** API, **not** Secrets Manager;
  the `bws` CLI/SDK that `bitwarden.secrets` depends on therefore does **not**
  work against Vaultwarden [V-docs, vaultwarden discussions #5702/#3368]. If a
  Bitwarden-shaped answer is ever wanted with a self-hosted server, the working
  path is `community.general.bitwarden` (the `bw` CLI against Vaultwarden), not
  `bitwarden.secrets`.
- **1Password Connect** — requires running the Connect server *and* a
  1Password subscription; a paid SaaS dependency in the critical path of
  reading the inventory.

**(d) `systemd-creds` — the deferred-timer answer, recorded now.**
Controller has systemd 255 with `+TPM2`, `/dev/tpmrm0` present, and
`systemd-creds has-tpm2` reports `yes` (`+firmware +driver +system +subsystem
+libraries`) [V-live]. `systemd-creds encrypt` requires root (it needs
`/var/lib/systemd/credential.secret`) — as the normal user it fails with
`Failed to determine local credential host secret: Permission denied`
[V-live]. So it is unusable for interactive work and *perfect* for a root-run
`systemd` timer via `LoadCredentialEncrypted=`. Two caveats to carry forward:
(i) the ciphertext is host-bound, so it is a delivery mechanism and never a
recovery root; (ii) the future controller is a vCenter VM, and a vTPM there
needs a vSphere Native Key Provider configured — **[UNVERIFIED]** whether this
vCenter has one. Without a vTPM, `--with-key=host` still works (host key file
only), just without TPM sealing.

### 2.4 "If the controller burns, what is the recovery root?"

**Recommended answer:** one password-manager entry.

```
Title:  McHomeLab — Ansible Vault (vault-id: mhl)
Secret: <the exact contents of ~/.mhl/vault/mhl.pass, no trailing newline>
Notes:  Restore to ~/.mhl/vault/mhl.pass (0600) on a new controller,
        install ~/.mhl/bin/mhl-vault-client (0700), git clone both repos,
        run `make validate`. Nothing else is needed.
```

Everything else — the encrypted inventory, the roles, the rendered artifacts —
is either in git or is derived state MHL rebuilds. That is a genuinely
one-artefact recovery root, which none of the store options can match: OpenBao
needs unseal/recovery key shares *and* its storage backend restored; Infisical
needs its DB and encryption key; BWS/1Password need an account plus an access
token.

---

## 3. Part 2 — Inline `!vault` in `hosts.yml`, or a runtime lookup?

**Recommendation: keep them inline. Do not introduce runtime lookups.**

### 3.1 What was verified

| Question | Result |
|---|---|
| Does the YAML inventory plugin accept `!vault` at arbitrary nesting depth (e.g. `services.plex.environment.PLEX_CLAIM`)? | **Yes** [V-live] |
| Does the value survive `.items()`, `dict2items`, `to_json`? | **Yes** — `to_json` emitted `{"PLEX_CLAIM": "hunter2"}` [V-live]. *(Corollary: `to_json` on a secret-bearing structure is a leak vector — the existing `healthcheck.test | to_json` is fine, but the pattern needs care.)* |
| `ansible-inventory --list` **without** the vault password? | **Succeeds**, emitting `{"__ansible_vault": "$ANSIBLE_VAULT;1.2;AES256;mhl\n…"}` — ciphertext, not plaintext [V-live] |
| `ansible-inventory --list` **with** the password? | Same output — it does **not** decrypt [V-live] |
| `ansible-lint --profile production` on a vaulted inventory file? | **Passes**, with or without the password [V-live] |
| `yamllint` (repo config and default) on inline `!vault`? | **Passes**, exit 0 [V-live] |
| Is there a Jinja test to detect a vaulted value? | **Yes** — `ansible.builtin.vault_encrypted`. In a template: `PUID:False PLEX_CLAIM:True` [V-live on ansible-core 2.19.4] |
| Does `ansible-inventory --list` template a `{{ lookup(...) }}` hostvar? | **No** — the literal `{{ lookup('ansible.builtin.file', '…') }}` string is emitted verbatim [V-live] |

**Correction to `RESEARCH_SYSADMIN_AGENT.md` §3 A1 / A3.** The test ladder's
step 1 says `ansible-inventory --list` *"proves vault + parse"*. It proves
**parse only** — it succeeds with no vault password at all. A vault-availability
probe must be a separate assertion (see the PoC checklist, step P3).

### 3.2 Why not lookups

1. `hosts.yml` stops being readable as the source of truth: `ansible-inventory
   --list` shows `{{ lookup(...) }}`, not the shape of the data (verified
   above). Today the same command shows ciphertext, which at least says
   *"a secret lives here"* structurally.
2. It creates a hard runtime dependency on a service MHL provisions (§2.3
   chicken-and-egg), inside the play that provisions it.
3. It splits custody: the lookup's own credential (token / role-id / access
   token) has to live somewhere — a 0600 file. You have not removed a 0600
   file, you have added a store on top of one.
4. Offline work stops working. `--check --diff` from a laptop with the store
   down would fail.

**One narrow exception worth allowing later:** a *dynamic* secret with a real
lifecycle (short-lived DB creds, a vault-issued cert). Nothing in the current
fleet is that. If one appears, add it as a `lookup` in a *role*, never in the
inventory.

### 3.3 Ergonomics gap and its fix

There is no in-place editor for a single inline value (`ansible-vault edit`
works on whole encrypted files only). Wrap it:

```bash
mhl-vault-set services.plex.environment.PLEX_CLAIM   # prompts, encrypts, splices
```

Sketch given in §6.4. This is the same gap A1 already identified.

---

## 4. Part 3 — Runtime delivery into Docker Compose

### 4.1 Compose file-sourced secrets: the verified contract

Docker Compose **v5.5.0** on this controller [V-live].

Top-level `secrets:` attributes: `file`, `environment`, `external`, `name`.
`environment` is *"only supported by Docker Compose"* and *"not supported when
deploying with `docker stack deploy`"* [V-docs, docs.docker.com compose-file/secrets].

Service-level long syntax: `source`, `target`, `uid`, `gid`, `mode`. `target`
*"Defaults to `source` if not specified"* and resolves under `/run/secrets/`
[V-docs]. And the sentence that decides the whole design:

> "Support for `uid`, `gid`, and `mode` attributes are only implemented in
> Docker Compose when the source of the secret is `environment`. When the
> source is a `file`, Compose uses a bind-mount under the hood which doesn't
> allow `uid` remapping, and these attributes are **silently ignored**."
> — [V-docs, docs.docker.com compose-file/services#secrets]

Confirmed by experiment: a host file `600 root:root` bind-mounted into a
container running `user: "1028:100"` shows as `-rw------- 1 0 0` inside, and
`cat` fails with `Permission denied` [V-live].

Two more experimental results, both important:

1. **`docker compose config -q` succeeds even when the secret file does not
   exist** [V-live]. → the render test (A3 step 3) can validate a rendered
   compose file in scratch with no secret material present. `docker compose
   config` prints the secret's *path*, never its contents [V-live].
2. **Changing a secret file's content does not recreate the container.**
   `com.docker.compose.config-hash` is unchanged and `docker compose up -d`
   reports `Container … Running` [V-live].

### 4.2 The atomic-rename trap (the single most important finding here)

Because it is a **bind mount of a file**, the container follows the *inode*:

| Action on the host | What the running container sees |
|---|---|
| `printf 'v2' > secret` (truncate in place) | `v2` **immediately**, no restart |
| `mv -f new secret` (atomic rename) | **still `v1`** |
| `ansible.builtin.copy` (which uses atomic rename) | **still `v1`** |
| then `docker restart <c>` | `v2` |
| then `docker compose restart <svc>` | `v2` |
| `docker compose up -d` after any of the above | no change — config-hash identical |

All [V-live] this session.

**Consequence for the role:** every secret-file write must `register` and a
follow-up task must `docker compose restart` exactly the services whose files
changed. `community.docker.docker_compose_v2` supports
`state: restarted` (*"equivalent to running `docker compose restart`"*) with a
`services:` subset [V-live, `ansible-doc`]. This is the same shape as the
existing WUD-TLS `notify: "Restart wud"` handler, so the pattern is already in
the repo.

### 4.3 The no-trailing-newline rule (verified per image)

| Consumer | Reads secret file how | Trims trailing newline? | Source |
|---|---|---|---|
| gluetun | `files.ReadFromFile` | **Yes** — `TrimSuffix("\r\n")` then `TrimSuffix("\n")` | [V-docs, `internal/configuration/sources/files/helpers.go`] |
| WUD | `fs.readFileSync(path,'utf-8')`, assigned directly | **No** | [V-docs, `app/configuration/index.ts` @ tag `8.3.1`] |
| LSIO (`FILE__`) | `cat "$SECRETFILE" > "$FILESTRIP"` | **No** — and it *prints a warning*: "contains a trailing newline and may not work as expected" | [V-docs, `docker-baseimage-alpine` `init-envfile/run`] |
| homepage (`HOMEPAGE_FILE_`) | `readFileSync(filename,'utf8')` then `replaceAll` into the YAML | **No** — a newline would be spliced into the YAML | [V-docs, `src/utils/config/config.js`] |
| step-ca | `cat < "$FILE" > $STEPPATH/password` | preserves bytes; `step` trims one trailing newline when reading a password file | [V-docs, entrypoint; the trim is **[UNVERIFIED]**] |

`ansible.builtin.copy` with `content=abc` writes exactly **3 bytes**, no
trailing newline [V-live]. → use `copy: content:`, never `template` with a
file that ends in a newline, and never `lineinfile`.

### 4.4 Per-image support, verified from each project

**gluetun `qmcgaw/gluetun:v3.41.3`** — runs as **uid 0** [V-live].
Any variable ending `_SECRETFILE` overrides the default path. Full table
[V-docs, `gluetun-wiki/setup/advanced/docker-secrets.md`]:

| Secret name (compose `secrets:` key) | Default path | Env override |
|---|---|---|
| `wireguard_private_key` | `/run/secrets/wireguard_private_key` | `WIREGUARD_PRIVATE_KEY_SECRETFILE` |
| `wireguard_preshared_key` | `/run/secrets/wireguard_preshared_key` | `WIREGUARD_PRESHARED_KEY_SECRETFILE` |
| `wireguard_addresses` | `/run/secrets/wireguard_addresses` | `WIREGUARD_ADDRESSES_SECRETFILE` |
| `wireguard_conf` | `/run/secrets/wireguard_conf` | `WIREGUARD_CONF_SECRETFILE` |
| `openvpn_user` / `openvpn_password` | `/run/secrets/openvpn_{user,password}` | `OPENVPN_{USER,PASSWORD}_SECRETFILE` |
| `httpproxy_user` / `httpproxy_password` | … | `HTTPPROXY_*_SECRETFILE` |
| `shadowsocks_password` | … | `SHADOWSOCKS_PASSWORD_SECRETFILE` |
| (also `openvpn_clientkey`, `openvpn_clientcrt`, `openvpn_encrypted_key`, `openvpn_key_passphrase`, `amneziawg_conf`) | | |

Priority order: docker secrets > config files > environment variables
[V-docs]. **Because the default paths already match Compose's default target,
gluetun needs no `*_SECRETFILE` env at all** if the compose secret is named
`wireguard_private_key`. Set them anyway for explicitness — cheap and
self-documenting.

**LinuxServer.io images (`plex`, `sonarr`, `radarr`, `prowlarr`, `bazarr`)** —
`FILE__<VAR>=/path` sets `<VAR>` from the file's contents. Documented on the
plex image page: *"`-e FILE__MYVAR=/run/secrets/mysecretvariable` will set the
environment variable `MYVAR` based on the contents of the
`/run/secrets/mysecretvariable` file"* [V-docs, docs.linuxserver.io]. The
handling is an s6 oneshot (`init-envfile`) that runs **as root before
privileges drop to PUID**, so a `0400 root:root` secret file works even though
the app runs as 1028 [V-docs, source]. `PLEX_CLAIM` is a normal env var and is
therefore eligible: `FILE__PLEX_CLAIM=/run/secrets/plex_plex_claim`.
Caveat: Plex claim tokens expire in 4 minutes and are only used at first
claim, so the honest fix here is *delete it from the inventory once claimed*
rather than plumb it — see §5.4.

**WUD `getwud/wud:8.3.1`** — runs as **uid 0** [V-live]. Suffix is
**`__FILE`** (two underscores):

> "If you don't want to expose your secret values as environment variables,
> you can externalize them in external files and reference them by suffixing
> the original env var name with `__FILE`. … This feature can be used for any
> WUD env var (no restrictions)."
> — [V-docs, `docs/configuration/README.md` @ tag `8.3.1`]

Implementation confirmed at that tag: it only scans env vars starting with
`WUD`, strips the suffix, and does **not** trim [V-docs, `app/configuration/index.ts`].
So:
`WUD_TRIGGER_MQTT_HA_PASSWORD__FILE`, `WUD_REGISTRY_LSCR_LINUXSERVER_TOKEN__FILE`.

**step-ca `smallstep/step-ca:0.30.2`** — runs as **uid 1000 (`step`)**
[V-live, `docker run --rm smallstep/step-ca:0.30.2 id` →
`uid=1000(step) gid=1000(step)`]. `DOCKER_STEPCA_INIT_PASSWORD_FILE` exists
and wins over `DOCKER_STEPCA_INIT_PASSWORD`:

```bash
if [ -n "${DOCKER_STEPCA_INIT_PASSWORD_FILE}" ]; then
    cat < "${DOCKER_STEPCA_INIT_PASSWORD_FILE}" > "${STEPPATH}/password"
    cat < "${DOCKER_STEPCA_INIT_PASSWORD_FILE}" > "${STEPPATH}/provisioner_password"
elif [ -n "${DOCKER_STEPCA_INIT_PASSWORD}" ]; then …
```
[V-docs, `smallstep/certificates` `docker/entrypoint.sh`]

**Two crucial consequences the current inventory does not reflect:**

1. The whole `DOCKER_STEPCA_INIT_*` block is guarded by
   `if [ ! -f "${STEPPATH}/config/ca.json" ]`. The util CA is long since
   initialised, so **`DOCKER_STEPCA_INIT_PASSWORD` in the rendered compose
   file is inert** — it is pure leak with zero function. The running CA reads
   `/home/step/secrets/password` from its own volume (`CMD … --password-file
   /home/step/secrets/password`).
2. Because step-ca runs as uid 1000, its secret file must be
   `0400 1000:1000` — a `0400 root:root` file would be unreadable. This is the
   one service in the fleet where the ownership differs.

**Side files:**

- **homepage** (`ghcr.io/gethomepage/homepage:v2.1.2`, runs as root [V-live]):
  > "Environment variables must start with `HOMEPAGE_VAR_` or
  > `HOMEPAGE_FILE_` … The value of env var `HOMEPAGE_FILE_XXX` must be a file
  > path, the contents of which will be used to replace `{{HOMEPAGE_FILE_XXX}}`
  > in any config"
  > — [V-docs, `gethomepage/homepage` `docs/installation/docker.md`]

  So `homepage-services.yaml` becomes committable: `key: {{HOMEPAGE_FILE_SONARR_KEY}}`
  with `HOMEPAGE_FILE_SONARR_KEY=/run/secrets/homepage_sonarr_key`.
- **recyclarr** (`ghcr.io/recyclarr/recyclarr:8.7.1`, runs as **uid 1000**
  [V-live]): supports `!env_var VAR [default]` (since v4.3.0), `!secret KEY`
  (from `secrets.yml` in the config dir), and **`!file /path/to/file`
  (since v7.5.0)** [V-docs, recyclarr.dev value-substitution]. We run 8.7.1, so
  `api_key: !file /run/secrets/recyclarr_sonarr_api_key` works — and
  `recyclarr.yml` becomes committable.

### 4.5 The `env_file` alternative — where it fits

`env_file` (0600 on the host, `env_files:` option exists on
`community.docker.docker_compose_v2` [V-live, `ansible-doc`]) is a legitimate
fallback but strictly worse:

- Values end up in the container's `Config.Env` and are visible to anyone who
  can run `docker inspect` — which, on these hosts, is anyone in the `docker`
  group, i.e. root-equivalent already, but also anything reading the daemon
  over the mTLS 2376 endpoint (WUD's remote watchers).
- They appear in `/proc/<pid>/environ` inside the container.
- Compose reads and interpolates it at `up` time, so the same
  atomic-rename/restart caveat applies anyway.

**Use it only for an image with no file form.** Every current secret consumer
has one, so `env_file` should not be needed at all in Phase 3.

### 4.6 Where the secret files live, and their modes

```
/opt/docker/compose/                     0755 root:root   (unchanged)
/opt/docker/compose/docker-compose.yml   0644 root:root   (unchanged — now secret-free)
/opt/docker/compose/secrets/             0700 root:root   ← new
/opt/docker/compose/secrets/<name>       0400 <uid>:<gid> ← new, one file per secret
```

`0700` on the directory is the real control: even a `0400 1000:1000` file
inside it is unreachable to a non-root local user, because traversal is denied.
Relative `file:` paths in the compose file resolve against the compose file's
directory — verified: `./secrets/x` was expanded to the absolute path in
`docker compose config` output [V-live].

---

## 5. Part 4 — Rotation

### 5.1 `ansible-vault rekey` and inline values — verified failure

```
$ ansible-vault rekey --vault-id mhl@old --new-vault-id mhl@new inline.yml
[ERROR]: Input is not vault encrypted data. for …/inline.yml
exit=1
```
[V-live]

`ansible-vault rekey` operates on **whole vault-encrypted files** only. A YAML
file containing `!vault` scalars is not one. Since A1 chose inline values
precisely to keep `git diff` legible, **rekey needs a custom tool**, and R-A
must supply it or the vault password can never be changed.

`ansible-vault rekey` options actually available (2.19.4) [V-live, `--help`]:
`--vault-id`, `-J/--ask-vault-password`, `--vault-password-file`,
`--encrypt-vault-id`, `--new-vault-password-file`, `--new-vault-id`.
`encrypt_string` options: `--vault-id`, `--encrypt-vault-id`, `-n/--name`,
`--stdin-name`, `-p/--prompt`, `--show-input`, `--output`.

### 5.2 A working rekey script — PoC built and verified this session

Approach: regex out each indented `$ANSIBLE_VAULT;…` block, decrypt with the
old `VaultLib`, re-encrypt with the new, re-indent, splice back. Verified
end-to-end: rekeyed a vaulted inventory, then decrypted the result with the new
password in a real playbook run and got the original plaintext back [V-live].

```python
#!/usr/bin/env python3
"""scripts/mhl-vault-rekey — rekey every inline !vault value in a YAML file."""
import re, sys, getpass
from ansible.parsing.vault import VaultLib, VaultSecret

BLOCK = re.compile(
    r'(?ms)^(?P<ind>[ \t]*)(?P<body>\$ANSIBLE_VAULT;[^\n]*\n(?:(?P=ind)[0-9a-f]+\n)+)')

def main(path, vault_id="mhl"):
    old = VaultLib([(vault_id, VaultSecret(getpass.getpass("old: ").encode()))])
    new = VaultLib([(vault_id, VaultSecret(getpass.getpass("new: ").encode()))])
    src = open(path).read()

    def sub(m):
        ind, body = m.group('ind'), m.group('body')
        plain = old.decrypt(body.replace(ind, '').encode())
        ct = new.encrypt(plain, vault_id=vault_id).decode()
        return ''.join(ind + l if l.strip() else l for l in ct.splitlines(True))

    out = BLOCK.sub(sub, src)
    open(path, 'w').write(out)

if __name__ == "__main__":
    main(sys.argv[1])
```

Notes: it never writes plaintext to disk; it re-encrypts every block so the
whole file churns in `git diff` (expected and correct for a rekey); run it on a
clean tree so the diff is reviewable.

### 5.3 Rotating the **vault password** (all secrets stay the same)

Green/red at each step.

1. `make validate` on a clean tree → **green** before starting.
2. Generate a new password; write it to `~/.mhl/vault/mhl.pass.new` (0600).
3. `git checkout -b rekey/vault-YYYY-MM-DD` in the inventory repo.
4. `scripts/mhl-vault-rekey hosts.yml` (and any other file with inline values).
5. `mv ~/.mhl/vault/mhl.pass{,.old}; mv ~/.mhl/vault/mhl.pass{.new,}`.
6. **Green/red:** `ansible-inventory -i hosts.yml --list` still parses, and a
   `--check` run of a play that *uses* a secret succeeds (parse alone does not
   prove decryption — §3.1).
7. Update the password-manager entry (§2.4). **Do this before deleting
   `.old`.**
8. Open the PR (Q5). Merge. Then `shred -u ~/.mhl/vault/mhl.pass.old`.

**What git history means here.** Rekeying re-encrypts the *current* values;
every historical commit still holds ciphertext encrypted under the **old**
password. Anyone who ever had the old password can still read history. So:

- A vault-password rotation is a **response to controller compromise or an
  access change**, and it does **not** protect past commits.
- If a *secret value* leaks, rotating the vault password is the wrong lever.
  Rotate **the secret at its source** (§5.4). The old value stays in git
  history forever, encrypted; it is only dangerous if the old vault password
  also leaked, in which case rotate both and treat every historical secret as
  burned.
- Never rewrite git history to "remove" a vaulted secret. It is already
  encrypted; a rewrite breaks the PR flow and the audit trail for no gain.

### 5.4 Rotating **one secret** end-to-end — worked example: the step-ca provisioner password

This is the messiest one in the fleet, which is why it is the example. It
appears in **four** places: `all.vars.step_ca_provisioner_password` (used by
the `step-ca-cert` role to mint the WUD client leaf), two per-host
`ca_provisioner_password` values, and `services.step-ca.environment.DOCKER_STEPCA_INIT_PASSWORD`
(which, per §4.4, is **inert** on the already-initialised CA).

1. **Open an incident/decision note** (Q1: a parameter change must be
   codified). `incidents/INCIDENT-2026-xx-xx-stepca-provisioner-rotate.md`.
2. **Change it at the source — the CA itself.** The compose env var does not
   set the running CA's password. On util:
   `step ca provisioner update <name>` (re-encrypt the provisioner's
   encrypted key under a new password) and update
   `/home/step/secrets/password` if the *key* password is rotating too.
   **Exact `step` subcommand/flags: [UNVERIFIED] — check `step ca provisioner
   update --help` on the live host before running.** Never invent them.
3. **Update the inventory:** `scripts/mhl-vault-set all.vars.step_ca_provisioner_password`
   and the two `ca_provisioner_password` entries. One `git diff` hunk per
   changed value — the whole reason A1 chose inline over whole-file.
4. **Delete `DOCKER_STEPCA_INIT_PASSWORD` from `hosts.yml`** rather than
   re-vaulting it. It does nothing on a live CA. If you want a from-scratch
   rebuild to be reproducible, replace it with a vaulted value delivered as a
   compose secret at `0400 1000:1000` per §4.4 — but say so in the note.
5. **PR → review → merge** (Q5). No apply from a dirty tree (Q9b).
6. **Apply:** `ansible-playbook site.yml` (no `--limit`, per the standing rule).
   The role writes `secrets/step-ca_docker_stepca_init_password` (if kept),
   `register`s the change, and `docker compose restart step-ca`.
7. **Green/red:**
   - `docker compose exec step-ca step ca health` → `ok`.
   - Force a WUD leaf re-issue with the new provisioner password and confirm
     the cert is minted.
   - `make validate` green.
8. **Close the incident** with what changed and where it was codified.

**Shorter template for the other secrets:**

| Secret | Rotate at | Then |
|---|---|---|
| AirVPN WG private/preshared key | AirVPN portal (new device/config) | `mhl-vault-set`, PR, apply → gluetun secret file changes → restart gluetun; **re-assert qBT `current_network_interface=tun0`** (existing known trap) |
| `wud_lscr_token` (GitHub PAT) | GitHub → fine-grained PAT, new expiry | `mhl-vault-set`, PR, apply → restart wud; verify LSCR images are watched again |
| `wud_mqtt_password` | HA/MQTT broker user | rotate broker first, then inventory, then restart wud |
| ARR API keys (homepage/recyclarr) | each *arr's Settings → General → API Key | update the vaulted values, apply → homepage + recyclarr secret files → restart both |
| `vmware_vcenter_password` | vCenter SSO | inventory only (controller-side; no container) |
| `ext_target_pass` | `mkpasswd -m sha-512` | inventory only; affects future provisioning only |
| `PLEX_CLAIM` | n/a — expires in 4 min | **delete it**; it is a one-shot claim token, not a standing credential |

---

## 6. Part 5 — Concrete proposed layout

### 6.1 Files

**Outside both repos (never committed, never in `export_root`):**

```
~/.mhl/vault/                       0700  <user>
~/.mhl/vault/mhl.pass               0600  <user>   the vault password, no trailing newline
~/.mhl/bin/mhl-vault-client         0700  <user>   the *-client script
```

Deliberately **not** under `~/.mhl/` root next to `registry.json`: `~/.mhl` is
`export_root`, it is 0755, and it is full of derived artefacts. A 0700
subdirectory keeps the password out of any future recursive fetch/copy.

**In `McHomeLab` (tracked):**

```
ansible/ansible.cfg                          + vault_identity_list
scripts/mhl-vault-set                        splice one inline !vault value
scripts/mhl-vault-rekey                      §5.2
scripts/mhl-no-secrets                       §6.5 scanner
ansible/roles/service/vars/main.yml          + secret manifest + style map
ansible/roles/service/tasks/main.yml         + secret dir/files/restart tasks
ansible/roles/service/templates/*.j2         secrets routed, no plaintext
ansible/roles/controller/tasks/main.yml      assert vault client present & executable
ansible/tests/render.yml                     render + `docker compose config -q` + scan
Makefile                                     validate: adds no-secrets + vault probe
```

**In `McHomeLab-Inventory` (tracked, after Phase 1):**

```
hosts.yml                    with inline !vault  (removed from .gitignore)
homepage-services.yaml       with {{HOMEPAGE_FILE_*}}  (removed from .gitignore)
recyclarr.yml                with !file /run/secrets/*  (removed from .gitignore)
```

### 6.2 `ansible/ansible.cfg`

```ini
[defaults]
vault_identity_list = mhl@~/.mhl/bin/mhl-vault-client
; NB: a *relative* path here resolves against cwd, NOT against this file's
; directory (verified 2026-08-25). Use ~/ or an absolute path only.

[inventory]
enable_plugins = vmware.vmware.vms, yaml, ini
```

Optionally also `vault_encrypt_identity = mhl` (`DEFAULT_VAULT_ENCRYPT_IDENTITY`)
so `encrypt_string` needs no `--encrypt-vault-id` once a second id ever exists.

### 6.3 `~/.mhl/bin/mhl-vault-client`

```bash
#!/usr/bin/env bash
# Ansible vault password client. ansible-core invokes this with
#   --vault-id <label>
# and reads the password from stdout. (Verified: argv is exactly
# "--vault-id mhl" for vault_identity_list = mhl@<this file>.)
set -euo pipefail

label="default"
while [ $# -gt 0 ]; do
  case "$1" in
    --vault-id) label="$2"; shift 2 ;;
    --vault-id=*) label="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

case "$label" in
  mhl) store="${MHL_VAULT_PASS_FILE:-$HOME/.mhl/vault/mhl.pass}" ;;
  *)   echo "mhl-vault-client: unknown vault-id '$label'" >&2; exit 1 ;;
esac

[ -r "$store" ] || { echo "mhl-vault-client: cannot read $store" >&2; exit 1; }
perm=$(stat -c '%a' "$store")
[ "$perm" = "600" ] || { echo "mhl-vault-client: $store is $perm, want 600" >&2; exit 1; }

# No trailing newline in output (ansible strips it, but be explicit).
printf '%s' "$(cat "$store")"
```

The mode check is deliberate: it turns a silent security regression into a red
run. The `MHL_VAULT_PASS_FILE` override is the seam for the deferred Q4 timer,
where systemd would set it to `${CREDENTIALS_DIRECTORY}/mhl_vault` from
`LoadCredentialEncrypted=`.

**Upgrade paths, same script, one `case` arm each:**

```bash
  # pass backend:      store=$(pass show mhl/ansible-vault | head -n1)
  # systemd-creds:     store="${CREDENTIALS_DIRECTORY}/mhl_vault"
```

### 6.4 `scripts/mhl-vault-set` (sketch)

```bash
#!/usr/bin/env bash
# mhl-vault-set <dotted.path>   — prompt for a value, encrypt it as an inline
# !vault scalar, and splice it into hosts.yml at that path.
set -euo pipefail
INV="${MHL_INVENTORY:-$HOME/workspace/McHomeLab-Inventory/hosts.yml}"
path="$1"; key="${path##*.}"
indent=$(python3 - "$INV" "$path" <<'PY'
# resolve the YAML path, return the column the key sits at (ruamel round-trip)
PY
)
ansible-vault encrypt_string --vault-id mhl@~/.mhl/bin/mhl-vault-client \
  --name "$key" --prompt \
  | python3 scripts/_splice.py "$INV" "$path" "$indent"
```

Implementation note: use `ruamel.yaml` in round-trip mode so comments and
ordering survive; `ansible-vault encrypt_string -n <name>` already emits the
`name: !vault |` form, so only the indentation has to be adjusted to the
target column. `--show-input` exists if you want the value echoed while
typing (do not use it).

### 6.5 The no-secrets check — regex that catches **unquoted** YAML values

Two independent passes. Both tested this session against synthetic fixtures
**and** counted against the real `hosts.yml` [V-live].

**Pass A — name-shaped.** Any key whose name *ends* in a secret word must have
a `!vault` or `{{ … }}` value.

```bash
NAME_RE='^[ \t-]*[A-Za-z0-9_.]*(?i:password|passwd|secret|token|api_?key|apikey|claim|private_key|preshared_key|credential)[ \t]*:[ \t]*(?!(!vault|\{\{|"\{\{|'"'"'\{\{|$|#))\S'
grep -rnP "$NAME_RE" hosts.yml *.yaml *.yml && exit 1 || true
```

Anchoring the secret word at the **end of the key** is what removes the two
false positives a naive pattern produces:

| Line | naive `password|token|…` anywhere | anchored |
|---|---|---|
| `bad_unquoted_password: hunter2` | match | **match** ✔ |
| `bad_quoted_password: "hunter2"` | match | **match** ✔ |
| `bad_single_token: 'ghp_…'` | match | **match** ✔ |
| `PLEX_CLAIM: claim-ABC…` | match | **match** ✔ |
| `ansible_ssh_private_key_file: "~/.ssh/id_ed25519"` | match (false positive) | no match ✔ |
| `passwordless_sudo: true` | match (false positive) | no match ✔ |
| `wud_mqtt_password: !vault \|` | — | no match ✔ |
| `step_ca_provisioner_password: "{{ vault_x }}"` | — | no match ✔ |
| `empty_password:` | — | no match ✔ |

All rows verified by running the pattern. Against the real `hosts.yml` today
it matches **10** lines — i.e. it is currently red, exactly as it should be
until Phase 1 lands.

**Pass B — value-shaped**, for secrets whose key name gives nothing away.

```bash
SHAPE_RE='(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])|gh[pousr]_[A-Za-z0-9]{36,}|claim-[A-Za-z0-9_-]{15,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
grep -rnP "$SHAPE_RE" --exclude-dir=.git . && exit 1 || true
```

(44-char base64 = WireGuard key; GitHub PAT prefixes; Plex claim; any PEM
private key.) Against the real `hosts.yml`: **3** matches today. Against
`ansible/`: exactly **1** — `ansible/inventory/test-key`, the committed lint
fixture from §1.3. Note the vault ciphertext is *hex*, so Pass B never
false-positives on `!vault` blocks [V-live].

**Wiring:** a `Makefile` target `no-secrets`, plus the same script as a
`guard_writes`/pre-commit hook so the agent literally cannot commit a
plaintext secret (Phase 2, Q9).

### 6.6 Role changes — `service`

**`vars/main.yml` (new):**

```yaml
service_secrets_dir: "{{ service_dir }}/secrets"
service_secrets_dir_mode: "0700"
service_secret_file_mode: "0400"

# How each image family consumes a secret file, and which uid must read it.
# Verified 2026-08-25 (see RESEARCH_SECRETS_RA.md §4.4).
service_secret_styles:
  gluetun:  {prefix: "",       suffix: "_SECRETFILE", uid: 0,    gid: 0}
  lsio:     {prefix: "FILE__", suffix: "",            uid: 0,    gid: 0}
  wud:      {prefix: "",       suffix: "__FILE",      uid: 0,    gid: 0}
  stepca:   {prefix: "",       suffix: "_FILE",       uid: 1000, gid: 1000}
  homepage: {prefix: "",       suffix: "",            uid: 0,    gid: 0}   # {{HOMEPAGE_FILE_X}}
  recyclarr:{prefix: "",       suffix: "",            uid: 1000, gid: 1000} # !file
  none:     {prefix: "",       suffix: "",            uid: 0,    gid: 0}   # env_file fallback

# One entry per (service, ENV_NAME) declared under services.<x>.secrets
service_secret_manifest: "{{ service_services | mhl_secret_manifest(service_secret_styles) }}"
```

**Inventory shape (`hosts.yml`) — one new key per service:**

```yaml
services:
  plex:
    image: "lscr.io/linuxserver/plex:1.43.3.10896-cb3ebc72d-ls321"
    secret_style: "lsio"
    environment:
      PUID: "1028"
      PGID: "100"
    secrets:                      # ← every !vault value lives here and nowhere else
      PLEX_CLAIM: !vault |
        $ANSIBLE_VAULT;1.2;AES256;mhl
        …
```

Why an explicit `secrets:` block rather than auto-detecting `!vault` anywhere?
Because `is vault_encrypted` can tell you *that* a value is a secret (verified,
§3.1) but not *how the image consumes it* — `_SECRETFILE` vs `__FILE` vs
`FILE__` vs `_FILE` vs a YAML tag. Keeping the declaration explicit makes the
mapping reviewable in a PR. **`is vault_encrypted` is then used as the
guard**: the render test asserts no `!vault` value appears *outside* a
`secrets:` block, which catches a secret pasted into `environment:` by hand.

**Filter plugin `filter_plugins/mhl_secrets.py` (sketch):**

```python
def mhl_secret_manifest(services, styles):
    out = []
    for svc_name, svc in (services or {}).items():
        style_name = svc.get('secret_style', 'none')
        style = styles[style_name]
        for env_key, value in (svc.get('secrets') or {}).items():
            name = f"{svc_name}_{env_key}".lower()
            out.append({
                'service':   svc_name,
                'name':      name,
                'env_key':   f"{style['prefix']}{env_key}{style['suffix']}",
                'container': f"/run/secrets/{name}",
                'value':     value,          # AnsibleVaultEncryptedUnicode -> str
                'uid':       style['uid'],
                'gid':       style['gid'],
                'style':     style_name,
            })
    return out

class FilterModule:
    def filters(self):
        return {'mhl_secret_manifest': mhl_secret_manifest}
```

**Template sketch — `docker-compose.yml.j2`, service block:**

```jinja
{% set svc_secrets = service_secret_manifest | selectattr('service', 'eq', svc_name) | list %}
{% if svc.environment is defined or svc_secrets %}
    environment:
{% for key, val in (svc.environment | default({})).items() %}
      {{ key }}: "{{ val }}"
{% endfor %}
{% for s in svc_secrets %}
{% if s.style not in ['homepage', 'recyclarr', 'none'] %}
      {{ s.env_key }}: "{{ s.container }}"
{% elif s.style == 'homepage' %}
      HOMEPAGE_FILE_{{ s.env_key }}: "{{ s.container }}"
{% endif %}
{% endfor %}
{% endif %}
{% if svc_secrets %}
    secrets:
{% for s in svc_secrets %}
      - {{ s.name }}
{% endfor %}
{% endif %}
```

**and the top-level block, once, at the end of the file:**

```jinja
{% if service_secret_manifest %}
secrets:
{% for s in service_secret_manifest %}
  {{ s.name }}:
    file: "{{ service_secrets_dir }}/{{ s.name }}"
{% endfor %}
{% endif %}
```

**`gluetun.yml.j2` — before / after:**

```jinja
{# BEFORE — plaintext in a 0644 file #}
      WIREGUARD_PRIVATE_KEY: "{{ config.wireguard_private_key }}"

{# AFTER — the secret is a file; gluetun's default path already matches, #}
{# the env var is set anyway so the compose file documents itself.       #}
      WIREGUARD_PRIVATE_KEY_SECRETFILE: "/run/secrets/gluetun_wireguard_private_key"
```

**`wud.yml.j2` — before / after:**

```jinja
      WUD_TRIGGER_MQTT_HA_PASSWORD__FILE: "/run/secrets/wud_wud_trigger_mqtt_ha_password"
      WUD_REGISTRY_LSCR_LINUXSERVER_TOKEN__FILE: "/run/secrets/wud_wud_registry_lscr_linuxserver_token"
```

(`wud_mqtt_user` and `wud_lscr_username` are usernames, not secrets — leave
them as plain env.)

**`tasks/main.yml` additions:**

```yaml
- name: "Ensure compose secrets directory"
  ansible.builtin.file:
    path: "{{ service_secrets_dir }}"
    state: directory
    owner: root
    group: root
    mode: "{{ service_secrets_dir_mode }}"

- name: "Write compose secret files"
  ansible.builtin.copy:
    content: "{{ item.value }}"        # copy writes the string verbatim: no trailing newline
    dest: "{{ service_secrets_dir }}/{{ item.name }}"
    owner: "{{ item.uid }}"
    group: "{{ item.gid }}"
    mode: "{{ service_secret_file_mode }}"
  loop: "{{ service_secret_manifest }}"
  loop_control:
    label: "{{ item.name }}"
  no_log: true                          # keeps --diff and -vvv clean
  register: service_secret_writes

- name: "Prune secret files no longer declared"
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop: "{{ (query('ansible.builtin.fileglob', service_secrets_dir ~ '/*'))
            | reject('in', service_secret_manifest | map(attribute='name')
                            | map('regex_replace', '^', service_secrets_dir ~ '/') | list)
            | list }}"

# … existing template + docker_compose_v2 tasks unchanged …

# MUST come after the compose `up`: a changed secret file does not change the
# compose config-hash, so `up` will not recreate the container, and Ansible's
# atomic-rename write leaves the running container bound to the old inode.
# (Both verified 2026-08-25 — RESEARCH_SECRETS_RA.md §4.2.)
- name: "Restart services whose secret files changed"
  community.docker.docker_compose_v2:
    project_src: "{{ service_dir }}"
    state: restarted
    services: "{{ _changed }}"
  vars:
    _changed: "{{ service_secret_writes.results | selectattr('changed')
                  | map(attribute='item.service') | unique | list }}"
  when: _changed | length > 0
```

**Two `no_log` notes.** (i) `no_log: true` on the write task is what keeps
`--check --diff` from printing the secret — verified this session that a
`template` task with a vaulted variable prints `+PASSWORD=hunter2` in the diff
[V-live]. Because the secrets now live in their own tiny files, the big
`docker-compose.yml` diff stays fully readable while only the secret writes are
suppressed. That is a real, concrete win of file-secrets over inline env.
(ii) `diff: false` is also a valid task keyword (`applies_to: Play, Role,
Block, Task, Handler`, type bool) [V-live, `ansible-doc -t keyword diff`] if you
want the change *reported* without the content.

### 6.7 `controller` role addition (Q12)

```yaml
- name: "Assert the vault client is installed and usable"
  ansible.builtin.stat:
    path: "{{ ansible_env.HOME }}/.mhl/bin/mhl-vault-client"
  register: _vc
- ansible.builtin.assert:
    that:
      - _vc.stat.exists
      - _vc.stat.executable
      - _vc.stat.mode in ['0700', '0500']
    fail_msg: "mhl-vault-client missing or wrong mode — see RESEARCH_SECRETS_RA.md §6.3"
```

---

## 7. Part 6 — PoC checklist for Phase 1

Each step has an explicit green/red. Steps P1–P6 are Phase 1 (inventory
vaulting); P7–P12 are the Phase 3 compose delivery, listed here because R-A
owns the design and the PoC should prove it before Phase 1 freezes the
inventory shape.

| # | Step | GREEN | RED |
|---|---|---|---|
| **P1** | Install `~/.mhl/vault/mhl.pass` (0600) and `~/.mhl/bin/mhl-vault-client` (0700). Escrow the password in the PM (§2.4). | `~/.mhl/bin/mhl-vault-client --vault-id mhl` prints the password and exits 0 | any other output, or nonzero exit |
| **P2** | Add `vault_identity_list = mhl@~/.mhl/bin/mhl-vault-client` to `ansible/ansible.cfg`. | From `ansible/`, `ansible-config dump --only-changed \| grep VAULT_IDENTITY` shows it | path resolved against cwd (§2.1) |
| **P3** | **Vault-availability probe** — a one-task play that decrypts a canary vaulted var. *(This is the step §3.1 shows `ansible-inventory --list` does NOT cover.)* | task prints the canary | `Attempting to decrypt but no vault secrets found` |
| **P4** | Vault the 11 `hosts.yml` values (§1.1) with `mhl-vault-set`, one commit per logical group. | `git diff` shows exactly one changed hunk per rotated value; unchanged keys untouched | whole-file churn (means whole-file vault crept in) |
| **P5** | `ansible-inventory -i hosts.yml --list` and `ansible-lint --profile production` and `yamllint`. | all three exit 0; `--list` output contains `__ansible_vault` and **no plaintext** | any plaintext in `--list` |
| **P6** | `scripts/mhl-no-secrets` (both passes, §6.5). | exit 0 — currently red at 10 + 3 matches | any match outside the `test-key` exception |
| **P6b** | Remove `hosts.yml` from the inventory repo's `.gitignore`; first PR (Q5). | PR opens, CI/`make validate` green, merge | — |
| **P7** | Rekey drill on a **copy** of `hosts.yml` with `scripts/mhl-vault-rekey`. | old password fails, new password decrypts, values identical | mixed-password file |
| **P8** | Convert **gluetun on media** first (simplest: runs as root, default paths already match). Render to scratch, `docker compose config -q`. | exits 0 with the secret files absent (verified this is expected, §4.1) | any failure |
| **P9** | Apply to media. | `grep -c 'WIREGUARD_PRIVATE_KEY:' /opt/docker/compose/docker-compose.yml` → **0**; `stat -c '%a %U' secrets/*` → `400 root`; dir `700 root`; `docker compose exec gluetun ...` reports the tunnel up; **public IP still the VPN exit** | any plaintext left, or tunnel down |
| **P10** | Change the WG key to a new value and re-apply. | the `Restart services whose secret files changed` task fires and only `gluetun` restarts; the new key is in effect | container not restarted → §4.2 trap not handled |
| **P11** | Convert **step-ca on util** (the uid-1000 case) — or, better, delete the inert `DOCKER_STEPCA_INIT_PASSWORD` per §5.4 step 4. | `step ca health` → `ok`; if the secret file is kept, `stat` shows `400 1000:1000` | `Permission denied` in the container log |
| **P12** | Convert WUD, homepage (`{{HOMEPAGE_FILE_*}}`), recyclarr (`!file`); un-gitignore `homepage-services.yaml` and `recyclarr.yml`. | WUD watches LSCR images and publishes to MQTT; homepage widgets render live data; `recyclarr sync --preview` reads its keys (remember: read `logs/cli/*.debug.log`, the non-TTY preview hides tables) | any widget shows an auth error |
| **P13** | Housekeeping: delete `media:/opt/docker/compose/docker-compose.yml.bak-2026-07-19` and `util:/opt/docker/compose/diun-watch.yml` (retire per the non-destructive rule: move to an `archive/` path with a note, **confirm each deletion explicitly**). | both gone from the live hosts | — |
| **P14** | `make validate` end to end, plus `ansible-playbook --check --diff site.yml` with **no plaintext secret anywhere in the diff**. | green, clean diff | any secret visible in `--diff` → a `no_log` is missing |

---

## 8. Open questions / what was not verified

- **OpenBao + `community.hashi_vault`** — plausible (API-compatible fork) but
  not tested. Only matters if the "later layer" in §2.3 is ever built.
- **vTPM on the future controller VM** — `systemd-creds` TPM sealing on a
  vSphere VM needs a Native Key Provider on this vCenter. Not checked.
- **`step ca provisioner update` exact flags** — deliberately not guessed;
  §5.4 says to read `--help` on the live host first.
- **Whether `step` trims a trailing newline from a `--password-file`** — the
  no-trailing-newline rule makes this moot either way.
- **The `!vault`-outside-`secrets:` guard** — the `is vault_encrypted` test is
  verified to work; the guard task that walks the inventory with it has not
  been written.
- **Other per-app configs on media** (`cross-seed`, `qbit-manage`, `qbitrr`,
  qBittorrent itself) were not swept for credentials. The Phase 3 sweep must
  cover them; only homepage and recyclarr were traced here because they are the
  two that gate un-gitignoring the inventory repo.
- **`community.general.bitwarden` against Vaultwarden** — noted as the working
  path if a Bitwarden-shaped answer is ever wanted, but not tested, and not
  recommended.

---

## 9. Sources

Ansible:
- https://docs.ansible.com/projects/ansible/latest/vault_guide/vault_managing_passwords.html
- https://docs.ansible.com/projects/ansible/latest/vault_guide/vault_using_encrypted_content.html
- https://docs.ansible.com/projects/ansible/latest/collections/community/hashi_vault/docsite/CHANGELOG.html
- https://github.com/ansible-collections/community.hashi_vault
- https://galaxy.ansible.com/ui/repo/published/infisical/vault/ · https://github.com/Infisical/ansible-collection
- https://github.com/bitwarden/sm-ansible
- https://github.com/1Password/ansible-onepasswordconnect-collection
- local `ansible-config list`, `ansible-doc`, `ansible-vault --help` (ansible-core 2.19.4, ansible-lint 25.9.2)

Docker / Compose:
- https://docs.docker.com/reference/compose-file/secrets/
- https://docs.docker.com/reference/compose-file/services/#secrets
- local `docker compose` v5.5.0 experiments

Images:
- https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/docker-secrets.md
- https://github.com/qdm12/gluetun `internal/configuration/sources/files/helpers.go`
- https://docs.linuxserver.io/images/docker-plex/ · `linuxserver/docker-baseimage-alpine` `root/etc/s6-overlay/s6-rc.d/init-envfile/run`
- https://github.com/getwud/wud `docs/configuration/README.md`, `app/configuration/index.ts` @ `8.3.1`
- https://github.com/smallstep/certificates `docker/entrypoint.sh`, `docker/Dockerfile`
- https://github.com/gethomepage/homepage `docs/installation/docker.md`, `src/utils/config/config.js`
- https://recyclarr.dev/reference/configuration/value-substitution/

Stores:
- https://github.com/openbao/openbao (MPL-2.0, v2.6.2 2026-08-18)
- https://github.com/hashicorp/vault `LICENSE` (BUSL-1.1, licensor IBM)
- https://github.com/dani-garcia/vaultwarden/discussions/5702 (no Secrets Manager API)
- https://git.zx2c4.com/password-store/ (v1.7.4)
