# Changelog

A record of failure modes observed in production use of this setup, what
caused them, and how the scripts were hardened to handle them.

The aim is not to scare anyone off. It is to make the failure surface
honest so you can decide what is acceptable for your own data.

## 2026 — Offline is not a failure

### What broke

Same symptom as before, different cause: critical failure notifications
every two minutes. This time I was just on a train.

Every popup said the same thing — "Unclassified failure (exit 2)" —
which told me nothing. The one condition I could have diagnosed in a
second from the notification itself was the one condition the
notification refused to name.

### Diagnosis

Two problems stacked on top of each other.

The first is that nothing checked whether the machine was online before
starting. rclone would go looking for `p71-drivews.icloud.com`, get no
answer from the resolver, and sit there. Each run took **3m20s** to fail
on a timer that fires every 2 minutes, so runs began overlapping and
piling into lock skips.

The second is that the wrapper already had a branch meant for exactly
this — "Vault path or remote not reachable" — and it never fired. It
matched on `directory not found|no such file|not mounted|transport
endpoint`. What rclone actually prints when the network is gone is:

```
dial tcp: lookup p71-drivews.icloud.com on 127.0.0.53:53: i/o timeout
```

Not one of those words appears. So offline fell straight through to the
catch-all `else` and got reported at `critical` urgency — the same
urgency as an expired trust token, which actually does need me. That is
the real damage: once the alarm cries wolf every two minutes on a train,
it stops meaning anything, and the expired-token notification it was
built for gets ignored along with the rest.

### Fix

1. A connectivity probe before the sync starts: resolve `www.icloud.com`
   with a 5s timeout, then a TLS `HEAD` with an 8s timeout. Offline now
   fails in about a second instead of 3m20s. The TLS half is not
   redundant — a captive portal answers DNS for everything, but cannot
   produce a valid certificate for Apple's host.
2. Offline exits 0 and logs a single line. Not a failure exit, because
   it is not a failure, and because a failing unit every 2 minutes
   overnight is its own kind of noise. Repeat offline runs log nothing
   at all.
3. Escalation on a delay instead of immediately: if the outage passes
   30 minutes, one `normal`-urgency "sync paused" notice, once per
   outage, tracked by two small state files next to the log. `critical`
   now means only "this needs your hands."
4. A network branch in the classifier for the case the probe cannot
   catch — the link dropping *during* a multi-minute sync. rclone itself
   says this is safe (`Error is retryable without --resync due to
   --resilient mode`), so it is treated as an outage rather than a
   failure and the next run resumes.
5. `TimeoutStartSec=300` on the service unit. `Type=oneshot` has no
   start timeout by default, which is why a wedged run was allowed to
   run past several timer intervals in the first place.
6. Log rotation at 5 MB, one generation kept. `sync.log` had reached
   1.3 MB with no bound, and an offline night was making it worse.

The same treatment went into `gdrive-turkish-sync/`, which had the
identical gap.

### Why this matters if you copy the approach

Classifying errors by grepping their text is guesswork, and this is what
it costs when the guess is wrong: the branch looked right, read right in
review, and never once fired. If you write a ladder like this, test it
against real captured failure output rather than against what you assume
the tool prints. I found the offline case only because I had the log.

The broader point is about notification urgency. A `critical` alert that
fires for a condition which resolves itself is worse than no alert,
because it trains you to swipe the whole category away — including the
30-day trust token expiry, which is the one thing this setup genuinely
cannot recover from on its own.

## 2026 — Self-healing sync baseline

### What broke

The first version of `obsidian-icloud-sync.sh` ran for a week without
me looking at it. Then one morning the systemd timer started firing
failure notifications every two minutes, and no note was getting
through to either side.

### Diagnosis

The error message was a one-liner. The cause was not obvious. Took me
a while to figure out what was actually happening.

`rclone bisync` stores a baseline of both sides inside `~/.cache`.
That directory is disposable. Something cleared it. Once the baseline
was gone, every run aborted asking for a manual `--resync`, and
`--resync` is not a thing a systemd timer can do for itself.

So the timer was permanently waiting for human hands.

### Fix

Three changes in the wrapper script and the timer unit:

1. Moved the bisync state out of `~/.cache` into a path that does not
   get wiped by the system. The state directory is now
   `~/.local/share/obsidian-icloud-sync/` along with the log and lock
   file.
2. Added rclone's `--resilient` and `--recover` flags so transient
   hiccups do not abort the run.
3. Taught the wrapper to detect that specific error pattern
   (bisync demanding a manual resync), run `--resync` on its own, and
   then notify me that it recovered rather than that it broke.

After that the failures stopped. The 2am panic notifications stopped.
The setup has been quietly keeping the vault in sync since.

### Why this matters if you copy the approach

If you reuse this setup and the sync stops working one day with no
notification, check `~/.local/share/obsidian-icloud-sync/sync.log`
first. The most likely cause is a missing bisync baseline, and the
fix is a one-shot `--resync`. The wrapper now does that automatically,
but the older versions did not.