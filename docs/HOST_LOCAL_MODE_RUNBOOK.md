# Host Local-Mode Runbook

This runbook documents the host-local Asterisk + Docker local-AI setup validated on this machine.

## Scope

Use this when:
- Asterisk runs on the same Linux host as AAVA
- `ai_engine`, `admin_ui`, and `local_ai_server` run in Docker
- the active pipeline is `local_hybrid`
- Asterisk hands calls into `from-ai-agent,s,1`

## Current validated state

- Host Asterisk installed and running
- ARI enabled on `127.0.0.1:8088`
- `ai_engine` healthy and `ari_connected: true`
- `local_ai_server` healthy
- Admin UI reachable on `http://127.0.0.1:3003`
- Active tracked config defaults:
  - `active_pipeline: local_hybrid`
  - `downstream_mode: file`
- Host dialplan context:
  - `from-ai-agent`
  - `Set(AI_PROVIDER=local_hybrid)`
  - `Set(AI_CONTEXT=default)`
  - `Stasis(asterisk-ai-voice-agent)`

## Local model set used on this host

CPU-friendly local models downloaded with `make model-setup`:

- STT: `vosk-model-small-en-us-0.15`
- LLM: `qwen2.5-1.5b-instruct-q4_k_m.gguf`
- TTS: `en_US-lessac-medium.onnx`

Relevant `.env` values on this host point to:

- `LOCAL_STT_MODEL_PATH=/app/models/stt/vosk-model-small-en-us-0.15`
- `LOCAL_LLM_MODEL_PATH=/app/models/llm/qwen2.5-1.5b-instruct-q4_k_m.gguf`
- `LOCAL_TTS_MODEL_PATH=/app/models/tts/en_US-lessac-medium.onnx`

## Start / rebuild

```bash
make model-setup
sudo docker compose -p asterisk-ai-voice-agent \
  -f docker-compose.yml \
  -f docker-compose.local-core.yml \
  up -d --build --force-recreate local_ai_server ai_engine admin_ui
```

## Health verification

### Engine health

```bash
curl -fsS http://127.0.0.1:15000/health
```

Expected signals:
- `"status": "healthy"`
- `"ari_connected": true`
- local provider ready
- AudioSocket listening on `127.0.0.1:8090`

### Local server health

```bash
sudo docker compose -p asterisk-ai-voice-agent \
  -f docker-compose.yml \
  -f docker-compose.local-core.yml ps
```

Expected:
- `local_ai_server` is `Up ... (healthy)`

### Local model load evidence

```bash
sudo docker logs --tail=120 local_ai_server 2>&1 | grep -E 'Vosk|Piper|loaded|model'
```

Expected:
- Vosk loaded from `/app/models/stt/vosk-model-small-en-us-0.15`
- Piper loaded from `/app/models/tts/en_US-lessac-medium.onnx`

## Admin UI credential rotation

Default credentials are `admin / admin` only until first rotation.

Rotate via API:

```bash
TOKEN=$(curl -sS -X POST http://127.0.0.1:3003/api/auth/login \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin&password=admin' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

curl -sS -X POST http://127.0.0.1:3003/api/auth/change-password \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \\
  -d '{"old_password":"admin","new_password":"REPLACE_WITH_STRONG_PASSWORD"}'
```

Verify old password fails and new password succeeds.

## Host dialplan check

```bash
sudo asterisk -rx 'dialplan show from-ai-agent'
```

Expected priorities:

```ini
[from-ai-agent]
exten => s,1,NoOp(Asterisk AI Voice Agent)
 same => n,Set(AI_PROVIDER=local_hybrid)
 same => n,Set(AI_CONTEXT=default)
 same => n,Stasis(asterisk-ai-voice-agent)
 same => n,Hangup()
```

## Synthetic test path (validated)

This host does support a **synthetic Asterisk originate** that proves the dialplan reaches Stasis:

```bash
sudo asterisk -rx "channel originate Local/s@from-ai-agent application Wait 8"
```

Observed result on this host:
- `ai_engine` receives `StasisStart`
- the Local channel enters the hybrid ARI path
- the engine then hangs up because there is **no real caller leg** attached to that synthetic Local channel

Relevant log pattern:

```text
HYBRID ARI - Local channel entered Stasis
HYBRID ARI - Processing Local channel StasisStart
HYBRID ARI - No caller found for Local channel
```

This is still useful as a smoke test for:
- ARI connectivity
- dialplan routing into Stasis
- engine event handling

## Real conversational test path (not yet possible on this host)

A real conversation requires an actual caller leg.

### Verified blocker on this host

```bash
sudo asterisk -rx 'pjsip show endpoints'
```

Observed result during validation:

```text
No objects found.
```

That means there are currently **no registered SIP/PJSIP endpoints** on this machine, so a full live conversation test cannot be completed yet.

## How to complete a real call test

1. Register a SIP phone or softphone to this Asterisk host.
2. Route an inbound DID or internal extension to `from-ai-agent,s,1`.
3. Call that route from the registered endpoint.
4. Watch logs:

```bash
sudo docker logs -f ai_engine
```

5. After the call, inspect health / history as needed.

## Recommended practical test options

### Option A: FreePBX custom destination

If using FreePBX, create a custom destination:

- Target: `from-ai-agent,s,1`
- Route an inbound route or extension to that destination

### Option B: Generic Asterisk internal test extension

If using plain Asterisk, add an internal extension in your normal dial context that forwards to:

```ini
Goto(from-ai-agent,s,1)
```

Then dial that internal extension from a registered phone.

## Troubleshooting notes

### `agent check --local` unavailable

Some installs may not have the `agent` CLI on `PATH`. In that case, use:
- `curl http://127.0.0.1:15000/health`
- Docker `ps`
- container logs
- `asterisk -rx` dialplan / ARI checks

### Local server healthy but no real calls

If synthetic originate works but conversations do not, check:
- registered endpoints exist
- inbound route actually targets `from-ai-agent,s,1`
- Asterisk modules for ARI/AudioSocket are loaded
- `ai_engine` still reports `ari_connected: true`

## Files touched for this host-local setup

Tracked repo config:
- `config/ai-agent.yaml`

Host/local-only config:
- `.env`
- `/etc/asterisk/ari.conf`
- `/etc/asterisk/http.conf`
- `/etc/asterisk/extensions_custom.conf`

## Summary

This machine is in a **working local-mode platform state**:
- local models load
- local AI services are healthy
- Asterisk reaches the Stasis app
- the remaining step for a full conversation is simply attaching a real SIP/PJSIP endpoint and routing a call into `from-ai-agent`
