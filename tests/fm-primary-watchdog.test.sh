#!/usr/bin/env bash
# tests/fm-primary-watchdog.test.sh - the out-of-session primary watchdog.
#
# Pins the trigger (alive, slow answer, ended session, stale note, a last turn
# the API refused), the restart paths through a fake Herdr CLI, the nudge of an
# errored primary through a recorder seam, and the once-per-episode alert. Every alert
# routes through the FM_WEDGE_ALARM_EXEC recorder seam, so no case can post a
# real notification, and the fake herdr on PATH answers for a named fake
# session only, so no case can touch a live Herdr server.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCHDOG="$ROOT/bin/fm-primary-watchdog.sh"
TMP_ROOT=$(fm_test_tmproot fm-primary-watchdog)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

reap_holders() {
  local pid pidfile
  for pidfile in "$TMP_ROOT/holder-pids" "$TMP_ROOT"/*/herdr/pids; do
    [ -f "$pidfile" ] || continue
    while IFS= read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$pidfile"
  done
}
trap 'reap_holders; fm_test_cleanup' EXIT

# A live process whose ps comm is the harness name, so lock inspection and
# harness ancestry both classify it as a running primary.
# Callers capture the pid through $(...), so the pid is also kept in a file the
# EXIT trap reaps rather than in this subshell's copy of an array.
start_holder() {  # -> pid
  perl -e '$0="claude"; sleep 600' >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$TMP_ROOT/holder-pids"
  sleep 0.2
  printf '%s\n' "$!"
}

# Fake herdr: answers status, pane get, pane process-info, tab create, and
# pane run from control files in $FAKE_HERDR_DIR, and logs every call.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
dir=${FAKE_HERDR_DIR:?}
printf '%s\n' "$*" >> "$dir/calls"
args=()
session=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) session=$2; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ "$session" = fm-fake ] || { echo "fake herdr: unexpected session '$session'" >&2; exit 9; }
set -- "${args[@]}"
case "$1 ${2:-}" in
  "status --json")
    if [ -e "$dir/server-stopped" ]; then
      printf '{"server":{"running":false}}\n'
    else
      printf '{"server":{"running":true}}\n'
    fi
    ;;
  "pane get")
    if [ -e "$dir/pane-dead" ] && [ "$3" = "w1:p1" ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3"
    ;;
  "pane process-info")
    pane=$4
    if [ -e "$dir/pane-agent" ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_processes":[{"pid":%s,"name":"claude","argv":["claude"]}]}}}\n' \
        "$pane" "$(cat "$dir/shell-pid")" "$(cat "$dir/shell-pid")"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_processes":[{"pid":%s,"name":"bash","argv":["bash"]}]}}}\n' \
        "$pane" "$(cat "$dir/shell-pid")" "$(cat "$dir/shell-pid")"
    fi
    ;;
  "tab create")
    [ ! -e "$dir/tab-create-fails" ] || exit 1
    printf '{"result":{"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9"}}}\n'
    ;;
  "workspace create")
    [ ! -e "$dir/workspace-create-fails" ] || exit 1
    printf '{"result":{"workspace":{"workspace_id":"w2"},"root_pane":{"pane_id":"w2:p1"}}}\n'
    ;;
  "pane run")
    [ ! -e "$dir/run-fails" ] || exit 1
    printf '%s\n' "$4" >> "$dir/run-lines"
    if [ -e "$dir/run-starts-primary" ]; then
      perl -e '$0="claude"; sleep 600' >/dev/null 2>&1 &
      pid=$!
      printf '%s\n' "$pid" >> "$dir/pids"
      sleep 0.2
      printf '%s\n' "$pid" > "$FAKE_STATE/.lock"
      printf '%s\n' "$pid" > "$FAKE_STATE/.session-start-complete"
    fi
    ;;
  *) echo "fake herdr: unhandled $*" >&2; exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/alert-recorder" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "${FAKE_ALERT_LOG:?}"
SH
chmod +x "$FAKEBIN/alert-recorder"

cat > "$FAKEBIN/nudge-recorder" <<'SH'
#!/usr/bin/env bash
# Stands in for the verified submit: records what would be typed and answers
# with the verdict a control file names (default sent).
dir=${FAKE_HERDR_DIR:?}
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$dir/nudges"
if [ -f "$dir/nudge-verdict" ]; then cat "$dir/nudge-verdict"; else printf 'sent\n'; fi
SH
chmod +x "$FAKEBIN/nudge-recorder"

make_home() {  # <name> -> home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state/inbox/handled" "$home/data" "$home/config" "$home/herdr"
  printf 'herdr\n' > "$home/config/wedge-alarm"
  sleep 600 >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$TMP_ROOT/holder-pids"
  printf '%s\n' "$!" > "$home/herdr/shell-pid"
  printf '%s\n' "$home"
}

# A recorded herdr primary endpoint, as `record` writes it at session start.
write_endpoint() {  # <home> <old-harness-pid>
  local home=$1 pid=$2
  cat > "$home/state/.primary-endpoint" <<EOF
schema=fm-primary-endpoint.v1
recorded_at=1
backend=herdr
target=fm-fake:w1:p1
workspace=w1
cwd=$home
harness_pid=$pid
launch=fake-primary --flag
EOF
}

# A pending inbox note whose capture time is <age> seconds ago.
write_note() {  # <home> <age-seconds>
  local home=$1 age=$2 at id
  at=$(python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-int(sys.argv[1]))))' "$age")
  id="$(date +%s)-n$RANDOM"
  printf 'id=%s\nat=%s\nsource=text\nannounce_marker=1\n--\nhello\n' "$id" "$at" > "$home/state/inbox/$id.note"
}

age_path() {  # <age-seconds> <path...>
  local age=$1
  shift
  fm_touch_epoch "$(( $(date +%s) - age ))" "$@"
}

# Mark the primary's last firstmate-owned turn activity <age> seconds ago.
set_activity() {  # <home> <age-seconds>
  local home=$1 age=$2
  printf 'epoch=1 updated_at=1\n' > "$home/state/.claude-autoarm-epoch"
  age_path "$age" "$home/state/.claude-autoarm-epoch" "$home/state/inbox/handled"
  [ ! -e "$home/state/.session-start-complete" ] || age_path "$age" "$home/state/.session-start-complete"
}

# The primary's own session transcript, ending <age> seconds ago in <last>:
#   error      a turn the API refused (Claude Code's synthetic error message)
#   reply      an ordinary finished turn
#   interrupt  the owner stopping the turn
#   resumed    an API error followed by a new prompt (a turn is under way)
write_transcript() {  # <home> <last> <age-seconds>
  local home=$1 last=$2 age=$3 dir
  dir="$home/userhome/.claude/projects/$(printf '%s' "$home" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  printf 'sess-1\n' > "$home/state/.lock-session"
  python3 - "$dir/sess-1.jsonl" "$last" "$age" <<'PY'
import json, sys, time
path, last, age = sys.argv[1], sys.argv[2], int(sys.argv[3])
def at(offset):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - age - offset))
def user(text, offset):
    return {"type": "user", "timestamp": at(offset), "message": {"role": "user", "content": text}}
def reply(offset):
    return {"type": "assistant", "timestamp": at(offset),
            "message": {"role": "assistant", "content": [{"type": "text", "text": "done"}]}}
def error(offset):
    return {"type": "assistant", "timestamp": at(offset), "isApiErrorMessage": True, "apiErrorStatus": 403,
            "error": "authentication_failed",
            "message": {"role": "assistant", "model": "<synthetic>",
                        "content": [{"type": "text", "text": "API Error: 403"}]}}
rows = [user("first", 30), reply(20)]
if last == "error":
    rows += [user("wake", 2), error(0)]
elif last == "interrupt":
    rows += [user("[Request interrupted by user]", 0)]
elif last == "resumed":
    rows += [user("wake", 12), error(10), user("continue", 0)]
elif last != "reply":
    raise SystemExit("unknown transcript ending " + last)
# Bookkeeping rows Claude Code appends between turns must never count as a turn.
rows += [{"type": "system", "subtype": "turn_duration", "timestamp": at(0)}, {"type": "pr-link"}]
with open(path, "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row) + "\n")
PY
}

# Age the watcher's liveness beacon: a fresh one means the watch is armed.
set_watcher_beat() {  # <home> <age-seconds>
  : > "$1/state/.last-watcher-beat"
  age_path "$2" "$1/state/.last-watcher-beat"
}

nudge_count() {  # <home>
  [ -f "$1/herdr/nudges" ] || { printf '0'; return 0; }
  wc -l < "$1/herdr/nudges" | tr -d ' '
}

# A live primary whose session is open but whose last turn the API refused.
make_errored_home() {  # <name> <error-age> -> home
  local home pid
  home=$(make_home "$1")
  pid=$(start_holder)
  printf '%s\n' "$pid" > "$home/state/.lock"
  write_endpoint "$home" "$pid"
  set_activity "$home" "$2"
  set_watcher_beat "$home" "$2"
  write_transcript "$home" error "$2"
  printf '%s\n' "$home"
}

run_check() {  # <home> [extra args...]
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" HOME="$home/userhome" FAKE_HERDR_DIR="$home/herdr" FAKE_STATE="$home/state" \
    FAKE_ALERT_LOG="$home/alerts" FM_WEDGE_ALARM_EXEC="${ALARM_EXEC-$FAKEBIN/alert-recorder}" \
    FM_PRIMARY_WATCHDOG_VERIFY_SECS="${VERIFY_SECS:-3}" \
    FM_PRIMARY_WATCHDOG_DEAD_GRACE_SECS="${DEAD_GRACE:-0}" \
    FM_PRIMARY_WATCHDOG_NUDGE_EXEC="$FAKEBIN/nudge-recorder" \
    "$WATCHDOG" check "$@"
}

alert_count() {  # <home>
  [ -f "$1/alerts" ] || { printf '0'; return 0; }
  wc -l < "$1/alerts" | tr -d ' '
}

run_count() {  # <home>
  [ -f "$1/herdr/run-lines" ] || { printf '0'; return 0; }
  wc -l < "$1/herdr/run-lines" | tr -d ' '
}

test_alive_primary_no_action() {
  local home pid out
  home=$(make_home alive)
  pid=$(start_holder)
  printf '%s\n' "$pid" > "$home/state/.lock"
  write_endpoint "$home" "$pid"
  write_note "$home" 60
  set_activity "$home" 30
  out=$(run_check "$home") || fail "check must succeed for a live primary"
  assert_contains "$out" "verdict=alive" "a live primary with a fresh note is alive"
  assert_contains "$out" "action=none" "a live primary is left alone"
  assert_equals 0 "$(alert_count "$home")" "a live primary raises no alert"
  assert_equals 0 "$(run_count "$home")" "a live primary is never relaunched"
  pass "a live primary with a fresh note triggers nothing"
}

test_slow_answer_no_action() {
  local home pid out
  home=$(make_home slow)
  pid=$(start_holder)
  printf '%s\n' "$pid" > "$home/state/.lock"
  write_endpoint "$home" "$pid"
  write_note "$home" 1800
  set_activity "$home" 60
  out=$(run_check "$home") || fail "check must succeed for a slow answer"
  assert_contains "$out" "verdict=alive" "an old note with recent turn activity is a slow answer, not a stop"
  assert_equals 0 "$(alert_count "$home")" "a slow answer raises no alert"
  # Divergence check: the same home with stale activity is a stall, so the
  # activity signal alone is what kept the verdict alive.
  set_activity "$home" 1800
  out=$(run_check "$home") || fail "check must succeed for a stall"
  assert_contains "$out" "verdict=stalled" "the same note with no recent activity is a stall"
  pass "a single slow answer never triggers the watchdog"
}

test_stale_note_alerts_once_never_kills() {
  local home pid out
  home=$(make_home stalled)
  pid=$(start_holder)
  printf '%s\n' "$pid" > "$home/state/.lock"
  write_endpoint "$home" "$pid"
  write_note "$home" 1800
  set_activity "$home" 1800
  out=$(run_check "$home") || fail "check must succeed for a stalled primary"
  assert_contains "$out" "verdict=stalled" "an unhandled note past the threshold with no activity is a stall"
  assert_contains "$out" "action=alerted" "a stall whose session still runs alerts instead of killing it"
  assert_equals 1 "$(alert_count "$home")" "the stall alerts once"
  assert_equals 0 "$(run_count "$home")" "a live session is never typed into or killed"
  kill -0 "$pid" 2>/dev/null || fail "the live primary process must survive the watchdog"
  assert_present "$home/state/.primary-watchdog-alert" "the alert leaves a durable marker"
  out=$(run_check "$home") || fail "second check must succeed"
  assert_contains "$out" "action=quiet" "the same episode stays quiet after its alert"
  assert_equals 1 "$(alert_count "$home")" "one alert per episode"
  pass "a stale note with a stopped primary alerts once and never kills the session"
}

test_threshold_is_configurable() {
  local home pid out
  home=$(make_home threshold)
  pid=$(start_holder)
  printf '%s\n' "$pid" > "$home/state/.lock"
  write_endpoint "$home" "$pid"
  write_note "$home" 400
  set_activity "$home" 400
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "verdict=alive" "a 400s-old note is under the 15-minute default"
  out=$(FM_PRIMARY_WATCHDOG_NOTE_SECS=300 run_check "$home") || fail "check must succeed"
  assert_contains "$out" "verdict=stalled" "a 300s threshold makes the same note a stall"
  pass "the unhandled-note threshold defaults to 15 minutes and is configurable"
}

test_dead_primary_restarts_in_its_shell() {
  local home out line
  home=$(make_home dead-shell)
  write_endpoint "$home" 999999
  touch "$home/herdr/run-starts-primary"
  out=$(DEAD_GRACE=600 run_check "$home") || fail "check must succeed inside the grace"
  assert_contains "$out" "verdict=dead" "no lock is an ended session"
  assert_contains "$out" "action=wait" "an ended session waits out the grace before acting"
  assert_equals 0 "$(run_count "$home")" "nothing is relaunched inside the grace"
  out=$(run_check "$home") || fail "check must succeed after the grace"
  assert_contains "$out" "action=restarted" "an ended session with a live shell is relaunched"
  line=$(cat "$home/herdr/run-lines")
  assert_contains "$line" "fake-primary --flag" "the recorded launch command is sent"
  assert_contains "$line" "cd -- " "the relaunch starts from the recorded directory"
  assert_grep "pane run w1:p1" "$home/herdr/calls" "the recorded pane receives the relaunch"
  assert_equals 0 "$(alert_count "$home")" "a successful restart raises no alert"
  out=$(run_check "$home") || fail "check after restart must succeed"
  assert_contains "$out" "verdict=alive" "the relaunched session is alive"
  assert_absent "$home/state/.primary-watchdog" "a recovered primary ends the episode"
  pass "an ended primary is relaunched in its recorded pane and verified"
}

test_dead_pane_opens_new_tab() {
  local home out
  home=$(make_home dead-pane)
  write_endpoint "$home" 999999
  touch "$home/herdr/pane-dead" "$home/herdr/run-starts-primary"
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=restarted" "a gone pane gets a new tab"
  assert_grep "tab create --workspace w1" "$home/herdr/calls" "a new tab opens in the recorded workspace"
  assert_grep "pane run w1:p9" "$home/herdr/calls" "the new tab receives the relaunch"
  pass "an ended primary whose pane is gone is relaunched in a new tab"
}

test_dead_workspace_opens_new_workspace() {
  local home out
  home=$(make_home dead-workspace)
  write_endpoint "$home" 999999
  touch "$home/herdr/pane-dead" "$home/herdr/tab-create-fails" "$home/herdr/run-starts-primary"
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=restarted" "a gone workspace gets a new workspace"
  assert_grep "workspace create --cwd $home --label firstmate" "$home/herdr/calls" "a new workspace opens in the recorded directory"
  assert_grep "pane run w2:p1" "$home/herdr/calls" "the new workspace receives the relaunch"
  touch "$home/herdr/workspace-create-fails"
  rm -f "$home/state/.lock" "$home/state/.primary-watchdog"
  out=$(FM_PRIMARY_WATCHDOG_COOLDOWN_SECS=0 run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=restart-failed" "no tab and no workspace is a failed restart"
  pass "an ended primary whose workspace is gone is relaunched in a new workspace"
}

test_failed_restart_alerts_once() {
  local home out
  home=$(make_home restart-fails)
  write_endpoint "$home" 999999
  touch "$home/herdr/run-fails"
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=restart-failed" "a failed relaunch is reported"
  assert_equals 1 "$(alert_count "$home")" "a failed restart alerts the owner"
  assert_grep "herdr|" "$home/alerts" "the configured herdr channel carries the alert"
  out=$(run_check "$home") || fail "second check must succeed"
  assert_contains "$out" "action=quiet" "the episode stays quiet"
  assert_equals 1 "$(alert_count "$home")" "a failed restart alerts once per episode"
  assert_equals 1 "$(grep -c 'pane run' "$home/herdr/calls")" "at most one restart attempt per episode"
  pass "a failed restart alerts once and is not retried within the episode"
}

test_unverified_restart_alerts() {
  local home out
  home=$(make_home unverified)
  write_endpoint "$home" 999999
  out=$(VERIFY_SECS=1 run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=restart-failed" "a relaunch that never produces a fresh session failed"
  assert_equals 1 "$(alert_count "$home")" "an unverified restart alerts"
  pass "a restart counts only when a fresh lock and completed startup appear"
}

test_live_agent_in_pane_refused() {
  local home out
  home=$(make_home pane-agent)
  write_endpoint "$home" 999999
  touch "$home/herdr/pane-agent"
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=restart-failed" "a pane still running a harness is not typed into"
  assert_equals 0 "$(run_count "$home")" "nothing is typed into an agent pane"
  assert_equals 1 "$(alert_count "$home")" "the refusal alerts"
  pass "a pane that still runs a harness is never typed into"
}

test_non_herdr_backend_refuses_and_alerts() {
  local home out
  home=$(make_home tmux)
  write_endpoint "$home" 999999
  sed -i.bak 's/^backend=herdr$/backend=tmux/' "$home/state/.primary-endpoint"
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=restart-failed" "an unsupported backend refuses the restart"
  assert_equals 1 "$(alert_count "$home")" "an unsupported backend alerts"
  [ ! -f "$home/herdr/calls" ] || assert_no_grep "pane run" "$home/herdr/calls" "an unsupported backend is never typed into"
  pass "a non-herdr primary refuses the restart and alerts"
}

test_missing_endpoint_alerts() {
  local home out
  home=$(make_home no-endpoint)
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=restart-failed" "no recorded endpoint cannot be restarted"
  assert_equals 1 "$(alert_count "$home")" "a missing endpoint alerts"
  pass "a home with no recorded primary endpoint alerts instead of guessing"
}

test_cooldown_blocks_restart_loop() {
  local home out
  home=$(make_home cooldown)
  write_endpoint "$home" 999999
  touch "$home/herdr/run-starts-primary"
  out=$(run_check "$home") || fail "first check must succeed"
  assert_contains "$out" "action=restarted" "the first episode restarts"
  out=$(run_check "$home") || fail "alive check must succeed"
  assert_contains "$out" "verdict=alive" "the relaunched primary is alive"
  # The relaunched primary dies again right away.
  rm -f "$home/state/.lock"
  out=$(run_check "$home") || fail "relapse check must succeed"
  assert_contains "$out" "action=alerted" "a relapse inside the cooldown alerts instead of restarting"
  assert_equals 1 "$(run_count "$home")" "no second restart inside the cooldown"
  assert_equals 1 "$(alert_count "$home")" "the relapse alerts once"
  out=$(FM_PRIMARY_WATCHDOG_COOLDOWN_SECS=0 run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=quiet" "the relapse episode stays quiet"
  pass "a restart loop is held by the cooldown and alerts once"
}

test_new_episode_after_recovery() {
  local home pid out
  home=$(make_home episodes)
  pid=$(start_holder)
  printf '%s\n' "$pid" > "$home/state/.lock"
  write_endpoint "$home" "$pid"
  write_note "$home" 1800
  set_activity "$home" 1800
  run_check "$home" >/dev/null || fail "stall check must succeed"
  assert_equals 1 "$(alert_count "$home")" "the first stall alerts"
  rm -f "$home/state/inbox/"*.note
  out=$(run_check "$home") || fail "recovery check must succeed"
  assert_contains "$out" "verdict=alive" "an acknowledged note ends the stall"
  write_note "$home" 1800
  set_activity "$home" 1800
  run_check "$home" >/dev/null || fail "second stall check must succeed"
  assert_equals 2 "$(alert_count "$home")" "a later, separate stall is a new episode"
  pass "recovery ends an episode so a later stop alerts again"
}

test_rex_channel_records_alert_once() {
  local home pid out rc
  home=$(make_home rex-channel)
  pid=$(start_holder)
  printf '%s\n' "$pid" > "$home/state/.lock"
  write_endpoint "$home" "$pid"
  write_note "$home" 1800
  set_activity "$home" 1800
  # shellcheck disable=SC2016 # literal $1 is the alarm command's argument, expanded later by the channel
  printf 'command:printf "%%s\\n" "$1" >> %s/alerts\nrex\n' "$home" > "$home/config/wedge-alarm"
  out=$(unset FM_SUPERVISOR_BACKEND FM_SUPERVISOR_TARGET; ALARM_EXEC='' run_check "$home" 2>/dev/null)
  rc=$?
  assert_equals 0 "$rc" "a rex directive must not abort the check"
  assert_contains "$out" "action=alerted" "the stall alerts through the configured channels"
  assert_grep "alerted_at=" "$home/state/.primary-watchdog" "the alert is recorded for the episode"
  assert_equals 1 "$(alert_count "$home")" "the command channel before rex fires once"
  out=$(unset FM_SUPERVISOR_BACKEND FM_SUPERVISOR_TARGET; ALARM_EXEC='' run_check "$home" 2>/dev/null) \
    || fail "second check must succeed"
  assert_contains "$out" "action=quiet" "the recorded alert keeps the episode quiet"
  assert_equals 1 "$(alert_count "$home")" "a rex directive still alerts only once"
  pass "a rex directive in config/wedge-alarm still records the alert once"
}

test_long_turn_transcript_keeps_alive() {
  local home pid out dir
  home=$(make_home long_turn)
  pid=$(start_holder)
  printf '%s\n' "$pid" > "$home/state/.lock"
  write_endpoint "$home" "$pid"
  write_note "$home" 1800
  set_activity "$home" 1800
  dir="$home/userhome/.claude/projects/$(printf '%s' "$home" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  printf 'sess-1\n' > "$home/state/.lock-session"
  printf '{}\n' > "$dir/sess-1.jsonl"
  printf '{}\n' > "$dir/other.jsonl"
  age_path 1800 "$dir/other.jsonl"
  out=$(run_check "$home") || fail "check must succeed during a long turn"
  assert_contains "$out" "verdict=alive" "a transcript still growing is turn activity"
  assert_equals 0 "$(alert_count "$home")" "a long working turn raises no alert"
  age_path 1800 "$dir/sess-1.jsonl"
  fm_touch_epoch "$(date +%s)" "$dir/other.jsonl"
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "verdict=stalled" "another session's transcript is not the primary's activity"
  rm -f "$home/state/.lock-session" "$home/state/.primary-watchdog"
  out=$(run_check "$home") || fail "check must succeed without a recorded session id"
  assert_contains "$out" "verdict=alive" "with no recorded id the newest transcript for the cwd counts"
  pass "a long working turn whose transcript is fresh is never a stall"
}

test_errored_turn_is_nudged() {
  local home out line
  home=$(make_errored_home errored 1800)
  out=$(run_check "$home") || fail "check must succeed for a primary stopped on an API error"
  assert_contains "$out" "verdict=errored" "an open session whose last turn the API refused, with no watch armed, is errored"
  assert_contains "$out" "action=nudged" "an errored primary is nudged without any inbox note waiting"
  assert_equals 1 "$(nudge_count "$home")" "exactly one nudge is typed"
  line=$(cat "$home/herdr/nudges")
  assert_contains "$line" "herdr|fm-fake:w1:p1|" "the nudge goes to the recorded primary endpoint"
  assert_contains "$line" "bin/fm-wake-drain.sh" "the nudge tells firstmate to drain its wake queue"
  assert_equals 0 "$(alert_count "$home")" "a nudge that was sent raises no alert"
  assert_equals 0 "$(run_count "$home")" "an open session is never relaunched"
  pass "a primary stopped on an API error is nudged once through its recorded endpoint"
}

test_errored_recovers_after_nudge() {
  local home out
  home=$(make_errored_home errored-recovers 1800)
  run_check "$home" >/dev/null || fail "nudge check must succeed"
  write_transcript "$home" reply 5
  out=$(run_check "$home") || fail "recovery check must succeed"
  assert_contains "$out" "verdict=alive" "a finished turn after the nudge ends the stop"
  assert_contains "$out" "action=recovered" "the episode is reported as recovered"
  assert_absent "$home/state/.primary-watchdog" "recovery ends the errored episode"
  assert_equals 1 "$(nudge_count "$home")" "a recovered primary is not nudged again"
  assert_equals 0 "$(alert_count "$home")" "a nudge that worked never alerts"
  pass "a nudge that restarts the primary closes the episode without an alert"
}

test_errored_still_failing_alerts_once_and_retries() {
  local home out
  home=$(make_errored_home errored-persists 1800)
  run_check "$home" >/dev/null || fail "nudge check must succeed"
  # The nudged turn failed too: the newest entry is a fresh API error.
  write_transcript "$home" error 30
  out=$(run_check "$home") || fail "check must succeed inside the error grace"
  assert_contains "$out" "verdict=errored" "a fresh failure keeps the open episode"
  assert_contains "$out" "action=wait" "a failure younger than the grace is left to settle"
  assert_present "$home/state/.primary-watchdog" "a repeated failure does not close the episode"
  assert_equals 1 "$(nudge_count "$home")" "no second nudge right after a failed one"
  write_transcript "$home" error 1800
  out=$(run_check "$home") || fail "check must succeed for a repeated failure"
  assert_contains "$out" "action=alerted" "a primary still failing after its nudge alerts the owner"
  assert_equals 1 "$(alert_count "$home")" "the repeated failure alerts once"
  assert_equals 1 "$(nudge_count "$home")" "the next nudge waits out the spacing"
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=quiet" "the episode stays quiet between nudges"
  out=$(FM_PRIMARY_WATCHDOG_NUDGE_SECS=0 run_check "$home") || fail "retry check must succeed"
  assert_contains "$out" "action=nudged" "a long outage is nudged again once the spacing has passed"
  assert_equals 2 "$(nudge_count "$home")" "the retry types one more nudge"
  assert_equals 1 "$(alert_count "$home")" "one alert per episode however many nudges"
  pass "a primary that keeps failing alerts once and is nudged again at a bounded spacing"
}

test_unanswered_nudge_keeps_episode() {
  local home out
  home=$(make_errored_home errored-retrying 1800)
  run_check "$home" >/dev/null || fail "nudge check must succeed"
  # The nudge's own prompt is the newest entry while the API keeps retrying.
  write_transcript "$home" resumed 400
  out=$(run_check "$home") || fail "check must succeed while the nudge is unanswered"
  assert_contains "$out" "verdict=errored" "an unanswered nudge keeps the errored episode"
  assert_contains "$out" "action=wait" "an unanswered nudge is waited on"
  assert_present "$home/state/.primary-watchdog" "an unanswered nudge does not close the episode"
  # The retried turn finally fails.
  write_transcript "$home" error 1800
  out=$(run_check "$home") || fail "check must succeed for the late failure"
  assert_contains "$out" "action=alerted" "a late failure after the nudge alerts the owner"
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=quiet" "the late failure alerts only once"
  assert_equals 1 "$(nudge_count "$home")" "no second nudge inside the spacing"
  assert_equals 1 "$(alert_count "$home")" "one alert per episode"
  pass "the nudge's own unanswered prompt neither closes the episode nor resets its spacing"
}

test_unconfirmed_nudge_counts_as_attempt() {
  local home out
  home=$(make_errored_home errored-unconfirmed 1800)
  printf 'failed\n' > "$home/herdr/nudge-verdict"
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=alerted" "an unconfirmed nudge alerts"
  out=$(run_check "$home") || fail "second check must succeed"
  assert_contains "$out" "action=quiet" "an unconfirmed nudge is not retyped inside the spacing"
  assert_equals 1 "$(nudge_count "$home")" "an unconfirmed nudge counts as the attempt"
  pass "a nudge typed but not confirmed waits out the spacing like a sent one"
}

test_fresh_error_is_left_to_settle() {
  local home out
  home=$(make_errored_home errored-fresh 60)
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "verdict=alive" "an error younger than the grace is not yet a stop"
  assert_equals 0 "$(nudge_count "$home")" "a fresh error is not nudged"
  out=$(FM_PRIMARY_WATCHDOG_ERROR_SECS=30 run_check "$home") || fail "check must succeed"
  assert_contains "$out" "verdict=errored" "the error grace is configurable"
  pass "an API error is nudged only after the grace, which is configurable"
}

test_error_with_armed_watch_left_alone() {
  local home out
  home=$(make_errored_home errored-armed 1800)
  set_watcher_beat "$home" 20
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "verdict=alive" "a live watcher will wake the primary by itself"
  assert_equals 0 "$(nudge_count "$home")" "a primary whose watch is armed is never typed into"
  pass "an old API error behind an armed watch is not a stop"
}

test_only_an_api_error_is_nudged() {
  local home out ending
  home=$(make_errored_home errored-other 1800)
  for ending in reply interrupt resumed; do
    write_transcript "$home" "$ending" 1800
    out=$(run_check "$home") || fail "check must succeed for a transcript ending in $ending"
    assert_contains "$out" "verdict=alive" "a session ending in $ending is not errored"
  done
  assert_equals 0 "$(nudge_count "$home")" "a finished turn, an owner interrupt, and a resumed turn are never typed into"
  assert_equals 0 "$(alert_count "$home")" "none of them alerts without a waiting note"
  pass "only a last turn the API refused counts as errored; an owner stop is respected"
}

test_unsendable_nudge_alerts_once() {
  local home out
  home=$(make_errored_home errored-composer 1800)
  printf 'composer\n' > "$home/herdr/nudge-verdict"
  out=$(run_check "$home") || fail "check must succeed"
  assert_contains "$out" "action=alerted" "a nudge that cannot be typed alerts instead"
  assert_contains "$(cat "$home/alerts")" "composer" "the alert says why nothing was typed"
  assert_equals 1 "$(alert_count "$home")" "the refusal alerts once"
  out=$(FM_PRIMARY_WATCHDOG_NUDGE_SECS=0 run_check "$home") || fail "second check must succeed"
  assert_contains "$out" "action=quiet" "a repeated refusal stays quiet"
  assert_equals 1 "$(alert_count "$home")" "one alert per episode"
  rm -f "$home/state/.primary-watchdog" "$home/herdr/nudges"
  sed -i.bak '/^target=/d' "$home/state/.primary-endpoint"
  out=$(run_check "$home") || fail "check must succeed with an incomplete endpoint"
  assert_contains "$out" "action=alerted" "an endpoint with no pane target cannot be nudged"
  assert_equals 0 "$(nudge_count "$home")" "nothing is typed without a recorded pane target"
  pass "a nudge that cannot be delivered alerts once and types nothing over the owner"
}

test_secondmate_home_skipped() {
  local home out
  home=$(make_home secondmate)
  printf 'sm-one\n' > "$home/.fm-secondmate-home"
  write_endpoint "$home" 999999
  touch "$home/herdr/run-starts-primary"
  out=$(run_check "$home") || fail "check must succeed in a secondmate home"
  assert_contains "$out" "verdict=skipped" "a secondmate home belongs to its parent's recovery"
  assert_equals 0 "$(run_count "$home")" "a secondmate home is never relaunched by the watchdog"
  pass "the watchdog leaves secondmate homes to their parent"
}

test_record_writes_endpoint() {
  local home pid out rec standin
  home=$(make_home record)
  pid=$(start_holder)
  printf '%s\n' "$pid" > "$home/state/.lock"
  out=$(FM_HOME="$home" HERDR_ENV=1 HERDR_PANE_ID=w5:p2 HERDR_WORKSPACE_ID=w5 HERDR_SESSION=fm-fake \
    TMUX_PANE='' FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' "$WATCHDOG" record) \
    || fail "record must succeed: $out"
  rec="$home/state/.primary-endpoint"
  assert_present "$rec" "record writes the endpoint file"
  assert_equals herdr "$(sed -n 's/^backend=//p' "$rec")" "the backend is recorded"
  assert_equals fm-fake:w5:p2 "$(sed -n 's/^target=//p' "$rec")" "the pane target is recorded"
  assert_equals w5 "$(sed -n 's/^workspace=//p' "$rec")" "the workspace is recorded"
  assert_equals "$pid" "$(sed -n 's/^harness_pid=//p' "$rec")" "the lock-holder pid is recorded"
  assert_equals claude "$(sed -n 's/^launch=//p' "$rec")" "the harness command line is recorded"
  assert_contains "$(sed -n 's/^cwd=//p' "$rec")" "/" "the working directory is recorded"
  # Perl's $0 rewrite clobbers /proc/<pid>/environ, so this holder is a real
  # executable reached through a harness-named link.
  standin=$(fm_agent_standin "$TMP_ROOT/standin") || fail "no harness stand-in could be built"
  ln -sf "$standin" "$TMP_ROOT/standin/claude"
  env FM_HOME=/some/home "$TMP_ROOT/standin/claude" 600 >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >> "$TMP_ROOT/holder-pids"
  sleep 0.2
  printf '%s\n' "$pid" > "$home/state/.lock"
  FM_HOME="$home" HERDR_ENV=1 HERDR_PANE_ID=w5:p2 HERDR_WORKSPACE_ID=w5 HERDR_SESSION=fm-fake \
    TMUX_PANE='' FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' "$WATCHDOG" record >/dev/null \
    || fail "record must succeed for a primary with an explicit home"
  assert_equals "FM_HOME=/some/home $TMP_ROOT/standin/claude 600" "$(sed -n 's/^launch=//p' "$rec")" \
    "an explicit FM_HOME in the primary's environment is kept for the relaunch"
  pass "record captures the primary's backend, pane, launch command, and directory"
}

fm_test_run \
  test_alive_primary_no_action \
  test_slow_answer_no_action \
  test_stale_note_alerts_once_never_kills \
  test_threshold_is_configurable \
  test_dead_primary_restarts_in_its_shell \
  test_dead_pane_opens_new_tab \
  test_dead_workspace_opens_new_workspace \
  test_failed_restart_alerts_once \
  test_unverified_restart_alerts \
  test_live_agent_in_pane_refused \
  test_non_herdr_backend_refuses_and_alerts \
  test_missing_endpoint_alerts \
  test_cooldown_blocks_restart_loop \
  test_new_episode_after_recovery \
  test_rex_channel_records_alert_once \
  test_long_turn_transcript_keeps_alive \
  test_errored_turn_is_nudged \
  test_errored_recovers_after_nudge \
  test_errored_still_failing_alerts_once_and_retries \
  test_unanswered_nudge_keeps_episode \
  test_unconfirmed_nudge_counts_as_attempt \
  test_fresh_error_is_left_to_settle \
  test_error_with_armed_watch_left_alone \
  test_only_an_api_error_is_nudged \
  test_unsendable_nudge_alerts_once \
  test_secondmate_home_skipped \
  test_record_writes_endpoint
