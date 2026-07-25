# Syncing `Learning Turkish` with Google Drive — Docs as Markdown

## Why

`~/Documents/Obsidian Vault - Learning Turkish` is a **standalone Obsidian vault** backed
by Google Drive, with a format translation in the middle: PDFs move
byte-for-byte, while **Google Docs appear locally as `.md`** so Obsidian
can read and link them, and **new local notes become native Google
Docs** on Drive.

It is deliberately *not* a folder inside `~/Documents/Obsidian Vault`.
That vault belongs to `../icloud-obsidian-sync/`, and nesting this one
inside it would put two sync jobs on the same files. Separate vault,
separate cloud, no interaction: the two tools share no paths, no lock,
and no state.

This works with stock `rclone` — no custom Drive API client. Google
added Markdown import/export to Docs in July 2024, and rclone's Drive
backend lists `md` / `text/markdown` in its export format table, so:

- `--drive-export-formats md` makes a Doc named `Lesson 1` list and
  download as `Lesson 1.md`
- `--drive-import-formats md` makes an uploaded `Lesson 1.md` convert
  into a native Doc on the way up

rclone requires the round-trip extension to match — export `md` plus
import `md` is an allowed pair in its conversion table.

## How it works

Not `bisync`. Docs are Drive-authoritative while assets move both ways,
so this is **four passes** in one script. `rclone copy` never deletes,
which makes it far safer than bisync and removes the `--resync`
baseline ritual entirely.

```
Pass 1  PULL     gdrive: -> local     --drive-export-formats md,xlsx,pptx
                 Doc -> .md, Sheet -> .xlsx, Slides -> .pptx, PDFs as-is.
                 Only pulls when the Drive mtime is newer.

Pass 2  PUSH     local -> gdrive:     --filter-from turkish-push-assets.txt
        assets   PDFs/images/audio only. Newer mtime wins.

Pass 3  PUSH     local -> gdrive:     --drive-import-formats md
        new .md  --ignore-existing    --drive-export-formats md
                 Uploads ONLY markdown with no remote counterpart and
                 converts it to a native Google Doc.

Pass 4  chmod a-w on every Doc-derived local file.
```

**`--ignore-existing` in pass 3 is the whole trick.** A Doc named
`Lesson 1` already lists remotely as `Lesson 1.md`, so rclone skips it —
local edits to Doc-derived notes are never pushed, with no manifest or
state file anywhere. Only genuinely new notes go up. Once uploaded and
converted, a note *is* a Doc, so it becomes Drive-authoritative from the
next run onward. The rule is self-maintaining.

Two supporting details:

- Native Google files report `Size == -1` and no checksum. rclone treats
  an unknown size as "not different" and falls back to modtime, which it
  sets explicitly on both upload and download — so files settle after
  one pass instead of re-transferring forever.
- Pass 4 finds Doc-derived files by exactly that `Size == -1` marker
  (`rclone lsjson | jq`) and `chmod a-w`s them, making the
  Drive-authoritative rule visible in Obsidian. rclone can still replace
  them: it downloads to a `.partial` temp file and renames over the
  target, which needs directory write permission, not file permission.

## Tradeoffs (read before relying on this)

- **Deletions never propagate, in either direction.** Delete a Doc on
  Drive and a stale `.md` stays behind locally; delete a note locally
  and the next pull brings it back. This is deliberate — deletion
  propagation is where sync tools lose data. Cleanup is manual, see
  "Finding orphans" below.
- **Doc-derived notes are effectively read-only.** Editing one in
  Obsidian is silently lost the next time that Doc changes on Drive.
  Pass 4's `chmod a-w` surfaces this in the editor rather than letting
  you find out later. Edit those in Google Docs.
- **Renaming a local `.md` creates a second Doc.** rclone sees a new
  filename with no remote counterpart and uploads it; the Doc under the
  old name stays. Rename on the Drive side instead.
- **Markdown export is lossy.** Images inside a Doc come through as
  reference-style placeholders with no image data. Comments,
  suggestions, fonts, colors, and layout are dropped. What survives is
  headings, bold/italic, lists, links, tables, and code blocks.
- **New notes lose Obsidian syntax on conversion.** YAML frontmatter and
  `[[wikilinks]]` are not markdown Google understands — they arrive in
  the Doc as literal text.
- **Sheets and Slides are one-way.** They arrive as `.xlsx` / `.pptx`,
  which Obsidian can't read, and pass 2's filter deliberately refuses to
  push them back — an uploaded `.xlsx` would shadow the native Sheet it
  came from.
- **Not real-time.** systemd timer every 5 min (three API round-trips
  per run, so less aggressive than the iCloud sync's 2 min).
- **Use your own OAuth client_id.** rclone's built-in default client is
  shared by every rclone user on earth and is heavily throttled.

## Relationship to the iCloud vault sync

None, by design. `../icloud-obsidian-sync/` bisyncs
`~/Documents/Obsidian Vault` with iCloud; this syncs
`~/Documents/Obsidian Vault - Learning Turkish` with Google Drive. Disjoint paths,
separate locks, separate logs, separate timers. Neither can corrupt the
other, and either can be removed without touching the other.

The practical consequence: **Turkish notes do not reach iCloud**, so
they won't appear in the Obsidian vault on your Mac or iPhone. Mobile
access is through Google Drive instead — which for Docs is the better
surface anyway, since you get real Docs editing rather than a markdown
rendering. In Obsidian, switch between the two with the vault switcher
(the icon at the bottom of the left ribbon).

`.obsidian/` lives *inside* this vault, since it's standalone. Both push
filters exclude it — Obsidian's local config, plugin state, and
workspace layout have no business on Drive, and a plugin's bundled
`README.md` would otherwise get uploaded as a Google Doc.

## Prerequisites

- `rclone` (v1.66+ for the Google Docs handling; v1.74.4 here), plus
  `jq`, `flock`, `notify-send` — all present on Ubuntu 24.04 desktop
- A Google account with the `Learning Turkish` folder on Drive
- A browser on this machine — the OAuth consent flow in step 2 redirects
  to a local webserver, so it must run where rclone runs

## Step 1 — Create your own OAuth client

Reference: <https://rclone.org/drive/#making-your-own-client-id>.

You *can* skip this whole step and use rclone's built-in client (just
omit `client_id`/`client_secret` in step 2). It works, but that client
is shared by every rclone user on earth and is throttled — on a 5-minute
timer you'll see intermittent 403s. Five minutes here removes the
problem permanently.

**Navigate by URL, not by menu.** Google renamed and reorganised this
area in 2024-25 (it used to be "APIs & Services → OAuth consent
screen"), so written guides and the console rarely agree. Every link
below goes straight where it needs to. Make sure the project picker at
the top of the page says your new project before each step — that is the
single most common way to end up on a page that looks wrong.

**1. Create the project** — <https://console.cloud.google.com/projectcreate>
Name it something like `rclone-personal`, Create, then **select it** in
the project picker at the top of the page.

**2. Enable the Drive API** — <https://console.cloud.google.com/apis/library/drive.googleapis.com>
Click **Enable**.

**3. Consent screen** — <https://console.cloud.google.com/auth/overview>

> On a fresh project this page shows a single **Get started** button and
> nothing else — no "Branding", no "Audience", no "Clients". That is
> expected, and it is why the section can seem to be missing. Those
> three appear in the left nav only *after* you finish this wizard.
> (In the left nav this whole area is **APIs & Services → Google Auth
> Platform**.)

Click **Get started** and fill in the four steps:

| Wizard step | What to enter |
|---|---|
| App Information | App name (anything, e.g. `rclone-personal`) + your Gmail as **User support email** |
| Audience | **External** |
| Contact Information | your Gmail again |
| Finish | tick the Google API Services User Data Policy → **Create** |

**4. Add yourself as a test user** — <https://console.cloud.google.com/auth/audience>
Under **Test users** → **Add users** → your Gmail address → Save.

**5. Create the client** — <https://console.cloud.google.com/auth/clients>
**Create client** → Application type **Desktop app** → **Create**.
Copy the **Client ID** and **Client secret** from the dialog (you can
re-open them from this page later).

**6. Publish the app** — <https://console.cloud.google.com/auth/audience>
Under **Publishing status**, click **Publish app** and confirm
(Testing → In production).

Step 6 is not optional for a scheduled sync. While the app sits in
**Testing**, Google expires the refresh token **every 7 days** and the
timer starts failing weekly. Published-but-unverified is fine for
personal use: during consent you get a "Google hasn't verified this
app" interstitial once, where you click *Advanced → Go to (app)*.

Sanity check before moving on: <https://console.cloud.google.com/auth/audience>
should show **Publishing status: In production**, and
<https://console.cloud.google.com/auth/clients> should list one Desktop
client.

## Step 2 — Configure the remote

One shot, no menu navigation. Opens a browser for consent, so run it
yourself rather than from a script:

```bash
rclone config create gdrive drive \
    client_id=YOUR_ID client_secret=YOUR_SECRET scope=drive
```

rclone starts a local webserver on `127.0.0.1:53682` and opens your
browser; approve, and the token is written to
`~/.config/rclone/rclone.conf`.

`scope=drive` (full access) is required. `drive.file` — the tempting
narrow option — only grants access to files the app itself created, so
it can't see the Docs and PDFs already in your folder. Step 3 is what
actually constrains the blast radius.

If that misbehaves, the interactive equivalent is `rclone config`:
`n` → name `gdrive` → storage `drive` → paste id/secret → scope `1` →
service account blank → advanced config `n` → auto config `y` →
shared drive `n` → `y` → `q`.

Verify: `rclone listremotes` shows `gdrive:`.

## Step 3 — Pin the remote to the folder

Open the `Learning Turkish` folder on Drive and copy the ID out of the
URL: `drive.google.com/drive/folders/<ID>`. Then:

```bash
rclone config update gdrive root_folder_id <ID>
```

This **limits rclone to that one folder** — if anything ever misfires,
the blast radius is `Learning Turkish` and nothing else in your Drive.
From here on the remote path is just `gdrive:`.

Verify it points at the right place:

```bash
rclone lsf gdrive:
```

## Step 4 — Check that Markdown import is available

The one thing worth confirming before installing. rclone gates
conversion on the import formats Drive *advertises*:

```bash
rclone backend importformats gdrive: | grep -i markdown
rclone backend exportformats gdrive: | grep -i markdown
```

Both should mention `text/markdown`. If **import** doesn't list it, see
"Fallback" at the bottom — pulls still work either way, only the
new-note upload path changes.

## Step 5 — Dry run

Before installing anything, confirm the conversions look right:

```bash
rclone copy gdrive: "$HOME/Documents/Obsidian Vault - Learning Turkish" \
  --drive-export-formats md,xlsx,pptx --dry-run -v
```

The log should show your Docs as `<name>.md` and PDFs under their own
names.

## Step 6 — Install

```bash
./install.sh
```

First run, and watch it:

```bash
systemctl --user start gdrive-turkish-sync.service
tail -f ~/.local/share/gdrive-turkish-sync/sync.log
```

## Step 7 — Open it as a vault in Obsidian

Once the first pull has landed some files: in Obsidian, use the vault
switcher (bottom of the left ribbon) → **Open folder as vault** →
`~/Documents/Obsidian Vault - Learning Turkish`.

Obsidian creates `.obsidian/` inside it on first open. Both push filters
exclude that directory, so it stays local.

## Verification

Work through these once; each isolates one path through the script.

- **Doc → md.** Create a Doc in the Drive folder with a heading, bold
  text and a bullet list. Within 5 min a `.md` with real markdown syntax
  appears locally, `ls -l` shows it as `-r--r--r--`, and Obsidian
  renders it.
- **Doc edit → md update.** Edit that Doc; the local `.md` changes on
  the next run.
- **New note → Doc.** Create `Test Note.md` in the vault. Next run, a
  Doc named `Test Note` appears on Drive — check it opens in Docs rather
  than downloading as a file. Then confirm the run *after* that doesn't
  re-upload or duplicate it.
- **Local edits are correctly ignored.** Edit a Doc-derived `.md` (you
  have to override the read-only bit) and confirm the log shows no
  upload for it on the next run.
- **PDFs both ways.** Drop one on Drive → it appears locally. Drop one
  locally → it appears on Drive; `rclone check` that single file to
  confirm it's byte-identical.
- **Sheets/Slides.** A Sheet in the folder arrives as `.xlsx` and is
  never pushed back.
- **`.obsidian/` stays local.** After opening the vault in Obsidian and
  letting one sync run, confirm no `.obsidian` folder appeared on Drive.
- **iCloud untouched.** `rclone lsf iclouddrive:"Documents/Obsidian Vault"`
  should show no `Learning Turkish` — the two setups are independent.

## Ongoing maintenance

Watch `~/.local/share/gdrive-turkish-sync/sync.log`, or wait for the
failure notification. The log names the pass that failed.

### Finding orphans

Since nothing is ever deleted automatically, list files that exist on
one side only:

```bash
VAULT="$HOME/Documents/Obsidian Vault - Learning Turkish"

# on Drive but not local
rclone check gdrive: "$VAULT" --drive-export-formats md,xlsx,pptx \
  --one-way --size-only --missing-on-dst /dev/stdout

# local but not on Drive (--exclude keeps Obsidian's own config out of
# the report; it is intentionally never uploaded)
rclone check "$VAULT" gdrive: --drive-export-formats md,xlsx,pptx \
  --exclude '.obsidian/**' --exclude '.trash/**' \
  --one-way --size-only --missing-on-dst /dev/stdout
```

`--size-only` is needed because Docs have no checksum. Delete whatever
you actually want gone, by hand, on both sides.

### Token refresh

Unlike the iCloud sync's ~30-day trust token, this needs no routine
re-auth: a Google refresh token on a **published** OAuth app doesn't
expire. It does get revoked if you change your Google password, revoke
access under <https://myaccount.google.com/permissions>, or leave the
consent screen in **Testing** status (7-day expiry — see step 1).

If auth starts failing:

```bash
rclone config reconnect gdrive:
```

If it fails again within a week, the consent screen is still in Testing.
Publish it.

### Rate limits

If the log shows 403 `userRateLimitExceeded`, widen `OnUnitActiveSec` in
`gdrive-turkish-sync.timer` and
`systemctl --user daemon-reload && systemctl --user restart gdrive-turkish-sync.timer`.

## Fallback: if Drive doesn't advertise `text/markdown` for import

Pulls (Doc → `.md`) are unaffected — only pass 3 needs changing. Install
`pandoc`, then have pass 3 convert each new note to a temp `.docx` and
upload that with `--drive-export-formats docx --drive-import-formats docx`
(that pass only; pass 1 still pulls as `md`). Local files stay `.md`
either way — the `.docx` is a transient in `/tmp`. The conversion is
slightly *less* lossy than markdown import, at the cost of a pandoc
dependency and a more complicated pass 3.
