# Barebones Server Install

Use this path when you want a minimal single-host deployment with:

- host **Asterisk**
- repo-local **Asterisk AI Voice Agent** stack
- **local-core** model services (`local_ai_server`, `ai_engine`, `admin_ui`)
- a ready-to-route dialplan entry at **`from-ai-agent,s,1`**

This is intentionally **not** the full FreePBX installer path. It bootstraps a plain Debian/Ubuntu server so you can route directly in Asterisk or later point FreePBX at the already-created `from-ai-agent,s,1` destination.

## What the installer does

`scripts/install-barebones-server.sh` will:

1. install host packages:
   - Docker
   - Docker Compose v2
   - Asterisk
   - `git`, `make`, `curl`, `jq`, `python3`, `rsync`
2. add the operator user to the **`asterisk`** and **`docker`** groups
3. create/update repo `.env` for local host Asterisk access
4. configure host Asterisk for:
   - ARI on `127.0.0.1:8088`
   - a local ARI user
   - `from-ai-agent` dialplan context
   - CLI socket ownership/perms compatible with `asterisk:asterisk`
5. run `make model-setup`
6. run `./preflight.sh --apply-fixes`
7. start the local-core stack with:
   ```bash
   docker compose -p asterisk-ai-voice-agent \
     -f docker-compose.yml \
     -f docker-compose.local-core.yml \
     up -d --build --force-recreate local_ai_server ai_engine admin_ui
   ```
8. verify Asterisk socket access, dialplan presence, and `http://127.0.0.1:15000/health`

## Supported target

Current script target:

- **Debian/Ubuntu** hosts with `apt`

Validated repo-side assumptions match the host-local notes in [FreePBX-Integration-Guide.md](FreePBX-Integration-Guide.md#44-validated-host-notes-for-ubuntu-2404--freepbx-17-manual-installs), especially:

- operator user should be in the `asterisk` group for non-root `asterisk -rx ...`
- Asterisk control socket should stay owned by `asterisk:asterisk`
- host Asterisk should expose ARI/HTTP locally

## Quick start

Clone the repo, then run:

```bash
git clone https://github.com/innotelinc/AI-Voice-Agent-for-Asterisk.git
cd AI-Voice-Agent-for-Asterisk
sudo scripts/install-barebones-server.sh --operator-user "$USER"
```

If you are running as a different maintenance account, pass that explicitly:

```bash
sudo scripts/install-barebones-server.sh --operator-user claude
```

## Verification-only mode

To inspect an already-bootstrapped host without changing it:

```bash
sudo scripts/install-barebones-server.sh --check
```

This prints:

- operator identity
- Asterisk version + CLI reachability
- socket permissions
- `from-ai-agent` dialplan presence
- ARI/http custom config excerpts
- `ai_engine` health output if available

## Custom ARI credentials

Default ARI user config written by the script:

- username: `aava`
- password: `AAVAchangeMeNow123!`

Override at install time:

```bash
sudo scripts/install-barebones-server.sh \
  --operator-user "$USER" \
  --ari-user myagent \
  --ari-password 'replace-this-with-a-real-secret'
```

## What the script writes

Host Asterisk files:

- `/etc/asterisk/ari_additional_custom.conf`
- `/etc/asterisk/http_custom.conf`
- `/etc/asterisk/extensions_custom.conf`
- `/etc/asterisk/asterisk.conf` (socket settings only)

Repo files:

- `.env` (created from `.env.example` if missing, then updated)
- model downloads under the repo’s standard model directories
- `data/asterisk_status.json` via `preflight.sh`

The script uses **managed block markers** for the ARI, HTTP, and dialplan inserts so rerunning it is idempotent.

## After install

### Direct Asterisk routing

Route any extension, inbound DID, or test destination to:

```text
from-ai-agent,s,1
```

### FreePBX routing

If you later install or already run FreePBX, create a **Custom Destination** that targets:

```text
from-ai-agent,s,1
```

Then point a Misc Application, Inbound Route, Ring Group, Queue destination, etc. at that Custom Destination.

## Common follow-ups

### New group membership not visible yet

If the operator user was newly added to `docker` or `asterisk`, log out and back in before expecting non-root access to work cleanly.

### Health endpoint is up but calls fail

Check:

```bash
asterisk -rx 'dialplan show from-ai-agent'
curl -fsS http://127.0.0.1:15000/health
docker compose -p asterisk-ai-voice-agent logs --tail=100 ai_engine
```

### You want the full PBX GUI path

Use this script first for the bare host, then follow:

- [FreePBX Integration Guide](FreePBX-Integration-Guide.md)
- [HOST_LOCAL_MODE_RUNBOOK.md](HOST_LOCAL_MODE_RUNBOOK.md)

## Notes

- This script is aimed at the **local-core** profile because it is the simplest reproducible bare-server deployment.
- It does **not** install FreePBX for you.
- It does **not** create a PJSIP extension like `1001`; that remains a PBX/admin task.
- It is safe to rerun when you want to reapply the managed Asterisk blocks and host-local `.env` wiring.
