# Primary watchdog

`bin/fm-primary-watchdog.sh` notices from outside firstmate's own session that the primary has stopped.
When the primary's session has ended it restarts firstmate, and when a restart is not possible or does not take it alerts the captain once.
It is opt-in: nothing runs until its cron line is installed.

## What counts as stopped

The watchdog reads only firstmate-owned records of the home it is scoped to.
The primary counts as stopped when its session lock is free or stale, or when an inbox note has stayed unacknowledged past the threshold (15 minutes by default) while the primary has also shown no turn activity for that long.
A note waiting behind recent turn activity is a slow answer, not a stop, and worker state is never read, so one slow worker or answer never fires it.
The script header owns the exact verdicts, activity signals, and episode rules.

## What it does

An ended session gets a short grace period and then at most one restart attempt per episode, with a cooldown between restarts so a crash loop alerts instead of relaunching repeatedly.
The restart supports a Herdr primary only: it types the recorded launch command into the primary's recorded pane when only a shell remains there, or opens a new tab in the recorded workspace (or a new workspace when that is gone too) when the pane is gone.
The primary records that endpoint at the end of every locked session start, and the restart starts a fresh session whose own session-start digest rebuilds state.
A restart counts only when a different harness holds the session lock and has finished its session start.
A stopped primary whose harness still runs is never killed or typed into; the watchdog alerts instead.
Any other primary backend, a missing endpoint record, a stopped Herdr session, or a pane that is not an idle shell also alerts instead of restarting.
Secondmate homes are skipped, because their parent recovers them.

## Alerts

Alerts go through the channels configured in `config/wedge-alarm`, whose directives [wedge-alarm.md](wedge-alarm.md) owns, and always leave the summary in `state/.primary-watchdog-alert`.
On Linux the `auto` default resolves to no active channel, so list a channel such as `herdr` there for the alert to reach the screen.
The watchdog adds no service of its own.

## Installing

Install one cron line per home, scoped by `FM_HOME`, for example every five minutes:

```cron
*/5 * * * * FM_HOME=/path/to/home /path/to/firstmate/bin/fm-primary-watchdog.sh check >> /path/to/home/state/primary-watchdog.log 2>&1
```

Cron's minimal `PATH` must still find `herdr`, `jq`, and `python3`, so prefix the command with a `PATH=...` assignment when they live outside `/usr/bin:/bin`.
Run `fm-primary-watchdog.sh check --dry-run` by hand first; it prints the verdict and the action it would take and changes nothing.
Thresholds are environment variables on the same line; `fm-primary-watchdog.sh --help` lists them.

## Verification

`tests/fm-primary-watchdog.test.sh` pins the verdicts, the restart paths against a fake Herdr CLI, and the once-per-episode alert.
