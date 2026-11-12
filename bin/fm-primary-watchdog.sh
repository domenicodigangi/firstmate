#!/usr/bin/env bash
# fm-primary-watchdog.sh - notice, from outside firstmate's own session, that the
# primary has stopped, restart it, and alert the captain once when it cannot.
#
# Usage:
#   fm-primary-watchdog.sh record [--pid <harness-pid>]
#   fm-primary-watchdog.sh check [--dry-run]
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
#             Turn activity is the newest of state/.claude-autoarm-epoch (every
#             Claude primary turn end), state/inbox/handled (every note
#             acknowledgement), and state/.session-start-complete.
#   alive     neither; a note waiting behind recent activity is a slow answer.
#   uncertain the lock state cannot be classified; nothing is done.
#   skipped   this is a secondmate home, which its parent recovers.
# Worker state is never read, so one slow worker can never trigger it.
#
# Episodes. A dead or stalled verdict opens an episode in state/.primary-watchdog;
# the next alive verdict closes it. Within one episode:
#   - a dead primary waits FM_PRIMARY_WATCHDOG_DEAD_GRACE_SECS, then gets at
#     most ONE restart attempt, and none while a previous restart is inside
#     FM_PRIMARY_WATCHDOG_COOLDOWN_SECS (state/.primary-watchdog-last-restart);
#   - a stalled primary is never restarted: its harness still runs and the
#     watchdog never kills a live session, so a stall alerts instead;
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
# `check --dry-run` prints the verdict and the action it would take, and
# changes nothing. Overlapping runs are skipped through the
# state/.primary-watchdog.lock directory.
#
# Environment:
#   FM_HOME                              operational home (default: code root)
#   FM_STATE_OVERRIDE                    state directory (default: $FM_HOME/state)
#   FM_PRIMARY_WATCHDOG_NOTE_SECS        unhandled-note and inactivity threshold (900)
#   FM_PRIMARY_WATCHDOG_DEAD_GRACE_SECS  wait before restarting an ended session (120)
#   FM_PRIMARY_WATCHDOG_COOLDOWN_SECS    minimum spacing between restarts (1800)
#   FM_PRIMARY_WATCHDOG_VERIFY_SECS      wait for a fresh session after a restart (180)
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
RUN_LOCK_STALE_SECS=900

die() { printf 'fm-primary-watchdog: %s\n' "$*" >&2; exit 2; }
log() { printf 'fm-primary-watchdog: %s\n' "$*" >&2; }

for _v in NOTE_SECS DEAD_GRACE_SECS COOLDOWN_SECS VERIFY_SECS; do
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

# Sets LOCK_STATE, LOCK_PID, OLDEST_NOTE_AGE (empty when none), ACTIVITY_AGE.
observe() {  # <now>
  local now=$1 ready receipts oldest m newest=0 path
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
  for path in "$STATE/.claude-autoarm-epoch" "$STATE/inbox/handled" "$STATE/.session-start-complete"; do
    m=$(mtime "$path")
    [ -n "$m" ] || continue
    [ "$m" -le "$newest" ] || newest=$m
  done
  ACTIVITY_AGE=$((now - newest))
}

classify() {
  case "$LOCK_STATE" in
    free|stale) VERDICT=dead; return ;;
    held) ;;
    *) VERDICT=uncertain; return ;;
  esac
  if [ -n "$OLDEST_NOTE_AGE" ] && [ "$OLDEST_NOTE_AGE" -ge "$NOTE_SECS" ] \
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
  local dry=0 now since reason restart_at result alerted last summary detail
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      *) die "usage: fm-primary-watchdog.sh check [--dry-run]" ;;
    esac
  done
  if fm_root_is_secondmate_home "$FM_HOME"; then
    say skipped none "secondmate homes are recovered by their parent"
    return 0
  fi
  [ -d "$STATE" ] || { say uncertain none "no state directory at $STATE"; return 0; }
  if [ "$dry" -eq 0 ]; then
    acquire_run_lock || { say uncertain none "another watchdog run is in progress"; return 0; }
    trap 'rmdir "$RUN_LOCK" 2>/dev/null || true' EXIT
  fi
  now=$(date +%s)
  observe "$now"
  classify
  detail="lock=$LOCK_STATE oldest-note-age=${OLDEST_NOTE_AGE:-none} activity-age=$ACTIVITY_AGE"

  case "$VERDICT" in
    alive)
      if [ -f "$EPISODE" ]; then
        [ "$dry" -eq 1 ] || rm -f "$EPISODE"
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
    [ "$dry" -eq 1 ] || write_record "$EPISODE" "since=$since" "reason=$reason"
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
    [ "$dry" -eq 1 ] || { alert "$summary"; write_record "$EPISODE" "since=$since" "reason=$reason" "restart_at=$restart_at" "restart_result=$result" "alerted_at=$now"; }
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
    elif [ "$dry" -eq 1 ]; then
      say dead restart "would restart the recorded primary; $detail"
      return 0
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
  if [ "$dry" -eq 1 ]; then
    say "$VERDICT" alert "would alert: $summary"
    return 0
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
  *) die "usage: fm-primary-watchdog.sh record [--pid <pid>] | check [--dry-run]" ;;
esac
