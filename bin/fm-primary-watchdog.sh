#!/usr/bin/env bash
# fm-primary-watchdog.sh - notice, from outside firstmate's own session, that the
# primary has stopped, restart or nudge it, and alert the captain once when it
# cannot.
#
# Usage:
#   fm-primary-watchdog.sh record [--pid <harness-pid>]
#   fm-primary-watchdog.sh check
#
# `record` runs inside the primary at the end of every locked full session start
# (bin/fm-session-start.sh). It writes state/.primary-endpoint: the primary's
# backend and pane target (bin/fm-supervisor-target-lib.sh discovery), the
# Herdr workspace, the harness pid (default: the session-lock holder), its
# command line, and its working directory. On Linux the command line and
# directory come from /proc, and an FM_HOME in the harness environment is kept
# as a prefix of the command; elsewhere they come from ps(1) and the caller's
# directory.
#
# `check` is the cron entry, scoped to one FM_HOME. It never runs inside the
# primary and never acquires the session lock. Each run prints one line:
#   primary-watchdog: <utc> verdict=<v> action=<a> - <detail>
# Verdicts, decided only from firstmate-owned records:
#   dead      the session lock is free or stale (bin/fm-inbox.sh ready).
#   stalled   a live harness holds the lock, the oldest unacknowledged inbox
#             note (bin/fm-inbox.sh receipts) is older than the note threshold,
#             AND the primary's last turn activity is older than that threshold.
#             Turn activity is the newest of the primary harness's own Claude
#             session transcript, which grows during a turn
#             ($HOME/.claude/projects/<encoded cwd>/<state/.lock-session id>.jsonl,
#             where <encoded cwd> is the recorded cwd with every character
#             outside A-Za-z0-9 replaced by "-" as Claude Code names it, or
#             the newest *.jsonl there when no id is recorded),
#             state/.claude-autoarm-epoch (every Claude
#             primary turn end), state/inbox/handled (every note
#             acknowledgement), and state/.session-start-complete.
#   errored   a live harness holds the lock, the newest turn entry in that
#             same transcript is an API error (Claude Code's own
#             `isApiErrorMessage` record) at least the error grace old, and
#             the watcher's liveness beacon (state/.last-watcher-beat) is that
#             old too. A turn the API refused ends without arming the watch,
#             so nothing inside the session can wake it again. No inbox note
#             is needed. Any later entry - a new prompt, a finished turn, the
#             owner's interrupt - means it is not errored. While an errored
#             episode is open, a prompt after the error that has no answer yet
#             (the nudge itself, or a turn the API is still retrying) keeps
#             the episode open without another nudge.
#   alive     none of these; a note waiting behind recent activity is a slow
#             answer.
#   uncertain the lock state cannot be classified; nothing is done.
#   skipped   this is a secondmate home, which its parent recovers.
# Worker state is never read, so one slow worker can never trigger it.
#
# Episodes. A dead, stalled, or errored verdict opens an episode in
# state/.primary-watchdog; the next alive verdict closes it, except as the
# errored rules below keep an errored episode open. Within one episode:
#   - a dead primary waits FM_PRIMARY_WATCHDOG_DEAD_GRACE_SECS, then gets at
#     most ONE restart attempt, and none while a previous restart is inside
#     FM_PRIMARY_WATCHDOG_COOLDOWN_SECS (state/.primary-watchdog-last-restart);
#   - a stalled primary is never restarted, only alerted: its session still
#     runs, the owner may have stopped firstmate there on purpose, and a
#     restart would override that; only an ended session is restarted;
#   - an errored primary is nudged: one short line typed into its recorded
#     endpoint through the backend's verified submit primitive
#     (fm_backend_send_text_submit, the one the away-mode daemon injects
#     through), only when the backend does not report a turn in progress and
#     the composer is provably empty, so the owner's own typing is never
#     overwritten. The session, its context, and its process are untouched.
#     A nudge is repeated at most every FM_PRIMARY_WATCHDOG_NUDGE_SECS while
#     the error lasts, so a long outage heals by itself once the API answers;
#     a nudge that cannot be typed, or a primary still errored after one,
#     alerts ONCE. An errored episode ends only when the newest assistant turn
#     entry is no longer an API error;
#   - a failed, refused, cooled-down, or unverified restart alerts ONCE, and a
#     restart that verified but did not keep the primary up alerts once too.
# A verdict that changes kind (stalled to dead) opens a new episode.
#
# Restart (Herdr only; any other recorded backend refuses and alerts). The
# recorded session must already be running - the watchdog never starts a
# Herdr server. A recorded pane whose processes are only a shell receives
# `cd -- <cwd> && <launch>` through `pane run`; a gone pane gets a new
# unfocused tab in the recorded workspace first, or a new unfocused workspace
# when that workspace is gone too. A pane still running a
# harness, or one that cannot be read, is refused. The new session starts
# fresh; its session-start digest rebuilds state. The restart counts only once
# a different harness pid holds the lock and state/.session-start-complete
# names that pid, within FM_PRIMARY_WATCHDOG_VERIFY_SECS.
#
# Alerts go through the configured channels in config/wedge-alarm
# (bin/fm-alert-channel-lib.sh; docs/wedge-alarm.md owns the directives) and
# always leave the summary in state/.primary-watchdog-alert. No other service.
#
# Overlapping runs are skipped through the state/.primary-watchdog.lock
# directory.
#
# Environment:
#   FM_HOME                              operational home (default: code root)
#   FM_STATE_OVERRIDE                    state directory (default: $FM_HOME/state)
#   FM_PRIMARY_WATCHDOG_NOTE_SECS        unhandled-note and inactivity threshold (900)
#   FM_PRIMARY_WATCHDOG_DEAD_GRACE_SECS  wait before restarting an ended session (120)
#   FM_PRIMARY_WATCHDOG_COOLDOWN_SECS    minimum spacing between restarts (1800)
#   FM_PRIMARY_WATCHDOG_VERIFY_SECS      wait for a fresh session after a restart (180)
#   FM_PRIMARY_WATCHDOG_ERROR_SECS       age of an API error before it is nudged (300)
#   FM_PRIMARY_WATCHDOG_NUDGE_SECS       minimum spacing between nudges (1800)
#   FM_WEDGE_ALARM_CHANNEL / FM_WEDGE_ALARM_EXEC  alert channel override and test seam
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENDPOINT="$STATE/.primary-endpoint"
EPISODE="$STATE/.primary-watchdog"
LAST_RESTART="$STATE/.primary-watchdog-last-restart"
ALERT_MARKER="$STATE/.primary-watchdog-alert"
RUN_LOCK="$STATE/.primary-watchdog.lock"

NOTE_SECS=${FM_PRIMARY_WATCHDOG_NOTE_SECS:-900}
DEAD_GRACE_SECS=${FM_PRIMARY_WATCHDOG_DEAD_GRACE_SECS:-120}
COOLDOWN_SECS=${FM_PRIMARY_WATCHDOG_COOLDOWN_SECS:-1800}
VERIFY_SECS=${FM_PRIMARY_WATCHDOG_VERIFY_SECS:-180}
ERROR_SECS=${FM_PRIMARY_WATCHDOG_ERROR_SECS:-300}
NUDGE_SECS=${FM_PRIMARY_WATCHDOG_NUDGE_SECS:-1800}
# One short line: the verified submit proves it in the composer before Enter.
NUDGE_TEXT="Watchdog: your last turn failed on an API error. Run bin/fm-wake-drain.sh and carry on."
RUN_LOCK_STALE_SECS=900

die() { printf 'fm-primary-watchdog: %s\n' "$*" >&2; exit 2; }
log() { printf 'fm-primary-watchdog: %s\n' "$*" >&2; }

for _v in NOTE_SECS DEAD_GRACE_SECS COOLDOWN_SECS VERIFY_SECS ERROR_SECS NUDGE_SECS; do
  case "${!_v}" in ''|*[!0-9]*) die "FM_PRIMARY_WATCHDOG_${_v} must be a whole number of seconds" ;; esac
done
unset _v

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SELF_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SELF_DIR/fm-primary-scope-lib.sh"

mtime() {  # <path> -> epoch or nothing
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null || true
  else
    stat -c %Y "$1" 2>/dev/null || true
  fi
}

# key=value record field, or nothing.
field() {  # <file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

write_record() {  # <file> <key=value>...
  local file=$1 tmp
  shift
  tmp=$(mktemp "$file.XXXXXX")
  printf '%s\n' "$@" > "$tmp"
  mv -f "$tmp" "$file"
}

# ---------------------------------------------------------------- record

harness_cmdline() {  # <pid>
  local pid=$1 arg out=
  if [ -r "/proc/$pid/cmdline" ]; then
    while IFS= read -r -d '' arg; do
      out="${out:+$out }$(printf '%q' "$arg")"
    done < "/proc/$pid/cmdline"
  fi
  [ -n "$out" ] || out=$(fm_ps_args "$pid" 2>/dev/null || true)
  # A primary started with an explicit FM_HOME must come back on that home.
  if [ -n "$out" ] && [ -r "/proc/$pid/environ" ]; then
    arg=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^FM_HOME=//p' | head -n 1)
    [ -z "$arg" ] || out="FM_HOME=$(printf '%q' "$arg") $out"
  fi
  printf '%s' "$out"
}

harness_cwd() {  # <pid>
  local pid=$1 dir
  dir=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
  if [ -z "$dir" ] && command -v lsof >/dev/null 2>&1; then
    dir=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
  fi
  [ -n "$dir" ] || dir=$(pwd -P)
  printf '%s' "$dir"
}

cmd_record() {
  local pid="" backend target workspace launch cwd
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pid) [ "$#" -ge 2 ] || die "usage: fm-primary-watchdog.sh record [--pid <harness-pid>]"; pid=$2; shift 2 ;;
      *) die "usage: fm-primary-watchdog.sh record [--pid <harness-pid>]" ;;
    esac
  done
  [ -n "$pid" ] || pid=$(head -n 1 "$STATE/.lock" 2>/dev/null || true)
  if ! fm_session_pid_valid "$pid" || ! kill -0 "$pid" 2>/dev/null; then
    die "no live session-lock holder to record"
  fi
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SELF_DIR/fm-supervisor-target-lib.sh"
  # Discovery's fallback is a guess, so an endpoint is recorded only from a
  # positive signal; otherwise any stale record is removed rather than kept.
  if ! backend=$(discover_supervisor_backend 2>/dev/null) \
    || ! target=$(discover_supervisor_target 2>/dev/null); then
    rm -f "$ENDPOINT"
    die "the primary's endpoint could not be discovered; nothing recorded"
  fi
  workspace=
  if [ "$backend" = herdr ]; then
    workspace=${HERDR_WORKSPACE_ID:-}
    if [ -z "$workspace" ]; then
      workspace=${target#*:}
      workspace=${workspace%%:*}
    fi
  fi
  launch=$(harness_cmdline "$pid")
  [ -n "$launch" ] || die "the harness command line for pid $pid could not be read"
  cwd=$(harness_cwd "$pid")
  case "$launch$cwd$target$workspace" in
    *$'\n'*) die "refusing to record a multi-line endpoint field" ;;
  esac
  mkdir -p "$STATE"
  write_record "$ENDPOINT" \
    "schema=fm-primary-endpoint.v1" \
    "recorded_at=$(date +%s)" \
    "backend=$backend" \
    "target=$target" \
    "workspace=$workspace" \
    "cwd=$cwd" \
    "harness_pid=$pid" \
    "launch=$launch"
  printf 'recorded %s %s\n' "$backend" "$target"
}

# ---------------------------------------------------------------- check

# The primary's own Claude session transcript: the recorded session's file, or
# every transcript for the recorded cwd when no session id is recorded.
primary_transcripts() {
  local cwd dir id
  cwd=$(field "$ENDPOINT" cwd)
  [ -n "$cwd" ] && [ -n "${HOME:-}" ] || return 0
  dir="$HOME/.claude/projects/${cwd//[^a-zA-Z0-9]/-}"
  [ -d "$dir" ] || return 0
  if id=$(fm_session_lock_recorded_session_id "$STATE"); then
    printf '%s\n' "$dir/$id.jsonl"
  else
    printf '%s\n' "$dir"/*.jsonl
  fi
}

# Print the epoch of the newest assistant turn entry in <transcript> when that
# entry is an API error, prefixed with "pending " when a user turn entry follows
# it, and nothing otherwise. A turn entry is a main-thread user or assistant
# row; the bookkeeping rows Claude Code appends between turns are skipped. Only
# the tail is read, so a long session costs the same as a new one.
last_turn_error_epoch() {  # <transcript>
  [ -f "$1" ] || return 0
  python3 - "$1" <<'PY' 2>/dev/null || true
import calendar, json, os, sys, time
path = sys.argv[1]
with open(path, "rb") as handle:
    handle.seek(0, os.SEEK_END)
    size = handle.tell()
    handle.seek(max(0, size - 1048576))
    lines = handle.read().decode("utf-8", "replace").splitlines()
if size > 1048576:
    lines = lines[1:]
pending = ""
for line in reversed(lines):
    try:
        row = json.loads(line)
    except ValueError:
        continue
    if not isinstance(row, dict) or row.get("type") not in ("user", "assistant"):
        continue
    if row.get("isSidechain") or row.get("isMeta"):
        continue
    if row.get("type") == "user":
        pending = "pending "
        continue
    if row.get("isApiErrorMessage") is True:
        try:
            stamp = (row.get("timestamp") or "").split(".")[0].rstrip("Z")
            print(pending + str(calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%S"))))
        except ValueError:
            print(pending + str(int(os.path.getmtime(path))))
    break
PY
}

# Sets LOCK_STATE, LOCK_PID, OLDEST_NOTE_AGE (empty when none), ACTIVITY_AGE,
# ERROR_AGE (empty unless the newest turn entry is an API error), ERROR_PENDING
# (1 when only user turn entries follow an API error), and BEAT_AGE.
observe() {  # <now>
  local now=$1 ready receipts oldest m newest=0 path transcript='' transcript_m=0 error_at
  ready=$(FM_HOME="$FM_HOME" "$SELF_DIR/fm-inbox.sh" ready 2>/dev/null) || ready=
  receipts=$(FM_HOME="$FM_HOME" "$SELF_DIR/fm-inbox.sh" receipts --all-pending 2>/dev/null) || receipts=
  read -r LOCK_STATE LOCK_PID <<EOF
$(printf '%s' "$ready" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    lock = d.get("lock") or {}
    print(lock.get("state") or "unknown", lock.get("pid") or "-")
except Exception:
    print("unknown -")
' 2>/dev/null || printf 'unknown -\n')
EOF
  [ "$LOCK_PID" != - ] || LOCK_PID=
  oldest=$(printf '%s' "$receipts" | python3 -c '
import calendar, json, sys, time
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ages = []
for note in d.get("pending") or []:
    try:
        ages.append(calendar.timegm(time.strptime(note.get("at") or "", "%Y-%m-%dT%H:%M:%SZ")))
    except ValueError:
        pass
if ages:
    print(min(ages))
' 2>/dev/null || true)
  OLDEST_NOTE_AGE=
  [ -z "$oldest" ] || OLDEST_NOTE_AGE=$((now - oldest))
  while IFS= read -r path; do
    m=$(mtime "$path")
    [ -n "$m" ] || continue
    [ "$m" -le "$newest" ] || newest=$m
  done < <(primary_transcripts
    printf '%s\n' "$STATE/.claude-autoarm-epoch" "$STATE/inbox/handled" "$STATE/.session-start-complete")
  ACTIVITY_AGE=$((now - newest))
  while IFS= read -r path; do
    m=$(mtime "$path")
    [ -n "$m" ] && [ "$m" -gt "$transcript_m" ] || continue
    transcript_m=$m
    transcript=$path
  done < <(primary_transcripts)
  ERROR_AGE=
  ERROR_PENDING=
  error_at=
  [ -z "$transcript" ] || error_at=$(last_turn_error_epoch "$transcript")
  case "$error_at" in pending\ *) ERROR_PENDING=1; error_at= ;; esac
  case "$error_at" in ''|*[!0-9]*) ;; *) ERROR_AGE=$((now - error_at)); [ "$ERROR_AGE" -ge 0 ] || ERROR_AGE=0 ;; esac
  m=$(mtime "$STATE/.last-watcher-beat")
  BEAT_AGE=$((now - ${m:-0}))
}

classify() {
  case "$LOCK_STATE" in
    free|stale) VERDICT=dead; return ;;
    held) ;;
    *) VERDICT=uncertain; return ;;
  esac
  if [ -n "$ERROR_AGE" ] && [ "$ERROR_AGE" -ge "$ERROR_SECS" ] && [ "$BEAT_AGE" -ge "$ERROR_SECS" ]; then
    VERDICT=errored
  elif [ -n "$OLDEST_NOTE_AGE" ] && [ "$OLDEST_NOTE_AGE" -ge "$NOTE_SECS" ] \
    && [ "$ACTIVITY_AGE" -ge "$NOTE_SECS" ]; then
    VERDICT=stalled
  else
    VERDICT=alive
  fi
}

say() {  # <verdict> <action> <detail>
  printf 'primary-watchdog: %s verdict=%s action=%s - %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3"
}

alert() {  # <summary>
  local summary=$1
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$summary" > "$ALERT_MARKER.tmp" \
    && mv -f "$ALERT_MARKER.tmp" "$ALERT_MARKER"
  WEDGE_ALARM_TITLE="firstmate stopped"
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SELF_DIR/fm-supervisor-target-lib.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$SELF_DIR/fm-backend.sh"
  # shellcheck source=bin/fm-alert-channel-lib.sh
  . "$SELF_DIR/fm-alert-channel-lib.sh"
  wedge_alarm_notify "$summary" "$ALERT_MARKER" || true
}

# Wait for a fresh session: a live harness other than <old-pid> holds the lock
# and has completed its session start.
verify_fresh_session() {  # <old-pid>
  local old=$1 deadline pid done_pid
  deadline=$(( $(date +%s) + VERIFY_SECS ))
  while :; do
    fm_session_lock_inspect "$STATE"
    pid=$FM_LOCK_INSPECT_PID
    if [ "$FM_LOCK_INSPECT_STATE" = held ] && [ -n "$pid" ] && [ "$pid" != "$old" ]; then
      done_pid=$(head -n 1 "$STATE/.session-start-complete" 2>/dev/null || true)
      [ "$done_pid" != "$pid" ] || return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 1
  done
}

# Sets RESTART_DETAIL. Returns 0 only for a verified fresh session.
restart_primary() {
  local backend target cwd launch workspace old session pane presence pstate out line
  RESTART_DETAIL=
  [ -f "$ENDPOINT" ] || { RESTART_DETAIL="no primary endpoint was recorded at session start"; return 1; }
  backend=$(field "$ENDPOINT" backend)
  target=$(field "$ENDPOINT" target)
  cwd=$(field "$ENDPOINT" cwd)
  launch=$(field "$ENDPOINT" launch)
  workspace=$(field "$ENDPOINT" workspace)
  old=$(field "$ENDPOINT" harness_pid)
  [ "$backend" = herdr ] || { RESTART_DETAIL="restart supports a Herdr primary only (recorded backend: ${backend:-none})"; return 1; }
  [ -n "$target" ] && [ -n "$cwd" ] && [ -n "$launch" ] \
    || { RESTART_DETAIL="the recorded endpoint is incomplete"; return 1; }
  # shellcheck source=bin/fm-backend.sh
  . "$SELF_DIR/fm-backend.sh"
  fm_backend_source herdr >/dev/null 2>&1 || { RESTART_DETAIL="the Herdr adapter could not be loaded"; return 1; }
  fm_backend_herdr_parse_target "$target" || { RESTART_DETAIL="the recorded target '$target' is malformed"; return 1; }
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  fm_backend_herdr_target_observable "$target" \
    || { RESTART_DETAIL="Herdr session '$session' is not running"; return 1; }
  presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane")
  case "$presence" in
    present)
      pstate=$(fm_backend_herdr_pane_process_state "$session" "$pane")
      [ "$pstate" = shell ] \
        || { RESTART_DETAIL="the recorded pane $pane is not an idle shell ($pstate); not typing into it"; return 1; }
      ;;
    dead)
      [ -n "$workspace" ] || { RESTART_DETAIL="the recorded pane is gone and no workspace was recorded"; return 1; }
      # Closing a workspace's last pane removes the workspace, so a gone
      # workspace gets a fresh one instead of a tab.
      out=$(fm_backend_herdr_cli "$session" tab create --workspace "$workspace" --cwd "$cwd" \
        --label firstmate --no-focus 2>/dev/null) \
        || out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$cwd" \
          --label firstmate --no-focus 2>/dev/null) \
        || { RESTART_DETAIL="the recorded pane is gone and neither a tab in workspace $workspace nor a new workspace could be opened"; return 1; }
      pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
      [ -n "$pane" ] || { RESTART_DETAIL="the new tab's pane id could not be read"; return 1; }
      ;;
    *) RESTART_DETAIL="the recorded pane $pane could not be read"; return 1 ;;
  esac
  line="cd -- $(printf '%q' "$cwd") && $launch"
  fm_backend_herdr_cli "$session" pane run "$pane" "$line" >/dev/null 2>&1 \
    || { RESTART_DETAIL="the relaunch could not be sent to pane $pane"; return 1; }
  verify_fresh_session "$old" \
    || { RESTART_DETAIL="relaunched in pane $pane but no fresh session completed startup within ${VERIFY_SECS}s"; return 1; }
  RESTART_DETAIL="relaunched in pane $pane"
  return 0
}

# Type the nudge into <backend> <target> and print sent|busy|composer|failed.
# Nothing is typed while a turn is in progress or the composer holds text.
nudge_submit() {  # <backend> <target>
  local backend=$1 target=$2
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SELF_DIR/fm-supervisor-target-lib.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$SELF_DIR/fm-backend.sh"
  if [ "$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)" = busy ]; then
    printf 'busy'
  elif [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" != empty ]; then
    printf 'composer'
  elif [ "$(fm_backend_send_text_submit "$backend" "$target" "$NUDGE_TEXT" 3 0.4 0.4 2>/dev/null)" = empty ]; then
    printf 'sent'
  else
    printf 'failed'
  fi
}

# Sets NUDGE_DETAIL, and NUDGE_TRIED when the line may have been typed.
# Returns 0 only for a confirmed submit.
nudge_primary() {
  local backend target verdict
  NUDGE_DETAIL=
  NUDGE_TRIED=
  [ -f "$ENDPOINT" ] || { NUDGE_DETAIL="no primary endpoint was recorded at session start"; return 1; }
  backend=$(field "$ENDPOINT" backend)
  target=$(field "$ENDPOINT" target)
  [ -n "$backend" ] && [ -n "$target" ] || { NUDGE_DETAIL="the recorded endpoint is incomplete"; return 1; }
  # Test seam, armed only by the suite (tests/lib.sh exports FM_TEST_SEAM).
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_PRIMARY_WATCHDOG_NUDGE_EXEC:-}" ]; then
    verdict=$("$FM_PRIMARY_WATCHDOG_NUDGE_EXEC" "$backend" "$target" "$NUDGE_TEXT" 2>/dev/null) || verdict=failed
  else
    verdict=$(nudge_submit "$backend" "$target") || verdict=failed
  fi
  case "$verdict" in
    sent) NUDGE_DETAIL="nudged $target"; return 0 ;;
    busy) NUDGE_DETAIL="$target reports a turn in progress" ;;
    composer) NUDGE_DETAIL="the composer in $target is not provably empty, so nothing was typed over it" ;;
    *) NUDGE_DETAIL="the nudge could not be confirmed in $target"; NUDGE_TRIED=1 ;;
  esac
  return 1
}

# An errored primary: nudge at a bounded spacing, alert once per episode.
handle_errored() {  # <now> <detail>
  local now=$1 detail=$2 since reason nudged alerted summary
  local -a record
  reason=$(field "$EPISODE" reason)
  since=$(field "$EPISODE" since)
  nudged=$(field "$EPISODE" nudged_at)
  alerted=$(field "$EPISODE" alerted_at)
  if [ "$reason" != errored ] || [ -z "$since" ]; then
    since=$now
    nudged=
    alerted=
  fi
  record=("since=$since" "reason=errored")
  case "$nudged" in ''|*[!0-9]*) nudged= ;; esac
  if [ -z "$nudged" ] || [ $((now - nudged)) -ge "$NUDGE_SECS" ]; then
    if nudge_primary; then
      record+=("nudged_at=$now")
      [ -z "$alerted" ] || record+=("alerted_at=$alerted")
      write_record "$EPISODE" "${record[@]}"
      say errored nudged "$NUDGE_DETAIL; $detail"
      return 0
    fi
    [ -z "$NUDGE_TRIED" ] || nudged=$now
    summary="firstmate in $FM_HOME stopped on an API error $((ERROR_AGE / 60))m ago and could not be nudged: $NUDGE_DETAIL"
  else
    summary="firstmate in $FM_HOME is still stopped on an API error $(( (now - nudged) / 60 ))m after a nudge; the next nudge follows within $(( (NUDGE_SECS - (now - nudged)) / 60 + 1 ))m"
  fi
  [ -z "$nudged" ] || record+=("nudged_at=$nudged")
  if [ -n "$alerted" ]; then
    write_record "$EPISODE" "${record[@]}" "alerted_at=$alerted"
    say errored quiet "already alerted for this episode; $detail"
    return 0
  fi
  alert "$summary"
  write_record "$EPISODE" "${record[@]}" "alerted_at=$now"
  say errored alerted "$summary"
}

acquire_run_lock() {
  local m
  if mkdir "$RUN_LOCK" 2>/dev/null; then
    return 0
  fi
  m=$(mtime "$RUN_LOCK")
  if [ -n "$m" ] && [ $(( $(date +%s) - m )) -ge "$RUN_LOCK_STALE_SECS" ]; then
    rmdir "$RUN_LOCK" 2>/dev/null || true
    mkdir "$RUN_LOCK" 2>/dev/null && return 0
  fi
  return 1
}

cmd_check() {
  local now since reason restart_at result alerted last summary detail
  [ "$#" -eq 0 ] || die "usage: fm-primary-watchdog.sh check"
  if fm_root_is_secondmate_home "$FM_HOME"; then
    say skipped none "secondmate homes are recovered by their parent"
    return 0
  fi
  [ -d "$STATE" ] || { say uncertain none "no state directory at $STATE"; return 0; }
  acquire_run_lock || { say uncertain none "another watchdog run is in progress"; return 0; }
  trap 'rmdir "$RUN_LOCK" 2>/dev/null || true' EXIT
  now=$(date +%s)
  observe "$now"
  classify
  detail="lock=$LOCK_STATE oldest-note-age=${OLDEST_NOTE_AGE:-none} activity-age=$ACTIVITY_AGE"
  [ -z "$ERROR_AGE" ] || detail="$detail error-age=$ERROR_AGE watcher-beat-age=$BEAT_AGE"

  case "$VERDICT" in
    errored) handle_errored "$now" "$detail"; return 0 ;;
    alive)
      # A nudged turn that the API refused again, or has not answered yet, is
      # still the same stop: the episode stays open until an assistant turn
      # entry that is not an API error appears.
      if [ -n "$ERROR_AGE$ERROR_PENDING" ] && [ "$(field "$EPISODE" reason)" = errored ]; then
        if [ -n "$ERROR_AGE" ]; then
          say errored wait "the newest turn entry is still an API error, ${ERROR_AGE}s old; $detail"
        else
          say errored wait "a prompt after the API error has no answer yet; $detail"
        fi
        return 0
      fi
      if [ -f "$EPISODE" ]; then
        rm -f "$EPISODE"
        say alive recovered "$detail"
      else
        say alive none "$detail"
      fi
      return 0
      ;;
    uncertain) say uncertain none "$detail"; return 0 ;;
  esac

  reason=$(field "$EPISODE" reason)
  since=$(field "$EPISODE" since)
  if [ "$reason" != "$VERDICT" ] || [ -z "$since" ]; then
    since=$now
    reason=$VERDICT
    write_record "$EPISODE" "since=$since" "reason=$reason"
  fi
  restart_at=$(field "$EPISODE" restart_at)
  result=$(field "$EPISODE" restart_result)
  alerted=$(field "$EPISODE" alerted_at)

  if [ -n "$restart_at" ]; then
    if [ -n "$alerted" ]; then
      say "$VERDICT" quiet "already alerted for this episode; $detail"
      return 0
    fi
    summary="firstmate in $FM_HOME is still $VERDICT after a restart at $(date -u -d "@$restart_at" +%H:%MZ 2>/dev/null || printf '%s' "$restart_at") (result: $result)"
    alert "$summary"
    write_record "$EPISODE" "since=$since" "reason=$reason" "restart_at=$restart_at" "restart_result=$result" "alerted_at=$now"
    say "$VERDICT" alerted "$summary"
    return 0
  fi

  if [ "$VERDICT" = dead ] && [ $((now - since)) -lt "$DEAD_GRACE_SECS" ]; then
    say dead wait "ended $((now - since))s ago, grace ${DEAD_GRACE_SECS}s; $detail"
    return 0
  fi

  if [ "$VERDICT" = stalled ]; then
    result=refused
    summary="firstmate in $FM_HOME has left an inbox note unhandled for $((OLDEST_NOTE_AGE / 60))m with no turn activity for $((ACTIVITY_AGE / 60))m; its session is still running, so it was not restarted"
  else
    last=$(head -n 1 "$LAST_RESTART" 2>/dev/null || true)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$COOLDOWN_SECS" ]; then
      result=cooldown
      summary="firstmate in $FM_HOME went down again $(( (now - last) / 60 ))m after a restart; not restarting again within the ${COOLDOWN_SECS}s cooldown"
    else
      write_record "$LAST_RESTART" "$now"
      write_record "$EPISODE" "since=$since" "reason=$reason" "restart_at=$now" "restart_result=attempting"
      if restart_primary; then
        write_record "$EPISODE" "since=$since" "reason=$reason" "restart_at=$now" "restart_result=ok"
        say dead restarted "$RESTART_DETAIL"
        return 0
      fi
      result=failed
      summary="firstmate in $FM_HOME is down and the restart failed: $RESTART_DETAIL"
    fi
  fi
  alert "$summary"
  write_record "$EPISODE" "since=$since" "reason=$reason" "restart_at=$now" "restart_result=$result" "alerted_at=$now"
  if [ "$result" = failed ]; then
    say "$VERDICT" restart-failed "$summary"
  else
    say "$VERDICT" alerted "$summary"
  fi
}

case "${1:-}" in
  record) shift; cmd_record "$@" ;;
  check) shift; cmd_check "$@" ;;
  -h|--help|help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *) die "usage: fm-primary-watchdog.sh record [--pid <pid>] | check" ;;
esac
