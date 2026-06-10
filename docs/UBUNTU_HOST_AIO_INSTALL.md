# Ubuntu Host AIO Install

Use this when you want a **single command** to bootstrap the validated Ubuntu host pattern for:

- **host Asterisk**
- **local-core Asterisk AI Voice Agent (AAVA)**
- **manual FreePBX 17** on top of that host Asterisk

This document is the operator-facing wrapper for the two validated installers already in this repo.

## Entry point

```bash
sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh --operator-user "$USER"
```

## What this wrapper does

The wrapper chains these repo-owned installers in order:

1. `scripts/install-barebones-server.sh`
   - installs host dependencies for Docker + Asterisk
   - prepares repo `.env`
   - configures host Asterisk ARI/HTTP and `from-ai-agent`
   - runs model/bootstrap and local-core stack startup unless skipped

2. `scripts/install-freepbx-ubuntu-host.sh`
   - installs Apache, MariaDB, PHP 8.2, and FreePBX prerequisites
   - performs the manual FreePBX 17 framework install validated for Ubuntu hosts
   - aligns Apache runtime and Asterisk control-socket permissions
   - installs the validated FreePBX module set

## Why this exists

The repo already had both lower-level installers, but operators still had to know which one to run first. This wrapper provides the **one obvious command** for the common request:

> “Install everything needed on this Ubuntu host for host Asterisk + AAVA + FreePBX.”

## Supported target

Validated for:

- **Ubuntu** hosts
- **apt-based** systems
- a deployment where **Asterisk runs on the host**
- AAVA services run from this repo
- FreePBX is installed using the **manual Ubuntu framework path**, not Sangoma's Debian all-in-one installer

## Usage

### Full install

```bash
sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh --operator-user "$USER"
```

### Verification only

```bash
sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh --check
```

### Provision the FreePBX AI route too

```bash
sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh \
  --operator-user "$USER" \
  --provision-ai-route
```

Optional route overrides:

```bash
sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh \
  --operator-user "$USER" \
  --provision-ai-route \
  --ai-route-target from-ai-agent,s,1 \
  --ai-route-extension 7000 \
  --ai-route-description "AI Agent Test" \
  --ai-custom-dest-description "AI Agent Entry"
```

### Verify an existing FreePBX AI route

```bash
sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh \
  --check \
  --check-ai-route \
  --ai-route-extension 7000 \
  --ai-route-target from-ai-agent,s,1
```

This verifies both:

- the FreePBX objects exist as expected
- the compiled Asterisk dialplan still resolves through `app-miscapps` into `from-ai-agent,s,1`
- the AI entry target still contains `Stasis(asterisk-ai-voice-agent)`

### Skip model download

```bash
sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh \
  --operator-user "$USER" \
  --skip-models
```

### Skip stack startup

```bash
sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh \
  --operator-user "$USER" \
  --skip-stack
```

### Run only one half

```bash
# Only host Asterisk + AAVA
sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh --skip-freepbx

# Only FreePBX on an already prepared host Asterisk box
sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh --skip-aava
```

## Important caveats

This wrapper **does not** attempt to version-control or commit host-local runtime state such as:

- `/etc/asterisk/*`
- `/etc/apache2/*`
- `/etc/freepbx.conf`
- `/etc/amportal.conf`
- MariaDB runtime state
- FreePBX GUI objects stored on the host

It also does **not** automate these GUI-driven/operator-specific items by default:

1. the first FreePBX web-admin account creation wizard
2. softphone registration and user-specific endpoint credentials

The PBX-facing AI route can now be provisioned noninteractively when you opt in with:

```bash
sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh \
  --operator-user "$USER" \
  --provision-ai-route
```

That mode uses FreePBX's own PHP bootstrap plus the `customappsreg` and `miscapps` modules to create or update:

- a **Custom Destination** pointing to `from-ai-agent,s,1`
- a **Misc Application** pointing to that Custom Destination

It remains optional because extension numbers, route descriptions, and PBX object naming are operator choices.

## After the wrapper finishes

1. Open FreePBX:
   ```text
   http://YOUR-HOST/admin
   ```
2. Complete the first-run admin wizard if prompted
3. Create:
   - **Custom Destination** → `from-ai-agent,s,1`
   - **Misc Application** → that destination
4. Verify:
   ```bash
   asterisk -rx 'dialplan show from-ai-agent'
   asterisk -rx 'dialplan show 7000@app-miscapps'
   asterisk -rx 'pjsip show endpoints'
   ```
5. Register a softphone and place a real call into the FreePBX-facing AI route

## Related docs

- [Barebones Server Install](BAREBONES_SERVER_INSTALL.md)
- [FreePBX Ubuntu Host Bootstrap](FREEPBX_UBUNTU_HOST_BOOTSTRAP.md)
- [FreePBX Integration Guide](FreePBX-Integration-Guide.md)
- [FreePBX Ubuntu Host Validation](freepbx/FreePBX-Ubuntu-Host-Validation.md)
