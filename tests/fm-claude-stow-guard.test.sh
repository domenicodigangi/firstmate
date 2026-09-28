#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-stow-guard.sh, the Claude stow-then-
# compact guard (docs/configuration.md "Stow before compaction").
# Hermetic: each case builds a primary-shaped checkout and a synthetic Claude
# transcript, then feeds the hook a Stop or PreCompact payload. No real agent
# session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stow-guard)
fm_git_identity fmtest fmtest@example.invalid
GUARD="$ROOT/bin/fm-claude-stow-guard.sh"

# Isolate the compaction-window lookup from the host's own Claude settings.
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/bin" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

SEQ=0
next_uuid() {
  SEQ=$((SEQ + 1))
  printf '00000000-0000-4000-8000-%012d\n' "$SEQ"
}

# Append a main-chain (or sidechain) assistant entry whose usage sums to $2.
add_usage() {  # <transcript> <tokens> [sidechain]
  local side=false
  [ "${3:-}" = sidechain ] && side=true
  jq -cn --arg u "$(next_uuid)" --argjson t "$2" --argjson s "$side" '{
    type: "assistant", isSidechain: $s, uuid: $u,
    message: {role: "assistant", content: [{type: "text", text: "ok"}],
      usage: {input_tokens: 2, cache_creation_input_tokens: 100,
        cache_read_input_tokens: ($t - 102), output_tokens: 40}}}' >> "$1"
}

# A synthetic main-chain assistant entry whose usage is all zero.
add_zero_usage() {  # <transcript>
  jq -cn --arg u "$(next_uuid)" '{type: "assistant", isSidechain: false, uuid: $u,
    message: {role: "assistant", model: "<synthetic>", content: [{type: "text", text: "No response requested."}],
      usage: {input_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0}}}' >> "$1"
}

add_typed_stow() {  # <transcript>
  jq -cn --arg u "$(next_uuid)" '{type: "user", isSidechain: false, uuid: $u,
    message: {role: "user", content: "<command-message>stow</command-message>\n<command-name>/stow</command-name>"}}' >> "$1"
}

add_skill_stow() {  # <transcript>
  jq -cn --arg u "$(next_uuid)" '{type: "assistant", isSidechain: false, uuid: $u,
    message: {role: "assistant", content: [{type: "tool_use", id: "toolu_1", name: "Skill", input: {skill: "stow"}}],
      usage: {input_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0}}}' >> "$1"
}

# A tool result that merely quotes a stow invocation, which must not count.
add_quoted_stow() {  # <transcript>
  jq -cn --arg u "$(next_uuid)" '{type: "user", isSidechain: false, uuid: $u,
    message: {role: "user", content: [{type: "tool_result", tool_use_id: "toolu_2",
      content: "<command-name>/stow</command-name> and \"skill\":\"stow\""}]}}' >> "$1"
}

add_boundary() {  # <transcript> <trigger> <preTokens>
  jq -cn --arg u "$(next_uuid)" --arg tr "$2" --argjson p "$3" '{type: "system", subtype: "compact_boundary",
    uuid: $u, isSidechain: false, compactMetadata: {trigger: $tr, preTokens: $p}}' >> "$1"
}

HOOK_RC=
HOOK_OUT=
HOOK_ERR=
run_guard() {  # <dir> <mode> <transcript> [trigger] [session]
  local dir=$1 mode=$2 transcript=$3 trigger=${4:-} session=${5:-sess-1} payload
  payload=$(jq -cn --arg t "$transcript" --arg s "$session" --arg tr "$trigger" --arg m "$mode" '
    {session_id: $s, transcript_path: $t, cwd: "/x"}
    + (if $m == "precompact" then {hook_event_name: "PreCompact", trigger: $tr, custom_instructions: null}
       else {hook_event_name: "Stop", stop_hook_active: false} end)')
  HOOK_RC=0
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$dir" "$GUARD" "--$mode" \
    > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || HOOK_RC=$?
  HOOK_OUT=$(cat "$TMP_ROOT/out")
  HOOK_ERR=$(cat "$TMP_ROOT/err")
}

expect_allow() {  # <label>
  [ "$HOOK_RC" -eq 0 ] || fail "$1: expected exit 0, got $HOOK_RC (stderr: $HOOK_ERR)"
  [ -z "$HOOK_OUT" ] || fail "$1: allow must print nothing on stdout, got: $HOOK_OUT"
  [ -z "$HOOK_ERR" ] || fail "$1: allow must print nothing on stderr, got: $HOOK_ERR"
}

expect_block() {  # <label> <stderr substring>
  [ "$HOOK_RC" -eq 2 ] || fail "$1: expected exit 2, got $HOOK_RC (stderr: $HOOK_ERR)"
  [ -z "$HOOK_OUT" ] || fail "$1: block must keep stdout empty, got: $HOOK_OUT"
  case "$HOOK_ERR" in
    *"$2"*) : ;;
    *) fail "$1: stderr lacks '$2': $HOOK_ERR" ;;
  esac
}

test_stop_below_threshold_allows() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/below")
  t="$dir/t.jsonl"
  add_usage "$t" 299999
  run_guard "$dir" stop "$t"
  expect_allow "context below the default threshold"
  pass "stop: context below 300000 tokens ends the turn silently"
}

test_stop_nudges_once_per_cycle() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/once")
  t="$dir/t.jsonl"
  add_usage "$t" 300000
  run_guard "$dir" stop "$t"
  expect_block "first stop past the threshold" "Invoke the stow skill now (/stow)"
  case "$HOOK_ERR" in *"300000 tokens"*) : ;; *) fail "nudge must name the context size: $HOOK_ERR" ;; esac
  add_usage "$t" 305000
  run_guard "$dir" stop "$t"
  expect_allow "second stop in the same cycle"
  pass "stop: the nudge blocks once at the threshold and not again in the same compaction cycle"
}

test_stop_counts_typed_and_skill_stow_only() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/typed")
  t="$dir/t.jsonl"
  add_typed_stow "$t"
  add_usage "$t" 310000
  run_guard "$dir" stop "$t"
  expect_allow "typed /stow in the cycle"

  dir=$(make_primary_dir "$TMP_ROOT/skill")
  t="$dir/t.jsonl"
  add_usage "$t" 280000
  add_skill_stow "$t"
  add_usage "$t" 310000
  run_guard "$dir" stop "$t"
  expect_allow "Skill stow in the cycle"

  dir=$(make_primary_dir "$TMP_ROOT/quoted")
  t="$dir/t.jsonl"
  add_quoted_stow "$t"
  add_usage "$t" 310000
  run_guard "$dir" stop "$t"
  expect_block "quoted stow text only" "/stow"
  pass "stop: a typed /stow or a Skill stow satisfies the cycle, while quoted stow text does not"
}

test_stop_ignores_sidechain_and_zero_usage() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/sidechain")
  t="$dir/t.jsonl"
  add_usage "$t" 100000
  add_usage "$t" 500000 sidechain
  add_zero_usage "$t"
  run_guard "$dir" stop "$t"
  expect_allow "sidechain usage and a zero-usage entry after it"
  add_usage "$t" 300001
  add_zero_usage "$t"
  run_guard "$dir" stop "$t"
  expect_block "main-chain usage behind a zero-usage entry" "300001 tokens"
  pass "stop: context size comes from the newest non-zero main-chain usage only"
}

test_stop_tolerates_partial_last_line() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/partial")
  t="$dir/t.jsonl"
  add_usage "$t" 310000
  printf '{"type":"assistant","message":{"usage":{"input_tok' >> "$t"
  run_guard "$dir" stop "$t"
  expect_block "partial trailing entry" "310000 tokens"
  pass "stop: a partially written trailing entry does not hide the context size"
}

test_stop_new_cycle_after_compaction() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/cycle")
  t="$dir/t.jsonl"
  add_usage "$t" 300000
  run_guard "$dir" stop "$t"
  expect_block "cycle 1 nudge" "/stow"
  add_skill_stow "$t"
  add_usage "$t" 310000
  add_boundary "$t" auto 310500
  run_guard "$dir" stop "$t"
  expect_allow "right after a stowed compaction (pre-compaction usage is not counted)"
  add_usage "$t" 60000
  add_usage "$t" 301000
  run_guard "$dir" stop "$t"
  expect_block "cycle 2 nudge" "301000 tokens"
  pass "stop: each compaction starts a new cycle with its own nudge, and pre-compaction usage is not counted"
}

test_stop_reports_unstowed_compaction_once() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/audit")
  t="$dir/t.jsonl"
  add_usage "$t" 200000
  add_boundary "$t" auto 317500
  add_usage "$t" 40000
  run_guard "$dir" stop "$t"
  expect_block "unstowed compaction" "compacted (trigger auto, at 317500 tokens) with no /stow since the previous compaction"
  run_guard "$dir" stop "$t"
  expect_allow "the same unstowed compaction again"

  dir=$(make_primary_dir "$TMP_ROOT/audit-after-stow")
  t="$dir/t.jsonl"
  add_boundary "$t" manual 300000
  add_typed_stow "$t"
  add_usage "$t" 40000
  run_guard "$dir" stop "$t"
  expect_allow "unstowed compaction followed by a stow"
  pass "stop: a compaction with no stow since the previous one is reported once, unless a stow already followed it"
}

test_threshold_config() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/cfg-off")
  t="$dir/t.jsonl"
  printf 'off\n' > "$dir/config/claude-stow-threshold"
  add_usage "$t" 400000
  run_guard "$dir" stop "$t"
  expect_allow "threshold off"
  run_guard "$dir" precompact "$t" manual
  expect_allow "threshold off, manual compaction"

  dir=$(make_primary_dir "$TMP_ROOT/cfg-custom")
  t="$dir/t.jsonl"
  printf '150000\n' > "$dir/config/claude-stow-threshold"
  add_usage "$t" 150000
  run_guard "$dir" stop "$t"
  expect_block "custom threshold" "past the 150000-token stow threshold"

  dir=$(make_primary_dir "$TMP_ROOT/cfg-bad")
  t="$dir/t.jsonl"
  printf 'lots\n' > "$dir/config/claude-stow-threshold"
  add_usage "$t" 250000
  run_guard "$dir" stop "$t"
  expect_allow "malformed threshold falls back to the default (below it)"
  add_usage "$t" 300000
  run_guard "$dir" stop "$t"
  expect_block "malformed threshold falls back to the default (at it)" "300000-token stow threshold"
  pass "config: off disables the guard, an integer sets the threshold, and a malformed value keeps the 300000 default"
}

test_precompact_manual_blocks_once() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/manual")
  t="$dir/t.jsonl"
  add_usage "$t" 50000
  run_guard "$dir" precompact "$t" manual
  expect_block "first manual compaction without a stow" "Run /stow first, then /compact"
  run_guard "$dir" precompact "$t" manual
  expect_allow "second manual compaction in the same cycle"

  dir=$(make_primary_dir "$TMP_ROOT/manual-stowed")
  t="$dir/t.jsonl"
  add_typed_stow "$t"
  add_usage "$t" 50000
  run_guard "$dir" precompact "$t" manual
  expect_allow "manual compaction after a stow"
  pass "precompact: manual compaction without a stow is blocked once per cycle, and a stow lets it through"
}

test_stop_kicks_compaction_right_after_stow() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/kick")
  t="$dir/t.jsonl"
  add_usage "$t" 300000
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_guard "$dir" stop "$t"
  expect_block "nudge at the threshold" "Invoke the stow skill now (/stow)"
  add_skill_stow "$t"
  add_usage "$t" 331000
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_guard "$dir" precompact "$t" auto
  expect_block "auto compaction while the stow is still running" "Automatic compaction deferred"
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_guard "$dir" stop "$t"
  expect_block "turn end that finishes the stow" "past the 267000-token automatic compaction point"
  case "$HOOK_ERR" in *"The stow is done. Context is at 331000 tokens"*) : ;; *) fail "the post-stow block must name the context size: $HOOK_ERR" ;; esac
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_guard "$dir" precompact "$t" auto
  expect_allow "auto compaction once the stow has finished"
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_guard "$dir" stop "$t"
  expect_allow "a later turn end in the same cycle"

  dir=$(make_primary_dir "$TMP_ROOT/kick-early")
  t="$dir/t.jsonl"
  add_usage "$t" 100000
  add_typed_stow "$t"
  add_usage "$t" 120000
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_guard "$dir" stop "$t"
  expect_allow "a stow that finishes below the compaction point"
  add_usage "$t" 305000
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_guard "$dir" stop "$t"
  expect_allow "the threshold after a finished stow in the same cycle"
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_guard "$dir" precompact "$t" auto
  expect_allow "auto compaction after an earlier finished stow"
  pass "stop: the turn end after a stow holds once more when compaction is due, so compaction follows the stow at once"
}

test_stop_kick_window_resolution() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/kick-window")
  t="$dir/t.jsonl"
  mkdir -p "$dir/.claude" "$HOME/.claude"
  add_typed_stow "$t"
  add_usage "$t" 330000
  printf '{"autoCompactWindow": 350000}\n' > "$dir/.claude/settings.json"
  printf '{"autoCompactWindow": 300000}\n' > "$dir/.claude/settings.local.json"
  run_guard "$dir" stop "$t" '' local-wins
  expect_block "local settings window wins over project settings" "267000-token automatic compaction point"
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000 run_guard "$dir" stop "$t" '' env-wins
  expect_allow "environment window wins over settings (compaction point 367000 not reached)"
  rm -f "$dir/.claude/settings.local.json"
  run_guard "$dir" stop "$t" '' project
  expect_block "project settings window" "317000-token automatic compaction point"
  rm -f "$dir/.claude/settings.json"
  printf '{"autoCompactWindow": 320000}\n' > "$HOME/.claude/settings.json"
  run_guard "$dir" stop "$t" '' user
  rm -f "$HOME/.claude/settings.json"
  expect_block "user settings window" "287000-token automatic compaction point"
  run_guard "$dir" stop "$t" '' none
  expect_allow "no resolvable window"
  pass "stop: the compaction point resolves the window from env, local, project, then user settings"
}

test_precompact_auto_bounds() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/auto")
  t="$dir/t.jsonl"
  add_usage "$t" 250000
  run_guard "$dir" precompact "$t" auto
  expect_block "unstowed auto compaction past 200000 tokens" "compaction follows right after it"
  run_guard "$dir" precompact "$t" auto
  expect_block "the same deferral again" "proceeds without a stow at 400000 tokens"
  add_usage "$t" 200000
  run_guard "$dir" precompact "$t" auto
  expect_allow "auto compaction at or below the smallest context window"
  add_usage "$t" 399999
  run_guard "$dir" precompact "$t" auto
  expect_block "just below the ceiling" "Automatic compaction deferred"
  add_usage "$t" 400000
  run_guard "$dir" precompact "$t" auto
  expect_allow "at the ceiling (threshold plus 100000)"

  dir=$(make_primary_dir "$TMP_ROOT/auto-cap")
  t="$dir/t.jsonl"
  printf '900000\n' > "$dir/config/claude-stow-threshold"
  add_usage "$t" 949999
  run_guard "$dir" precompact "$t" auto
  expect_block "high threshold, below the cap" "proceeds without a stow at 950000 tokens"
  add_usage "$t" 950000
  run_guard "$dir" precompact "$t" auto
  expect_allow "high threshold, at the 950000 cap"
  pass "precompact: unstowed automatic compaction is deferred between 200000 tokens and the threshold plus 100000, capped at 950000"
}

test_scope_and_foreign_hosts() {
  local base dir t payload
  base=$(make_primary_dir "$TMP_ROOT/scope-base")
  dir="$TMP_ROOT/scope-wt"
  git -C "$base" worktree add -q -b fm/stow-guard-test "$dir"
  mkdir -p "$dir/state"
  t="$dir/t.jsonl"
  add_usage "$t" 300000
  run_guard "$dir" stop "$t"
  expect_allow "linked task worktree"

  dir=$(make_primary_dir "$TMP_ROOT/scope-cursor")
  t="$dir/t.jsonl"
  add_usage "$t" 300000
  payload=$(jq -cn --arg t "$t" '{session_id: "s", transcript_path: $t, cursor_version: "1.0"}')
  HOOK_RC=0
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$dir" "$GUARD" --stop 2> "$TMP_ROOT/err" || HOOK_RC=$?
  [ "$HOOK_RC" -eq 0 ] || fail "Cursor-delivered payload must stand down: $(cat "$TMP_ROOT/err")"

  mkdir -p "$dir/.pi/sessions"
  cp "$t" "$dir/.pi/sessions/t.jsonl"
  run_guard "$dir" stop "$dir/.pi/sessions/t.jsonl"
  expect_allow "Pi compatibility payload"

  HOOK_RC=0
  printf '' | FM_ROOT_OVERRIDE="$dir" "$GUARD" --stop 2> "$TMP_ROOT/err" || HOOK_RC=$?
  [ "$HOOK_RC" -eq 0 ] || fail "an empty payload must allow"
  run_guard "$dir" stop "$dir/missing.jsonl"
  expect_allow "missing transcript"
  pass "scope: task worktrees, Cursor and Pi payloads, empty payloads, and missing transcripts all allow"
}

test_markers_keep_only_current_session() {
  local dir t
  dir=$(make_primary_dir "$TMP_ROOT/sessions")
  t="$dir/t.jsonl"
  add_usage "$t" 300000
  run_guard "$dir" stop "$t" '' old-session
  expect_block "old session nudge" "/stow"
  run_guard "$dir" stop "$t" '' new-session
  expect_block "new session gets its own nudge" "/stow"
  if grep -q 'old-session' "$dir/state/.claude-stow-guard"; then
    fail "markers from an earlier session must be dropped"
  fi
  pass "markers: a new session gets its own nudge and older sessions' markers are dropped"
}

test_tracked_settings_register_guard() {
  local settings="$ROOT/.claude/settings.json"
  jq -e '.autoCompactWindow == 300000' "$settings" >/dev/null ||
    fail "tracked Claude settings must default autoCompactWindow to 300000"
  jq -e '[.hooks.Stop[].hooks[] | select(.asyncRewake != true) | .command | select(test("fm-claude-stow-guard.sh --stop$"))] | length == 1' "$settings" >/dev/null ||
    fail "tracked Claude settings must register the synchronous Stop stow guard"
  jq -e '[.hooks.PreCompact[].hooks[].command | select(test("fm-claude-stow-guard.sh --precompact$"))] | length == 1' "$settings" >/dev/null ||
    fail "tracked Claude settings must register the PreCompact stow guard"
  pass "settings: tracked Claude settings default the compaction window to 300000 and register both guard hooks"
}

test_stop_below_threshold_allows
test_stop_nudges_once_per_cycle
test_stop_counts_typed_and_skill_stow_only
test_stop_ignores_sidechain_and_zero_usage
test_stop_tolerates_partial_last_line
test_stop_new_cycle_after_compaction
test_stop_reports_unstowed_compaction_once
test_threshold_config
test_precompact_manual_blocks_once
test_stop_kicks_compaction_right_after_stow
test_stop_kick_window_resolution
test_precompact_auto_bounds
test_scope_and_foreign_hosts
test_markers_keep_only_current_session
test_tracked_settings_register_guard

echo "all fm-claude-stow-guard tests passed"
