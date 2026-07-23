# Syncing an Obsidian Vault with iCloud Drive from Ubuntu 24.04

## Why

Apple ships no official iCloud Drive client for Linux. The Mac keeps
`~/Documents/Obsidian Vault` current automatically via macOS's built-in
iCloud Drive "Desktop & Documents" sync — nothing on the Mac needs to
change. This setup makes Ubuntu independently push/pull the same vault
to/from iCloud using `rclone`'s `iclouddrive` backend, so both machines
end up in sync through iCloud, touching only the Linux side.

## Tradeoffs (read before relying on this)

- **Experimental backend.** `rclone`'s `iclouddrive` backend authenticates
  like the iCloud web client. As of 2026 there are open upstream bugs
  around 2FA code delivery (github.com/rclone/rclone/issues/9359) — the
  2FA prompt can fail to send a code at all. If setup hangs at 2FA,
  cancel and retry, try the SMS/trusted-phone-number path instead of
  device push, or grab the latest rclone release/beta.
- **Trust token expires every ~30 days.** Login is not "set and forget."
  When it expires, scheduled syncs start failing until you re-run
  `rclone config reconnect iclouddrive:`. The wrapper script below fires
  a desktop notification on sync failure so this doesn't go unnoticed —
  but there's no way around the periodic manual re-auth.
- **Not real-time.** This uses a polling systemd timer (every 2 min),
  not a push/webhook. A change on either side can take up to one
  interval to show up on the other. Real-time (inotify-triggered) sync
  was considered and rejected in favor of simplicity and fewer calls
  against Apple's undocumented rate limits.
- **Rate-limit risk is unquantified.** Apple publishes no rate limits
  for this unofficial API surface. 2 minutes was chosen empirically —
  each no-op sync takes ~3-5s, so this leaves plenty of idle headroom —
  but if `sync.log` starts showing auth/throttling failures, the fix is
  to widen `OnUnitActiveSec` in the timer (back up to 5 min or more).
  There's no hard evidence 2 min is "safe," just no observed problems.
- **Shared `.obsidian/` settings.** Only `workspace.json` /
  `workspace-mobile.json` (per-device window/pane layout) are excluded
  from sync. Other `.obsidian/*.json` (theme, enabled plugins, etc.) DO
  sync both ways — editing Obsidian settings on one machine can
  overwrite the other's on the next sync. This mirrors what iCloud/any
  full-vault sync would do; it's not unique to this setup.
- **Requires an active or lingering user session.** Handled below via
  `loginctl enable-linger`, but worth knowing: without it, systemd
  --user timers only run while you're logged in.
- **bisync is officially "beta" in rclone**, though widely used for
  exactly this purpose (cloud-synced note vaults). First run must
  always be `--resync` (see step 5) — never skip it, it establishes the
  baseline bisync uses to detect changes/deletions safely.

## Prerequisites

- Ubuntu 24.04, vault expected at `~/Documents/Obsidian Vault`
- Your Apple ID email + password (not an app-specific password) and
  access to 2FA (trusted device or phone number)
- `notify-send` and `flock` (both ship by default on Ubuntu desktop)

## Files in this directory

Alongside this README are the actual deployed files (not just the
copies inlined below), plus `install.sh` which copies them into place
and enables the timer in one shot:

```bash
./install.sh
```

Run `install.sh` only after completing steps 1-3 and 5 below (rclone
installed, remote configured, vault path confirmed, baseline resync
done) — it deploys the script/timer but doesn't do the interactive
Apple ID login or the first resync for you.

## Step 1 — Install rclone (latest, not the apt package)

Ubuntu 24.04's `apt` rclone is too old to include the `iclouddrive`
backend. Use the official installer:

```bash
curl https://rclone.org/install.sh | sudo bash
```

Verify:

```bash
rclone version
rclone help backends | grep -i icloud   # should list "iclouddrive"
```

## Step 2 — Configure the iCloud remote

Run interactively (needs your password + 2FA, so do this yourself, not
via automation):

```bash
rclone config
```

- `n` → new remote
- name: `iclouddrive`
- storage type: `iclouddrive`
- Apple ID email, then your regular account password
- complete the 2FA prompt with the 6-digit code
- `y` to confirm, `q` to quit

Verify: `rclone listremotes` should print `iclouddrive:`.

## Step 3 — Find the exact remote path to the vault

With macOS "Desktop & Documents" sync on, `~/Documents` is mirrored at
iCloud Drive's root:

```bash
rclone lsd iclouddrive:
rclone lsd iclouddrive:Documents
```

Confirm `Obsidian Vault` shows up under `Documents/`. This guide
assumes the path `iclouddrive:Documents/Obsidian Vault` — adjust
everything below if your discovery shows a different path.

## Step 4 — Ignore filters

`~/.config/rclone/obsidian-filters.txt`:

```
- .DS_Store
- .obsidian/workspace.json
- .obsidian/workspace-mobile.json
```

## Step 5 — Baseline resync (run once)

```bash
mkdir -p ~/Documents/"Obsidian Vault"
rclone bisync "$HOME/Documents/Obsidian Vault" "iclouddrive:Documents/Obsidian Vault" \
  --filters-file "$HOME/.config/rclone/obsidian-filters.txt" \
  --resync -v
```

`--resync` merges rather than deletes: if local is empty and remote has
files (fresh machine), everything is pulled down safely. Confirm the
log ends with `Bisync successful`.

## Step 6 — Sync wrapper script

`~/.local/bin/obsidian-icloud-sync.sh` (make executable with
`chmod +x`):

```bash
#!/usr/bin/env bash
set -euo pipefail

VAULT_LOCAL="$HOME/Documents/Obsidian Vault"
VAULT_REMOTE="iclouddrive:Documents/Obsidian Vault"
FILTERS="$HOME/.config/rclone/obsidian-filters.txt"
LOG_DIR="$HOME/.local/share/obsidian-icloud-sync"
LOG_FILE="$LOG_DIR/sync.log"
LOCK_FILE="$LOG_DIR/sync.lock"

mkdir -p "$LOG_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date -Iseconds) Skipped: previous sync still running" >>"$LOG_FILE"
    exit 0
fi

{
    echo "=== $(date -Iseconds) starting sync ==="
    if rclone bisync "$VAULT_LOCAL" "$VAULT_REMOTE" --filters-file "$FILTERS" --conflict-resolve newer -v; then
        echo "=== $(date -Iseconds) sync OK ==="
    else
        status=$?
        echo "=== $(date -Iseconds) sync FAILED (exit $status) ==="
        DISPLAY="${DISPLAY:-:0}" notify-send -u critical "Obsidian iCloud sync failed" \
            "Check $LOG_FILE — trust token may have expired. Run: rclone config reconnect iclouddrive:" || true
        exit "$status"
    fi
} >>"$LOG_FILE" 2>&1
```

Test it manually before automating: `~/.local/bin/obsidian-icloud-sync.sh`
then check `~/.local/share/obsidian-icloud-sync/sync.log`.

## Step 7 — systemd user timer

`~/.config/systemd/user/obsidian-icloud-sync.service`:

```ini
[Unit]
Description=Sync Obsidian Vault with iCloud Drive via rclone bisync

[Service]
Type=oneshot
ExecStart=%h/.local/bin/obsidian-icloud-sync.sh
```

`~/.config/systemd/user/obsidian-icloud-sync.timer`:

```ini
[Unit]
Description=Run Obsidian iCloud sync periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
```

(Started at 5 min intervals, later tightened to 2 min after confirming
each no-op run only takes a few seconds — see Tradeoffs above on how
to widen this back up if failures appear.)

Enable:

```bash
systemctl --user daemon-reload
systemctl --user enable --now obsidian-icloud-sync.timer
systemctl --user list-timers obsidian-icloud-sync.timer
```

## Step 8 — Keep it running while logged out

systemd `--user` units stop when your session ends unless lingering is
enabled:

```bash
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" -p Linger   # should print Linger=yes
```

## Verification

```bash
# trigger a sync on demand instead of waiting for the timer
systemctl --user start obsidian-icloud-sync.service

# tail the log
tail -30 ~/.local/share/obsidian-icloud-sync/sync.log

# spot-check a file directly against the remote
rclone cat "iclouddrive:Documents/Obsidian Vault/<some file>.md"
```

Also test both directions: create a note on Ubuntu and confirm it
appears in iCloud Drive on the Mac (Finder or icloud.com) after one
interval; then create/edit a note on the Mac and confirm it lands in
`~/Documents/Obsidian Vault` on Ubuntu.

## Ongoing maintenance

- Watch `~/.local/share/obsidian-icloud-sync/sync.log` occasionally, or
  just wait for the failure desktop notification.
- Roughly every 30 days: `rclone config reconnect iclouddrive:` to
  refresh the expired trust token.
- If syncs start failing/throttling, widen `OnUnitActiveSec` in the
  timer unit and `systemctl --user daemon-reload && systemctl --user restart obsidian-icloud-sync.timer`.
