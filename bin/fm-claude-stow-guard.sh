#!/usr/bin/env bash
# Stow-before-compaction guard for a Claude PRIMARY session (main home or
# marked secondmate home). Registered twice in tracked .claude/settings.json:
#
#   --stop        synchronous Stop hook. Once the session's context reaches
#                 the stow threshold, it blocks the turn end ONCE per
#                 compaction cycle with an instruction to run /stow now. It
#                 also reports, once, a compaction that happened with no stow
#                 since the previous compaction.
#   --precompact  PreCompact hook. When no stow ran since the previous
#                 compaction it blocks compaction where that is safe (below),
#                 so the Stop nudge gets the chance to run first.
#
# A stow needs a model turn, so it can never run inside a compaction hook;
# the Stop nudge is what actually gets the stow done, and the PreCompact block
# only buys the time for it. docs/configuration.md "Stow before compaction"
# owns the operator-facing contract and the two thresholds;
# docs/verification/stow-memory.md records the Claude Code evidence.
#
# Compaction cycle: the part of the session transcript after its newest
# compact boundary entry ({"type":"system","subtype":"compact_boundary"}), or
# the whole transcript before the first compaction. Claude Code appends that
# entry to the same transcript file on every manual or automatic compaction.
#
# Context size: the newest main-chain (isSidechain not true) assistant entry
# in the current cycle whose message.usage is non-zero, measured as
# message.usage.input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens. That is the prompt size Claude Code itself compares
# against its auto-compact threshold. With no such entry in the cycle (a
# compaction just ran) the context reads as 0.
#
# A stow counts when the cycle contains either a main-chain user entry whose
# string content carries <command-name>/stow</command-name> (the captain typed
# /stow) or a main-chain assistant tool_use of Skill with input.skill "stow"
# (the model invoked the skill).
#
# Stow threshold: config/claude-stow-threshold holds one positive integer
# token count, or "off" to disable both modes; absent or malformed means the
# 270000 default. The compaction window is Claude Code's own autoCompactWindow
# (tracked default 350000 in .claude/settings.json), resolved here in Claude's
# order for the block ceiling: CLAUDE_CODE_AUTO_COMPACT_WINDOW, then
# autoCompactWindow in .claude/settings.local.json, .claude/settings.json, and
# ~/.claude/settings.json.
#
# PreCompact decision when no stow ran in the current cycle:
#   - trigger "manual": block once per cycle with an instruction to stow
#     first; a second /compact in the same cycle compacts anyway.
#   - trigger "auto": block only while stow threshold <= context < ceiling,
#     where the ceiling is the resolved window capped at 950000 tokens, below
#     the hard limit of Claude's largest (1M-token) context window. Below the
#     stow threshold the nudge has not had its chance (Claude Code's
#     background precompute arms there, or the model's own window is smaller
#     than the threshold), and at or past the ceiling the block would only
#     push the session toward its hard limit, so both allow. With no
#     resolvable window it allows.
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
DEFAULT_STOW_THRESHOLD=270000
MAX_BLOCK_CEILING=950000
MARKERS="$STATE/.claude-stow-guard"

MODE=
case "${1:-}" in
  --stop) MODE=stop ;;
  --precompact) MODE=precompact ;;
  *) echo "usage: $(basename "$0") --stop|--precompact" >&2; exit 2 ;;
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
  slice_has_stow "$CUR" 0 && exit 0
  case "$TRIGGER" in
    manual)
      marker_present precompact-manual "$CYCLE_KEY" && exit 0
      marker_record precompact-manual "$CYCLE_KEY" || exit 0
      printf 'No /stow has run since the previous compaction, so this session'"'"'s uncaptured knowledge would be lost to the summary. Run /stow first, then /compact. Run /compact again to compact without a stow.\n' >&2
      exit 2
      ;;
    auto)
      TOKENS=$(cycle_context_tokens "$CUR")
      [ "$TOKENS" -ge "$THRESHOLD" ] || exit 0
      WINDOW=$(compact_window)
      [ -n "$WINDOW" ] || exit 0
      [ "$WINDOW" -le "$MAX_BLOCK_CEILING" ] || WINDOW=$MAX_BLOCK_CEILING
      [ "$TOKENS" -lt "$WINDOW" ] || exit 0
      printf 'Automatic compaction deferred: context is at %s tokens and no /stow has run since the previous compaction. The turn-end stow nudge runs /stow first; compaction proceeds once a stow has run or the context reaches %s tokens.\n' "$TOKENS" "$WINDOW" >&2
      exit 2
      ;;
  esac
  exit 0
fi

# --- Stop mode ------------------------------------------------------------------
MESSAGE=

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

if ! marker_present nudged "$CYCLE_KEY"; then
  TOKENS=$(cycle_context_tokens "$CUR")
  if [ "$TOKENS" -ge "$THRESHOLD" ] && ! slice_has_stow "$CUR" 0 && marker_record nudged "$CYCLE_KEY"; then
    MESSAGE="${MESSAGE:+$MESSAGE }Context is at $TOKENS tokens, past the $THRESHOLD-token stow threshold, and compaction comes next."
  fi
fi

[ -n "$MESSAGE" ] || exit 0
printf '%s Invoke the stow skill now (/stow) to capture this session'"'"'s durable knowledge and open work, then end the turn. A lock-refused read-only session skips the stow and says so.\n' "$MESSAGE" >&2
exit 2
