# Live watchdog run against a real Claude primary in a lab tmux session

Lab home /tmp/fm-lab.ZReFnH; the primary is `claude -n fm-lab-primary` on the private fm-lab tmux socket, pointed at a disposable local API stub (ANTHROPIC_BASE_URL) whose mode file decides 403 / hang / ok. Every API error row below was written by Claude Code itself. Alerts go to a recorder via FM_WEDGE_ALARM_EXEC; the nudge goes through the real tmux verified submit (no FM_TEST_SEAM).

## S1a: fresh API error (default 300s grace) is not nudged

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=300 check   # 16:06:23Z, stub mode=403
primary-watchdog: 2026-11-13T16:06:23Z verdict=alive action=none - lock=held oldest-note-age=none activity-age=47 error-age=47 watcher-beat-age=1794585983
--- state/.primary-watchdog:
(absent)
--- alerts recorded so far: 0
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:05:36.129Z user  say hello
  2026-11-13T16:05:36.758Z assistant isApiErrorMessage Please run /login · API Error: 403 stub: forbidden
--- primary pane (lab tmux):
 ▝▝   ▝▝   /home/ddg/.no-mistakes/worktrees/67bf63ea0b24/01M7ASVG3KBSBFE6C20PFZ9QNP
❯ say hello
● Please run /login · API Error: 403 stub: forbidden
✻ Cooked for 0s · done 4:05 PM
❯ 
```

## S2: API error past the grace but the watch is armed (fresh state/.last-watcher-beat) - left alone

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 check   # 16:06:26Z, stub mode=403
primary-watchdog: 2026-11-13T16:06:27Z verdict=alive action=none - lock=held oldest-note-age=none activity-age=50 error-age=50 watcher-beat-age=0
--- state/.primary-watchdog:
(absent)
--- alerts recorded so far: 0
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:05:36.129Z user  say hello
  2026-11-13T16:05:36.758Z assistant isApiErrorMessage Please run /login · API Error: 403 stub: forbidden
--- primary pane (lab tmux):
 ▝▝   ▝▝   /home/ddg/.no-mistakes/worktrees/67bf63ea0b24/01M7ASVG3KBSBFE6C20PFZ9QNP
❯ say hello
● Please run /login · API Error: 403 stub: forbidden
✻ Cooked for 0s · done 4:05 PM
❯ 
```

## S1b: errored primary (API error 30s+ old, no watch beacon, no inbox note) is nudged through the real tmux verified submit

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 check   # 16:06:33Z, stub mode=403
primary-watchdog: 2026-11-13T16:06:36Z verdict=errored action=nudged - nudged %0; lock=held oldest-note-age=none activity-age=57 error-age=57 watcher-beat-age=1794585993
--- state/.primary-watchdog:
since=1794585993
reason=errored
nudged_at=1794585993
--- alerts recorded so far: 0
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:05:36.758Z assistant isApiErrorMessage Please run /login · API Error: 403 stub: forbidden
  2026-11-13T16:06:35.353Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
  2026-11-13T16:06:35.917Z assistant isApiErrorMessage Please run /login · API Error: 403 stub: forbidden
--- primary pane (lab tmux):
 ▝▝   ▝▝   /home/ddg/.no-mistakes/worktrees/67bf63ea0b24/01M7ASVG3KBSBFE6C20PFZ9QNP
❯ say hello
● Please run /login · API Error: 403 stub: forbidden
✻ Cooked for 0s · done 4:05 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
● Please run /login · API Error: 403 stub: forbidden
✻ Sautéed for 0s · done 4:06 PM
❯ 
```

## S3a: right after the nudge the refused nudge turn is a fresh error - episode stays open, no retype

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 check   # 16:06:53Z, stub mode=403
primary-watchdog: 2026-11-13T16:06:54Z verdict=errored action=wait - the newest turn entry is still an API error, 18s old; lock=held oldest-note-age=none activity-age=17 error-age=18 watcher-beat-age=1794586013
--- state/.primary-watchdog:
since=1794585993
reason=errored
nudged_at=1794585993

## S3b: still errored after the nudge, inside the 1800s spacing - one alert, no second nudge

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 check   # 16:07:27Z, stub mode=403
primary-watchdog: 2026-11-13T16:07:29Z verdict=errored action=alerted - firstmate in /tmp/fm-lab.ZReFnH is still stopped on an API error 0m after a nudge; the next nudge follows within 30m
--- state/.primary-watchdog:
since=1794585993
reason=errored
nudged_at=1794585993
alerted_at=1794586047
--- alerts recorded so far: 1
--- newest main-thread turn entries in the primary's real transcript:

## S3c: next run in the same episode - quiet, no second alert, no nudge

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 check   # 16:07:29Z, stub mode=403
primary-watchdog: 2026-11-13T16:07:30Z verdict=errored action=quiet - already alerted for this episode; lock=held oldest-note-age=none activity-age=53 error-age=54 watcher-beat-age=1794586049
--- state/.primary-watchdog:
since=1794585993
reason=errored
nudged_at=1794585993
alerted_at=1794586047
--- alerts recorded so far: 1

## S4a: nudge spacing elapsed (FM_PRIMARY_WATCHDOG_NUDGE_SECS=60) and still errored - nudged again, alert not repeated

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 FM_PRIMARY_WATCHDOG_NUDGE_SECS=60 check   # 16:07:42Z, stub mode=hang
primary-watchdog: 2026-11-13T16:07:45Z verdict=errored action=nudged - nudged %0; lock=held oldest-note-age=none activity-age=66 error-age=67 watcher-beat-age=1794586062
--- state/.primary-watchdog:
since=1794585993
reason=errored
nudged_at=1794586062
alerted_at=1794586047
--- alerts recorded so far: 1
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:06:35.353Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
  2026-11-13T16:06:35.917Z assistant isApiErrorMessage Please run /login · API Error: 403 stub: forbidden
  2026-11-13T16:07:44.906Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
--- primary pane (lab tmux):
✻ Cooked for 0s · done 4:05 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
● Please run /login · API Error: 403 stub: forbidden
✻ Sautéed for 0s · done 4:06 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
✶ Honking…
  ⎿  Tip: Connect Claude to your IDE · /ide
❯ 
```

## S4b: the nudge's own prompt is unanswered (API hanging, turn in progress) for longer than both the grace and the spacing - episode kept open, nothing typed

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 FM_PRIMARY_WATCHDOG_NUDGE_SECS=60 check   # 16:08:54Z, stub mode=hang
primary-watchdog: 2026-11-13T16:08:55Z verdict=errored action=wait - a prompt after the API error has no answer yet; lock=held oldest-note-age=none activity-age=69
--- state/.primary-watchdog:
since=1794585993
reason=errored
nudged_at=1794586062
alerted_at=1794586047
--- alerts recorded so far: 1
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:06:35.353Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
  2026-11-13T16:06:35.917Z assistant isApiErrorMessage Please run /login · API Error: 403 stub: forbidden
  2026-11-13T16:07:44.906Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
--- primary pane (lab tmux):
✻ Cooked for 0s · done 4:05 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
● Please run /login · API Error: 403 stub: forbidden
✻ Sautéed for 0s · done 4:06 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
✶ Honking… (1m 11s)
  ⎿  Tip: Connect Claude to your IDE · /ide
❯ 
```

## S5a: owner interrupts the hanging nudge turn while the episode is open - still waiting, nothing typed

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 FM_PRIMARY_WATCHDOG_NUDGE_SECS=60 check   # 16:09:10Z, stub mode=hang
primary-watchdog: 2026-11-13T16:09:11Z verdict=errored action=wait - a prompt after the API error has no answer yet; lock=held oldest-note-age=none activity-age=85
--- state/.primary-watchdog:
since=1794585993
reason=errored
nudged_at=1794586062
alerted_at=1794586047
--- alerts recorded so far: 1
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:06:35.353Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
  2026-11-13T16:06:35.917Z assistant isApiErrorMessage Please run /login · API Error: 403 stub: forbidden
  2026-11-13T16:07:44.906Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
--- primary pane (lab tmux):
 ▝▝   ▝▝   /home/ddg/.no-mistakes/worktrees/67bf63ea0b24/01M7ASVG3KBSBFE6C20PFZ9QNP
❯ say hello
● Please run /login · API Error: 403 stub: forbidden
✻ Cooked for 0s · done 4:05 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
● Please run /login · API Error: 403 stub: forbidden
✻ Sautéed for 0s · done 4:06 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
```

## S6: the API answers again (stub ok) and the newest assistant entry is a real reply - episode closes as recovered

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 FM_PRIMARY_WATCHDOG_NUDGE_SECS=60 check   # 16:09:29Z, stub mode=ok
primary-watchdog: 2026-11-13T16:09:30Z verdict=alive action=recovered - lock=held oldest-note-age=none activity-age=10
--- state/.primary-watchdog:
(absent)
--- alerts recorded so far: 1
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:07:44.906Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
  2026-11-13T16:09:17.790Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.status?
  2026-11-13T16:09:18.339Z assistant  Back online (stub reply).
--- primary pane (lab tmux):
✻ Cooked for 0s · done 4:05 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
● Please run /login · API Error: 403 stub: forbidden
✻ Sautéed for 0s · done 4:06 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.status?
● Back online (stub reply).
✻ Cooked for 1s · done 4:09 PM
❯ 
```

## S7: errored primary whose composer holds the owner's unsent draft - nothing typed, one alert

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 check   # 16:10:17Z, stub mode=403
primary-watchdog: 2026-11-13T16:10:18Z verdict=errored action=alerted - firstmate in /tmp/fm-lab.ZReFnH stopped on an API error 0m ago and could not be nudged: the composer in %0 is not provably empty, so nothing was typed over it
--- state/.primary-watchdog:
since=1794586217
reason=errored
alerted_at=1794586217
--- alerts recorded so far: 2
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:09:18.339Z assistant  Back online (stub reply).
  2026-11-13T16:09:40.027Z user  ping
  2026-11-13T16:09:40.541Z assistant isApiErrorMessage Please run /login · API Error: 403 stub: forbidden
--- primary pane (lab tmux):
✻ Sautéed for 0s · done 4:06 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.status?
● Back online (stub reply).
✻ Cooked for 1s · done 4:09 PM
❯ ping
● Please run /login · API Error: 403 stub: forbidden
✻ Baked for 0s · done 4:09 PM
❯ owner draft, do not overwrite
```

## S7b: next run in the same episode - quiet, still nothing typed

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 check   # 16:10:18Z, stub mode=403
primary-watchdog: 2026-11-13T16:10:19Z verdict=errored action=quiet - already alerted for this episode; lock=held oldest-note-age=none activity-age=38 error-age=38 watcher-beat-age=1794586218
--- state/.primary-watchdog:
since=1794586217
reason=errored
alerted_at=1794586217
--- alerts recorded so far: 2
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:09:18.339Z assistant  Back online (stub reply).
  2026-11-13T16:09:40.027Z user  ping
  2026-11-13T16:09:40.541Z assistant isApiErrorMessage Please run /login · API Error: 403 stub: forbidden
--- primary pane (lab tmux):
✻ Sautéed for 0s · done 4:06 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.status?
● Back online (stub reply).
✻ Cooked for 1s · done 4:09 PM
❯ ping
● Please run /login · API Error: 403 stub: forbidden
✻ Baked for 0s · done 4:09 PM
❯ owner draft, do not overwrite
```

## S8a: owner cleared the draft and the API is back - the pending nudge is now typed (alert not repeated)

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 check   # 16:10:27Z, stub mode=ok
primary-watchdog: 2026-11-13T16:10:30Z verdict=errored action=nudged - nudged %0; lock=held oldest-note-age=none activity-age=47 error-age=47 watcher-beat-age=1794586227
--- state/.primary-watchdog:
since=1794586217
reason=errored
nudged_at=1794586227
alerted_at=1794586217
--- alerts recorded so far: 2
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:09:40.541Z assistant isApiErrorMessage Please run /login · API Error: 403 stub: forbidden
  2026-11-13T16:10:29.188Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
  2026-11-13T16:10:29.802Z assistant  Back online (stub reply).
--- primary pane (lab tmux):
❯ ping
● Please run /login · API Error: 403 stub: forbidden
✻ Baked for 0s · done 4:09 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
● Back online (stub reply).
✢ Drizzling… (running Stop hooks… 3/4 · 1s · ↓ 6 tokens)
                                                                                                                                                                          Ctrl+Y to paste deleted text
❯ 
```

## S8b: the nudged turn was answered - episode closes, the primary is running again without the owner

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 check   # 16:10:40Z, stub mode=ok
primary-watchdog: 2026-11-13T16:10:41Z verdict=alive action=recovered - lock=held oldest-note-age=none activity-age=10
--- state/.primary-watchdog:
(absent)
--- alerts recorded so far: 2
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:09:40.541Z assistant isApiErrorMessage Please run /login · API Error: 403 stub: forbidden
  2026-11-13T16:10:29.188Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
  2026-11-13T16:10:29.802Z assistant  Back online (stub reply).
--- primary pane (lab tmux):
✻ Cooked for 1s · done 4:09 PM
❯ ping
● Please run /login · API Error: 403 stub: forbidden
✻ Baked for 0s · done 4:09 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
● Back online (stub reply).
✻ Churned for 1s · done 4:10 PM
❯ 
```

## S9: owner interrupted a turn (no API error, no open episode) - alive, never typed into

```
$ FM_PRIMARY_WATCHDOG_ERROR_SECS=30 check   # 16:11:27Z, stub mode=hang
primary-watchdog: 2026-11-13T16:11:28Z verdict=alive action=none - lock=held oldest-note-age=none activity-age=38
--- state/.primary-watchdog:
(absent)
--- alerts recorded so far: 2
--- newest main-thread turn entries in the primary's real transcript:
  2026-11-13T16:10:29.188Z user  Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
  2026-11-13T16:10:29.802Z assistant  Back online (stub reply).
  2026-11-13T16:10:48.492Z user  long task
--- primary pane (lab tmux):
✻ Cooked for 1s · done 4:09 PM
❯ ping
● Please run /login · API Error: 403 stub: forbidden
✻ Baked for 0s · done 4:09 PM
❯ Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on.
● Back online (stub reply).
✻ Churned for 1s · done 4:10 PM
❯ 
```
