#!/usr/bin/env bash
# Stow-then-compact guard for a Claude PRIMARY session (main home or marked
# secondmate home). Registered twice in tracked .claude/settings.json:
#
#   --stop        synchronous Stop hook. Once the session's context reaches
#                 the stow threshold with no stow in the current compaction
#                 cycle, it blocks the turn end ONCE per cycle with an
#                 instruction to run /stow now. At the turn end that follows a
#                 stow, when Claude Code's own compaction point is already
#                 passed, it blocks the turn end ONCE more so the model sends
#                 one more request: Claude Code runs its automatic compaction
#                 before that request, so compaction follows the stow at once
#                 instead of waiting for the next prompt. It also reports,
#                 once, a compaction that happened with no stow since the
#                 previous compaction.
#   --precompact  PreCompact hook. It holds back a compaction that no finished
#                 stow licenses (below), so the stow runs first.
#
# A stow needs a model turn, so it can never run inside a compaction hook,
# and no hook can start a compaction; the Stop hook is what gets the stow
# done and then hands Claude Code the request it compacts before.
# docs/configuration.md "Stow before compaction" owns the operator-facing
# contract; docs/verification/stow-memory.md records the Claude Code evidence.
#
# Compaction cycle: the part of the session transcript after its newest
# compact boundary entry ({"type":"system","subtype":"compact_boundary"}), or
# the whole transcript before the first compaction. Claude Code appends that
# entry to the same transcript file on every manual or automatic compaction.
#
# Context size: the newest main-chain (isSidechain not true) assistant entry
# in the current cycle whose message.usage is non-zero, measured as
# message.usage.input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens. That is the prompt size Claude Code itself starts
# from when it checks its auto-compact threshold. With no such entry in the
# cycle (a compaction just ran) the context reads as 0.
#
# A stow counts when the cycle contains either a main-chain user entry whose
# string content carries <command-name>/stow</command-name> (the captain typed
# /stow) or a main-chain assistant tool_use of Skill with input.skill "stow"
# (the model invoked the skill). A stow has FINISHED once a turn end follows
# it: the Stop hook then records a "stowed" marker for the cycle.
#
# Stow threshold: config/claude-stow-threshold holds one positive integer
# token count, or "off" to disable both modes; absent or malformed means the
# 300000 default. Compaction window W: Claude Code's own autoCompactWindow
# (tracked default 300000 in .claude/settings.json), resolved in Claude
# Code's order: CLAUDE_CODE_AUTO_COMPACT_WINDOW, then autoCompactWindow in
# .claude/settings.local.json, .claude/settings.json, and
# ~/.claude/settings.json. Claude Code 2.1.283 compacts automatically at
# W - 20000 - 13000 (267000 for the default); that is the compaction point
# the post-stow block compares against. With no resolvable window the
# post-stow block never fires.
#
# PreCompact decision:
#   - trigger "manual": when no stow ran in the current cycle, block once per
#     cycle with an instruction to stow first; a second /compact in the same
#     cycle compacts anyway.
#   - trigger "auto": allow once the cycle's stow has finished. Otherwise
#     block while 200000 < context < ceiling, where the ceiling is the stow
#     threshold plus 100000 tokens, capped at 950000. 200000 is the smallest
#     Claude context window, so a prompt past it proves the model has the
#     1M-token window and holding compaction cannot run it into its hard
#     limit; at or past the ceiling the stow has had its chance and the block
#     would only push the session toward that limit. Both sides allow.
# Every other case allows silently. On allow this hook prints nothing: a
# PreCompact hook's stdout becomes extra compaction instructions.
#
# Once-per-cycle markers live in state/.claude-stow-guard as
# "<kind> <session_id> <cycle key>" lines, where the cycle key is the newest
# compact boundary's uuid or "start". Only the current session's lines are
# kept.
#
# Scope and fail direction: only a genuine primary checkout, as
# bin/fm-primary-scope-lib.sh decides it; child crew/scout worktrees stay
# inert. Payloads delivered by Cursor or by Pi's Claude-hook compatibility
# layer stand down, as the other tracked Claude hooks do. Any uncertainty
# (no payload, no jq, unreadable transcript) allows the stop or compaction:
# a missed stow nudge costs memory, while a wrongly blocked compaction could
# wedge the session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DEFAULT_STOW_THRESHOLD=300000
SMALLEST_CONTEXT_WINDOW=200000
BLOCK_HEADROOM=100000
MAX_BLOCK_CEILING=950000
# Claude Code 2.1.283 compacts at window - min(max output, 20000) - 13000.
COMPACT_RESERVE=33000
MARKERS="$STATE/.claude-stow-guard"

MODE=
case "${1:-}" in
  --stop) MODE=stop ;;
  --precompact) MODE=precompact ;;
  # Exit 1, never 2: Claude Code reads a hook's exit 2 as a deliberate block.
  *) echo "usage: $(basename "$0") --stop|--precompact" >&2; exit 1 ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# One parse for every payload field: this hook runs at every turn end, and
# each jq start is the bulk of its cost.
FIELDS=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload") else . end
  | ((.transcript_path // "") | tostring | gsub("\n"; " ")),
    ((.session_id // "unknown") | tostring | gsub("\\s"; "_")),
    ((.trigger // "") | tostring | gsub("\n"; " "))
' 2>/dev/null) || exit 0
TRANSCRIPT=$(printf '%s\n' "$FIELDS" | sed -n 1p)
SESSION_ID=$(printf '%s\n' "$FIELDS" | sed -n 2p)
TRIGGER=$(printf '%s\n' "$FIELDS" | sed -n 3p)
[ -n "$SESSION_ID" ] || SESSION_ID=unknown
case "$TRANSCRIPT" in */.pi/*) exit 0 ;; esac

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

stow_threshold() {
  local value
  value=$(head -n 1 "$CONFIG/claude-stow-threshold" 2>/dev/null | tr -d '[:space:]') || value=
  case "$value" in
    off) printf 'off\n' ;;
    ''|*[!0-9]*|0*) printf '%s\n' "$DEFAULT_STOW_THRESHOLD" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

THRESHOLD=$(stow_threshold)
[ "$THRESHOLD" = off ] && exit 0
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || exit 0

# "<line> <uuid> <trigger> <preTokens>" for each genuine compact boundary
# entry, oldest first; a missing field prints as "-".
boundary_lines() {
  local hits
  hits=$(grep -n -F '"compact_boundary"' "$TRANSCRIPT" 2>/dev/null) || return 0
  printf '%s\n' "$hits" | jq -R -r '
    capture("^(?<n>[0-9]+):(?<j>.*)$") as $c
    | ($c.j | fromjson?)
    | select(type == "object" and .type == "system" and .subtype == "compact_boundary")
    | [$c.n, .uuid, .compactMetadata.trigger?, .compactMetadata.preTokens?]
    | map(if . == null or . == "" then "-" else (tostring | gsub("\\s"; "_")) end)
    | join(" ")
  ' 2>/dev/null
}

# Print the lines strictly after line $1 up to and including line $2
# (0 = end of file).
cycle_slice() {  # <after-line> <through-line|0>
  if [ "$2" -gt 0 ]; then
    sed -n "$(($1 + 1)),$2p" "$TRANSCRIPT" 2>/dev/null
  else
    tail -n +"$(($1 + 1))" "$TRANSCRIPT" 2>/dev/null
  fi
}

# True when a stow invocation appears in the given slice of the transcript.
# Each line parses on its own, so a partially written entry is skipped rather
# than ending the scan. first() is avoided: jq 1.6 lets fromjson? swallow its
# break, so it would not stop at the first match anyway.
slice_has_stow() {  # <after-line> <through-line|0>
  local lines hit
  lines=$(cycle_slice "$1" "$2" | grep -F 'stow') || return 1
  hit=$(printf '%s\n' "$lines" | jq -R -r '
    fromjson? | select(type == "object" and (.isSidechain | not)) | select(
      (.type == "user" and ((.message.content? // null) | type) == "string"
        and (.message.content | contains("<command-name>/stow</command-name>")))
      or (.type == "assistant" and ((.message.content? // null) | type) == "array"
        and any(.message.content[]; type == "object" and .type == "tool_use"
          and .name == "Skill" and ((.input.skill? // "") == "stow")))
    ) | "stow"
  ' 2>/dev/null | head -n 1)
  [ "$hit" = stow ]
}

# Context tokens of the newest main-chain assistant usage after line $1.
cycle_context_tokens() {  # <after-line>
  local lines tokens
  lines=$(cycle_slice "$1" 0 | grep -F '"usage"') || { printf '0\n'; return 0; }
  tokens=$(printf '%s\n' "$lines" | jq -R -r '
    fromjson? | select(type == "object" and .type == "assistant" and (.isSidechain | not)
        and ((.message.usage? // null) | type) == "object")
      | .message.usage
      | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
      | select(. > 0)
  ' 2>/dev/null | tail -n 1)
  case "$tokens" in ''|*[!0-9]*) tokens=0 ;; esac
  printf '%s\n' "$tokens"
}

marker_present() {  # <kind> <cycle-key>
  grep -qxF "$1 $SESSION_ID $2" "$MARKERS" 2>/dev/null
}

# Record a once-per-cycle marker, keeping only this session's lines. Returns
# nonzero when the marker cannot be written, so a caller never blocks
# without a durable record bounding the block.
marker_record() {  # <kind> <cycle-key>
  local tmp
  tmp=$(mktemp "$STATE/.claude-stow-guard.XXXXXX") || return 1
  {
    awk -v s="$SESSION_ID" '$2 == s' "$MARKERS" 2>/dev/null
    printf '%s %s %s\n' "$1" "$SESSION_ID" "$2"
  } > "$tmp" && mv -f "$tmp" "$MARKERS" && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Resolve Claude Code's configured auto-compact window, or print nothing.
compact_window() {
  local value file
  value=${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}
  case "$value" in ''|*[!0-9]*) value= ;; esac
  if [ -z "$value" ]; then
    for file in "$FM_ROOT/.claude/settings.local.json" "$FM_ROOT/.claude/settings.json" "${HOME:-/nonexistent}/.claude/settings.json"; do
      [ -f "$file" ] || continue
      value=$(jq -r 'if (.autoCompactWindow | type) == "number" then (.autoCompactWindow | floor | tostring) else empty end' "$file" 2>/dev/null) || value=
      [ -n "$value" ] && break
    done
  fi
  [ -n "$value" ] && printf '%s\n' "$value"
}

BOUNDARIES=$(boundary_lines)
CUR=0
PREV=0
CYCLE_KEY=start
CUR_TRIGGER=-
CUR_PRE=-
if [ -n "$BOUNDARIES" ]; then
  read -r CUR CYCLE_KEY CUR_TRIGGER CUR_PRE <<EOF
$(printf '%s\n' "$BOUNDARIES" | tail -n 1)
EOF
  read -r PREV _ <<EOF
$(printf '%s\n' "$BOUNDARIES" | tail -n 2 | head -n 1)
EOF
  [ "$PREV" = "$CUR" ] && PREV=0
  [ "$CYCLE_KEY" != - ] || CYCLE_KEY="line-$CUR"
fi

if [ "$MODE" = precompact ]; then
  case "$TRIGGER" in
    manual)
      slice_has_stow "$CUR" 0 && exit 0
      marker_present precompact-manual "$CYCLE_KEY" && exit 0
      marker_record precompact-manual "$CYCLE_KEY" || exit 0
      printf 'No /stow has run since the previous compaction, so this session'"'"'s uncaptured knowledge would be lost to the summary. Run /stow first, then /compact. Run /compact again to compact without a stow.\n' >&2
      exit 2
      ;;
    auto)
      marker_present stowed "$CYCLE_KEY" && exit 0
      TOKENS=$(cycle_context_tokens "$CUR")
      [ "$TOKENS" -gt "$SMALLEST_CONTEXT_WINDOW" ] || exit 0
      CEILING=$((THRESHOLD + BLOCK_HEADROOM))
      [ "$CEILING" -le "$MAX_BLOCK_CEILING" ] || CEILING=$MAX_BLOCK_CEILING
      [ "$TOKENS" -lt "$CEILING" ] || exit 0
      printf 'Automatic compaction deferred: context is at %s tokens and no /stow has finished since the previous compaction. The stow runs at the turn end past %s tokens and compaction follows right after it; compaction proceeds without a stow at %s tokens.\n' "$TOKENS" "$THRESHOLD" "$CEILING" >&2
      exit 2
      ;;
  esac
  exit 0
fi

# --- Stop mode ------------------------------------------------------------------
MESSAGE=
TOKENS=$(cycle_context_tokens "$CUR")

# A compaction that ran with no stow since the previous one is reported once,
# unless a stow already ran after it.
if [ "$CUR" -gt 0 ] && ! marker_present audited "$CYCLE_KEY"; then
  if slice_has_stow "$CUR" 0 || slice_has_stow "$PREV" "$CUR"; then
    marker_record audited "$CYCLE_KEY" || true
  elif marker_record audited "$CYCLE_KEY"; then
    DETAIL=
    [ "$CUR_TRIGGER" = - ] || DETAIL="trigger $CUR_TRIGGER"
    [ "$CUR_PRE" = - ] || DETAIL="${DETAIL:+$DETAIL, }at $CUR_PRE tokens"
    MESSAGE="This session compacted${DETAIL:+ ($DETAIL)} with no /stow since the previous compaction."
  fi
fi

if slice_has_stow "$CUR" 0; then
  # The first turn end after a stow finishes it. When Claude Code's own
  # compaction point is already passed, hold this turn end once more so the
  # next request, which Claude Code compacts before, happens now.
  marker_present stowed "$CYCLE_KEY" && exit 0
  marker_record stowed "$CYCLE_KEY" || exit 0
  WINDOW=$(compact_window)
  [ -n "$WINDOW" ] || exit 0
  COMPACT_AT=$((WINDOW - COMPACT_RESERVE))
  [ "$COMPACT_AT" -gt 0 ] && [ "$TOKENS" -ge "$COMPACT_AT" ] || exit 0
  marker_present compact-kick "$CYCLE_KEY" && exit 0
  marker_record compact-kick "$CYCLE_KEY" || exit 0
  printf 'The stow is done. Context is at %s tokens, past the %s-token automatic compaction point, so Claude Code compacts before your next reply. Reply with one short line saying the stow is done and compaction follows, then end the turn.\n' "$TOKENS" "$COMPACT_AT" >&2
  exit 2
fi

if ! marker_present nudged "$CYCLE_KEY" && [ "$TOKENS" -ge "$THRESHOLD" ] && marker_record nudged "$CYCLE_KEY"; then
  MESSAGE="${MESSAGE:+$MESSAGE }Context is at $TOKENS tokens, past the $THRESHOLD-token stow threshold, and compaction follows the stow."
fi

[ -n "$MESSAGE" ] || exit 0
printf '%s Invoke the stow skill now (/stow) to capture this session'"'"'s durable knowledge and open work, then end the turn. A lock-refused read-only session skips the stow and says so.\n' "$MESSAGE" >&2
exit 2
