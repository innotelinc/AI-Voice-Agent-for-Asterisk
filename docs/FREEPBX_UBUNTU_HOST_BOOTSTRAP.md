# FreePBX Ubuntu Host Bootstrap

Use this path when you already have **Asterisk on the Ubuntu host** and you want a repeatable **manual FreePBX 17 bootstrap** that matches the validated Ubuntu 24.04 host pattern used for AAVA testing.

This installer is for the **Ubuntu-specific manual framework path**, not Sangoma's Debian all-in-one installer.

## What it installs/configures

`scripts/install-freepbx-ubuntu-host.sh` will:

1. install/verify host prerequisites:
   - Apache
   - MariaDB
   - system `nodejs` / `npm`
   - PHP **8.2** and required extensions
2. switch CLI/Apache PHP to **8.2**
3. run Apache workers as **`asterisk:asterisk`**
4. ensure the operator user is in the **`asterisk`** group
5. create the `asterisk` and `asteriskcdrdb` MariaDB databases
6. download the current **FreePBX 17** framework tarball from `mirror.freepbx.org`
7. run the manual FreePBX framework installer non-interactively
8. normalize ownership/readability for:
   - `/var/www/html/admin`
   - `/etc/freepbx.conf`
   - `/etc/amportal.conf`
9. install the validated module set:
   - `framework`
   - `core`
   - `sipsettings`
   - `voicemail`
   - `dashboard`
   - `calendar`
   - `contactmanager`
   - `certman`
   - `pm2`
   - `userman`
   - `customappsreg`
   - `miscapps`
   - `filestore`
   - `backup`
10. align Asterisk control socket ownership/perms with the `asterisk` group model
11. provide a non-destructive `--check` mode

## Scope and caveats

This script is designed for the host model validated in:

- [FreePBX Ubuntu Host Validation](freepbx/FreePBX-Ubuntu-Host-Validation.md)
- [FreePBX Integration Guide](FreePBX-Integration-Guide.md)

Important caveats:

- it is validated for **Ubuntu** only
- it assumes **Asterisk is already installed on the host**
- it does **not** automate the first web-admin user creation wizard inside `/admin`
- it does **not** create your `from-ai-agent` FreePBX Custom Destination for you
- it does **not** replace the repo’s broader host-Asterisk/AAVA bootstrap flow

Use this installer when your goal is specifically: **"Get FreePBX onto this Ubuntu Asterisk host in the working manual-install shape."**

## Quick start

```bash
git clone https://github.com/innotelinc/AI-Voice-Agent-for-Asterisk.git
cd AI-Voice-Agent-for-Asterisk
sudo scripts/install-freepbx-ubuntu-host.sh --operator-user "$USER"
```

## Verification mode

```bash
sudo scripts/install-freepbx-ubuntu-host.sh --check
```

This prints:

- Ubuntu release
- active PHP alternative
- Apache runtime user/group
- whether `fwconsole` is installed
- key FreePBX files and config lines
- key module statuses
- HTTP response headers from `http://127.0.0.1/admin/`
- Asterisk socket ownership and CLI reachability

## MariaDB root password handling

If MariaDB root uses socket auth, you usually do **not** need a password argument.

If your host uses a real root password:

```bash
sudo scripts/install-freepbx-ubuntu-host.sh \
  --operator-user "$USER" \
  --db-root-pass 'your-root-password'
```

## PHP version behavior

The script targets **PHP 8.2** because that matched the validated Ubuntu FreePBX 17 host setup.

If `php8.2` packages are not available from current apt sources, the script adds the **Ondřej Surý PHP PPA** before installing packages.

## FreePBX framework source

By default the script downloads:

```text
https://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz
```

Override if needed:

```bash
sudo scripts/install-freepbx-ubuntu-host.sh \
  --operator-user "$USER" \
  --freepbx-url https://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz
```

## After the script finishes

1. Open:
   ```text
   http://YOUR-HOST/admin
   ```
2. Complete the first-run FreePBX admin account setup if prompted
3. In FreePBX create:
   - **Custom Destination** → `from-ai-agent,s,1`
   - **Misc Application** (or other route) → that Custom Destination
4. Verify compiled routing from the Asterisk CLI:
   ```bash
   asterisk -rx 'dialplan show from-ai-agent'
   asterisk -rx 'dialplan show 7000@app-miscapps'
   ```

## Relationship to the other installer

If you want the **plain host Asterisk + local-core AAVA stack** first, use:

- [Barebones Server Install](BAREBONES_SERVER_INSTALL.md)
- `scripts/install-barebones-server.sh`

If you specifically want the **Ubuntu manual FreePBX layer** on top of a host Asterisk box, use this script.

## Real-world steady state this aims for

The validated Ubuntu host ended up with:

- `php` alternative pointing to **`/usr/bin/php8.2`**
- Apache envvars set to:
  - `APACHE_RUN_USER=asterisk`
  - `APACHE_RUN_GROUP=asterisk`
- FreePBX config readable as:
  - `/etc/freepbx.conf` → `asterisk:asterisk`, mode `640`
  - `/etc/amportal.conf` → `asterisk:asterisk`, mode `640`
- `fwconsole` installed and working
- FreePBX module set including `customappsreg` and `miscapps`

## Notes

- This script makes **host-local system changes**; do not confuse them with repo-tracked config.
- It is meant to be rerunnable for verification and repair, but it is still a real system bootstrap script.
- For end-to-end AI-call proof after FreePBX is up, follow the validation flow in [freepbx/FreePBX-Ubuntu-Host-Validation.md](freepbx/FreePBX-Ubuntu-Host-Validation.md).
