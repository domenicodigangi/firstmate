#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-agent-home.sh, the throwaway-HOME launcher that
# no-mistakes' agent_path_override points at through bin/nm-agent-home/<agent>.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-agent-home)
LINKS="$ROOT/bin/nm-agent-home"

# A fake real HOME holding the agent config the launcher links in, plus key
# material that must stay untouched.
REAL="$TMP_ROOT/real-home"
mkdir -p "$REAL/.pi/agent" "$REAL/.claude" "$REAL/.codex" "$REAL/.config/gh" \
  "$REAL/.config/git" "$REAL/.config/sops/age" "$REAL/.secrets" "$REAL/.ssh"
printf 'pi-auth\n' > "$REAL/.pi/agent/auth.json"
printf 'claude-state\n' > "$REAL/.claude.json"
printf '[user]\n\tname = t\n' > "$REAL/.gitconfig"
printf '[init]\n\tdefaultBranch = main\n' > "$REAL/.config/git/config"
printf 'gh-token\n' > "$REAL/.config/gh/hosts.yml"
printf 'real-key\n' > "$REAL/.config/sops/age/keys.txt"

# Fake agents: report the environment they were launched with, then run any
# CI-style step handed to them through FAKE_STEP.
FAKE="$TMP_ROOT/fake-agents"
mkdir -p "$FAKE"
for agent in pi claude codex; do
  cat > "$FAKE/$agent" <<'EOF'
#!/usr/bin/env bash
{
  printf 'pid=%s\n' "$$"
  printf 'home=%s\n' "$HOME"
  printf 'args=%s\n' "$*"
  printf 'stdin=%s\n' "$(cat)"
  printf 'sops=%s\n' "$(env | grep -c '^SOPS_AGE_' || true)"
  printf 'xdg_config=%s\n' "${XDG_CONFIG_HOME-unset}"
  printf 'runtime=%s\n' "${XDG_RUNTIME_DIR-unset}"
} > "$FAKE_OUT"
[ -z "${FAKE_STEP:-}" ] || sh -c "$FAKE_STEP"
exit "${FAKE_EXIT:-0}"
EOF
  chmod +x "$FAKE/$agent"
done

SANDBOX_TMP="$TMP_ROOT/tmp"
mkdir -p "$SANDBOX_TMP"

run_agent() {  # <agent> [args...]; stdin is forwarded
  HOME="$REAL" TMPDIR="$SANDBOX_TMP" PATH="$LINKS:$FAKE:$PATH" \
    FAKE_OUT="$TMP_ROOT/out" "$LINKS/$1" "${@:2}"
}

field() { sed -n "s/^$1=//p" "$TMP_ROOT/out"; }

test_launches_agent_with_throwaway_home() {
  local home code
  printf 'the prompt' | SOPS_AGE_KEY=secret SOPS_AGE_KEY_FILE="$REAL/.config/sops/age/keys.txt" \
    SOPS_AGE_KEY_CMD=cat XDG_CONFIG_HOME="$REAL/.config" XDG_RUNTIME_DIR=/run/user/fixture \
    run_agent pi --mode json --session "a b"
  code=$?
  assert_equals 0 "$code" "launcher did not exit with the agent's status"
  home=$(field home)
  assert_not_equals "$REAL" "$home" "agent kept the real HOME"
  case "$home" in "$SANDBOX_TMP"/fm-nm-agent-home.*) ;; *) fail "throwaway HOME is not a fresh mktemp dir under TMPDIR: $home" ;; esac
  assert_equals 700 "$(stat -c %a "$home" 2>/dev/null || stat -f %Lp "$home")" "throwaway HOME is not private"
  assert_equals "--mode json --session a b" "$(field args)" "agent argv was not passed through unchanged"
  assert_equals "the prompt" "$(field stdin)" "agent stdin was not forwarded"
  assert_equals 0 "$(field sops)" "SOPS_AGE_* variables reached the agent"
  assert_equals unset "$(field xdg_config)" "XDG_CONFIG_HOME still pointed the agent at the real config"
  assert_equals /run/user/fixture "$(field runtime)" "XDG_RUNTIME_DIR must survive; it is not HOME-relative"
  pass "fm-nm-agent-home.sh: agents run with a throwaway HOME, unchanged argv and stdin, and no SOPS age keys"
}

test_agent_config_is_linked_and_git_gh_copied() {
  local home
  run_agent pi < /dev/null || fail "pi launch failed"
  home=$(field home)
  [ -L "$home/.pi" ] || fail "pi config was not linked into the throwaway HOME"
  assert_equals "$REAL/.pi" "$(readlink "$home/.pi")" "pi config link does not reach the real config"
  [ ! -L "$home/.gitconfig" ] || fail "git identity was symlinked, exposing the real file to writes"
  [ ! -L "$home/.config/git" ] || fail "git config was symlinked, exposing the real config to writes"
  [ ! -L "$home/.config/gh" ] || fail "gh auth was symlinked, exposing the real config to writes"
  assert_equals "$(cat "$REAL/.gitconfig")" "$(cat "$home/.gitconfig")" "git identity was not copied"
  assert_equals "$(cat "$REAL/.config/git/config")" "$(cat "$home/.config/git/config")" "git config was not copied"
  assert_equals "$(cat "$REAL/.config/gh/hosts.yml")" "$(cat "$home/.config/gh/hosts.yml")" "gh auth was not copied"
  [ ! -e "$home/.claude" ] || fail "pi launch linked another agent's config"
  [ ! -e "$home/.config/sops" ] && [ ! -e "$home/.secrets" ] && [ ! -e "$home/.ssh" ] \
    || fail "key directories were exposed in the throwaway HOME"

  local step
  # shellcheck disable=SC2016 # The step runs later, inside the agent's HOME.
  step='unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM; git config --global user.name clobbered && echo clobbered > "$HOME/.config/git/config" && echo clobbered > "$HOME/.config/gh/hosts.yml"'
  FAKE_STEP=$step run_agent pi < /dev/null || fail "pi launch with a git/gh write step failed"
  home=$(field home)
  grep -q 'clobbered' "$home/.gitconfig" || fail "the step did not write the throwaway HOME's git identity"
  grep -q 'name = t' "$REAL/.gitconfig" || fail "a write through the throwaway HOME changed the real git identity"
  assert_equals '[init]
	defaultBranch = main' "$(cat "$REAL/.config/git/config")" "a write through the throwaway HOME changed the real git config"
  assert_equals gh-token "$(cat "$REAL/.config/gh/hosts.yml")" "a write through the throwaway HOME changed the real gh auth"

  run_agent claude < /dev/null || fail "claude launch failed"
  home=$(field home)
  [ -L "$home/.claude" ] && [ -L "$home/.claude.json" ] || fail "claude config was not linked"
  run_agent codex < /dev/null || fail "codex launch failed"
  home=$(field home)
  [ -L "$home/.codex" ] || fail "codex config was not linked"
  pass "fm-nm-agent-home.sh: agent config is linked, git and gh auth are copied and write-isolated"
}

test_symlinked_git_gh_sources_are_copied_not_linked() {
  local real dotfiles home step
  real="$TMP_ROOT/linked-home"
  dotfiles="$TMP_ROOT/dotfiles"
  mkdir -p "$real/.config" "$real/.pi" "$dotfiles/git" "$dotfiles/gh"
  printf '[user]\n\tname = sym\n' > "$dotfiles/gitconfig"
  printf '[init]\n\tdefaultBranch = symlinked\n' > "$dotfiles/git/config"
  printf 'gh-token-sym\n' > "$dotfiles/gh/hosts.yml"
  ln -s "$dotfiles/gitconfig" "$real/.gitconfig"
  ln -s "$dotfiles/git" "$real/.config/git"
  ln -s "$dotfiles/gh" "$real/.config/gh"

  HOME="$real" TMPDIR="$SANDBOX_TMP" PATH="$LINKS:$FAKE:$PATH" FAKE_OUT="$TMP_ROOT/out" \
    "$LINKS/pi" < /dev/null || fail "pi launch failed"
  home=$(field home)
  [ ! -L "$home/.gitconfig" ] || fail "a symlinked git identity was copied as a link"
  [ ! -L "$home/.config/git" ] || fail "a symlinked git config was copied as a link"
  [ ! -L "$home/.config/gh" ] || fail "a symlinked gh auth was copied as a link"
  assert_equals "$(cat "$dotfiles/gitconfig")" "$(cat "$home/.gitconfig")" "the symlinked git identity was not copied as a real file"
  assert_equals "$(cat "$dotfiles/git/config")" "$(cat "$home/.config/git/config")" "the symlinked git config was not copied as a real file"
  assert_equals "$(cat "$dotfiles/gh/hosts.yml")" "$(cat "$home/.config/gh/hosts.yml")" "the symlinked gh auth was not copied as a real file"

  # shellcheck disable=SC2016 # The step runs later, inside the agent's HOME.
  step='unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM; git config --global user.name clobbered && echo clobbered > "$HOME/.config/git/config" && echo clobbered > "$HOME/.config/gh/hosts.yml"'
  FAKE_STEP=$step HOME="$real" TMPDIR="$SANDBOX_TMP" PATH="$LINKS:$FAKE:$PATH" FAKE_OUT="$TMP_ROOT/out" \
    "$LINKS/pi" < /dev/null || fail "pi launch with a git/gh write step failed"
  grep -q 'name = sym' "$dotfiles/gitconfig" || fail "a write through the throwaway HOME changed the symlinked real git identity"
  assert_equals '[init]
	defaultBranch = symlinked' "$(cat "$dotfiles/git/config")" "a write through the throwaway HOME changed the symlinked real git config"
  assert_equals gh-token-sym "$(cat "$dotfiles/gh/hosts.yml")" "a write through the throwaway HOME changed the symlinked real gh auth"
  pass "fm-nm-agent-home.sh: symlinked git and gh config are dereferenced into real copies"
}

test_ci_step_cannot_clobber_real_keys() {
  local step
  # shellcheck disable=SC2016 # The step runs later, inside the agent's HOME.
  step='mkdir -p "$HOME/.config/sops/age" "$HOME/.secrets" "$HOME/.ssh" && echo clobbered > "$HOME/.config/sops/age/keys.txt" && echo x > "$HOME/.secrets/s" && echo x > "$HOME/.ssh/id"'
  FAKE_STEP=$step run_agent pi < /dev/null || fail "pi launch with a CI step failed"
  assert_equals real-key "$(cat "$REAL/.config/sops/age/keys.txt")" "CI step overwrote the real SOPS age key"
  assert_absent "$REAL/.secrets/s" "CI step wrote into the real ~/.secrets"
  assert_absent "$REAL/.ssh/id" "CI step wrote into the real ~/.ssh"
  pass "fm-nm-agent-home.sh: a CI step writing ~/.config/sops, ~/.secrets, or ~/.ssh lands in the throwaway HOME"
}

test_agent_replaces_the_launcher_process() {
  local pid
  HOME="$REAL" TMPDIR="$SANDBOX_TMP" PATH="$LINKS:$FAKE:$PATH" FAKE_OUT="$TMP_ROOT/out" \
    "$LINKS/pi" < /dev/null &
  pid=$!
  wait "$pid"
  assert_equals "$pid" "$(field pid)" "agent ran as a child, so killing the launcher would orphan it"
  pass "fm-nm-agent-home.sh: the agent replaces the launcher process"
}

test_exit_status_propagates() {
  FAKE_EXIT=7 run_agent codex < /dev/null
  assert_equals 7 "$?" "agent exit status was not propagated"
  pass "fm-nm-agent-home.sh: the agent's exit status is propagated"
}

test_refuses_unknown_or_missing_agent() {
  local out code
  ln -s "$ROOT/bin/fm-nm-agent-home.sh" "$TMP_ROOT/grok"
  out=$(HOME="$REAL" TMPDIR="$SANDBOX_TMP" PATH="$FAKE:$PATH" "$TMP_ROOT/grok" 2>&1 < /dev/null)
  code=$?
  assert_not_equals 0 "$code" "an agent without a known config layout was launched"
  assert_contains "$out" "grok" "unknown-agent refusal did not name the agent"

  out=$(HOME="$REAL" TMPDIR="$SANDBOX_TMP" PATH="$LINKS:$(fm_test_base_path_sans "$PATH" pi)" \
    "$LINKS/pi" 2>&1 < /dev/null)
  code=$?
  assert_not_equals 0 "$code" "launcher succeeded with no real pi on PATH"
  assert_contains "$out" "pi" "missing-agent refusal did not name the agent"
  pass "fm-nm-agent-home.sh: an unknown agent or one missing from PATH is refused, never relaunched through itself"
}

test_prunes_dead_launch_homes_only() {
  local dead live
  dead=$(mktemp -d "$SANDBOX_TMP/fm-nm-agent-home.XXXXXXXX")
  printf '999999999\n' > "$dead/.fm-nm-agent-pid"
  ln -s "$REAL/.pi" "$dead/.pi"
  live=$(mktemp -d "$SANDBOX_TMP/fm-nm-agent-home.XXXXXXXX")
  printf '%s\n' "$$" > "$live/.fm-nm-agent-pid"
  run_agent pi < /dev/null || fail "pi launch failed"
  assert_absent "$dead" "a launch HOME whose agent exited was not pruned"
  assert_present "$live" "a launch HOME whose agent is still running was pruned"
  assert_present "$REAL/.pi/agent/auth.json" "pruning followed a link into the real agent config"
  pass "fm-nm-agent-home.sh: finished launch HOMEs are pruned without following links"
}

test_launches_agent_with_throwaway_home
test_agent_config_is_linked_and_git_gh_copied
test_symlinked_git_gh_sources_are_copied_not_linked
test_ci_step_cannot_clobber_real_keys
test_agent_replaces_the_launcher_process
test_exit_status_propagates
test_refuses_unknown_or_missing_agent
test_prunes_dead_launch_homes_only
