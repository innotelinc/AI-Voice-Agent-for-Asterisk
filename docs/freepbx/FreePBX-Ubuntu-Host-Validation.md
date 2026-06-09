# FreePBX on an Existing Ubuntu Asterisk Host: Validated Notes

This note captures a validated pattern for running **FreePBX 17** on an **Ubuntu 24.04 host** that already has **Asterisk 20** installed locally, while the AI engine runs separately.

> Status: validated on a live host with a real PJSIP endpoint registration and a successful call into `Stasis(asterisk-ai-voice-agent)`.

## Scope

Use this when:

- Asterisk is installed on the Linux host
- FreePBX is desired for PBX administration/routing
- The host is **Ubuntu**, not Sangoma's officially documented Debian target
- The AI application is reached through a custom dialplan context such as `from-ai-agent`

## Important support note

Sangoma's current installer guidance targets **vanilla Debian 12**. On Ubuntu, expect to use a **manual FreePBX framework install** layered on top of the existing distro Asterisk rather than the official all-in-one installer.

## Validated host prerequisites

The following host pieces were required:

- Apache
- MariaDB
- PHP **8.2** for both CLI and Apache
- system `node` / `npm` available on PATH
- existing working Asterisk host runtime

## Apache/FreePBX ownership model on Ubuntu

A frequent Ubuntu failure mode is a working framework install with a broken GUI bootstrap, often showing errors equivalent to **`Class "FreePBX" not found`** from `/etc/freepbx.conf`.

A validated steady state was:

- FreePBX config owned/readable under the `asterisk` model
- Apache worker processes running as **`asterisk`**
- `fwconsole` available and functioning

Quick checks:

```bash
ps -eo user,group,comm | grep '[a]pache2'
command -v fwconsole
curl -I http://127.0.0.1/admin/
```

## Asterisk runtime socket access

If operator commands succeed with `sudo` but fail as the normal shell user, verify **group membership** and **socket ownership** before assuming Asterisk is down.

Validated pattern:

- operator user is in group `asterisk`
- `/run/asterisk/asterisk.ctl` owned by `asterisk:asterisk`
- socket mode allows group read/write

Example checks:

```bash
id
stat -c '%A %a %U %G %n' /run/asterisk /run/asterisk/asterisk.ctl /var/run/asterisk/asterisk.ctl
asterisk -rx 'core show version'
```

## FreePBX routing pattern

Keep the AI entry logic in custom Asterisk dialplan, then route to it from FreePBX-managed objects.

Validated target context:

```asterisk
[from-ai-agent]
exten => s,1,NoOp(Asterisk AI Voice Agent)
 same => n,Stasis(asterisk-ai-voice-agent)
 same => n,Hangup()
```

Recommended FreePBX objects:

1. **Custom Destination** → `from-ai-agent,s,1`
2. **Misc Application** (or other GUI-managed route) → Custom Destination

Validated compiled route shape:

```text
7000@app-miscapps -> Goto(customdests,dest-1,1)
dest-1@customdests -> Goto(from-ai-agent,s,1)
from-ai-agent,s,1 -> Stasis(asterisk-ai-voice-agent)
```

Verify from the Asterisk CLI, not just the GUI:

```bash
asterisk -rx 'dialplan show 7000@app-miscapps'
asterisk -rx 'dialplan show dest-1@customdests'
asterisk -rx 'dialplan show from-ai-agent'
```

## Real-call validation sequence

A synthetic Local-channel originate is useful for smoke testing, but it is **not** the same as a real phone call.

Validated PBX-side proof sequence:

1. Confirm endpoint exists
2. Confirm endpoint has a live contact
3. Call the FreePBX-facing route (for example `7000`)
4. Confirm the caller leg and AI media leg are both active simultaneously
5. Confirm AI-engine logs show greeting generation/playback

Useful checks:

```bash
asterisk -rx 'pjsip show endpoint 1001'
asterisk -rx 'pjsip show contacts'
asterisk -rx 'core show channels verbose'
asterisk -rx 'bridge show all'
```

Expected evidence during a live call:

- `PJSIP/1001-...` channel in `from-ai-agent`
- `AudioSocket/...` channel in `Stasis`
- a bridge containing both channels
- AI engine logs showing:
  - caller entered Stasis
  - caller answered
  - bridge created
  - AudioSocket channel originated
  - greeting TTS generated and played

## Headless softphone verification with baresip

If you need a temporary local softphone on Ubuntu, `baresip` works, but the packaged build can be finicky.

Validated notes:

- use the distro-generated config layout rather than a hand-minimized config
- confirm `module_path` is present in the generated config
- a working account example for a local test endpoint looked like:

```text
<sip:1001@127.0.0.1;transport=udp>;auth_pass=YOUR_SECRET;regint=60
```

A useful live check is whether Asterisk shows the contact as `Avail`.

After testing, disconnect the temporary softphone so the user's real softphone can register without collision.

## Commit discipline

Most of the FreePBX/Asterisk install and validation work lives outside the repo:

- `/etc/asterisk/*`
- `/etc/apache2/*`
- `/etc/freepbx.conf`
- `/etc/amportal.conf`
- MariaDB state
- FreePBX module/runtime state

Do **not** commit those host-local changes. Commit only durable repo-side artifacts such as:

- docs/runbooks
- tracked configuration defaults
- stable guidance that helps future operators
