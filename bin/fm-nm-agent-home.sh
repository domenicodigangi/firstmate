#!/usr/bin/env bash
# fm-nm-agent-home.sh - launch a no-mistakes pipeline agent with a throwaway HOME.
#
# Usage: bin/nm-agent-home/<agent> [agent args...]
#   <agent> is pi, claude, or codex; each bin/nm-agent-home/<agent> entry is a
#   symlink to this script, which reads the agent name from the name it was
#   invoked as. Point the machine-global no-mistakes config at those entries:
#
#     # ~/.no-mistakes/config.yaml
#     agent_path_override:
#       pi: <firstmate>/bin/nm-agent-home/pi
#       claude: <firstmate>/bin/nm-agent-home/claude
#       codex: <firstmate>/bin/nm-agent-home/codex
#
#   no-mistakes execs the override with the agent's own argv and stdin, and
#   re-reads that config for each new run, so a run already in progress keeps
#   the agent it started with.
#
# Why: no-mistakes gate and test agents inherit the daemon's environment, so a
# CI step or repo script an agent runs locally writes through the real HOME.
# That is how a test agent once overwrote ~/.config/sops/age/keys.txt.
#
# Contract, per launch:
#   - HOME becomes a fresh private `mktemp -d` directory under ${TMPDIR:-/tmp}
#     named fm-nm-agent-home.*, so ~/.config/sops, ~/.secrets, and ~/.ssh
#     resolve inside it.
#   - Every SOPS_AGE_* variable is unset (SOPS_AGE_KEY, SOPS_AGE_KEY_FILE,
#     SOPS_AGE_KEY_CMD, and the rest of that family), and the HOME-relative
#     XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, and XDG_CACHE_HOME are
#     unset so tools fall back to the throwaway HOME. XDG_RUNTIME_DIR is kept.
#   - Only what the agent needs to authenticate and resume sessions is linked
#     in from the real HOME: the agent's own config (pi: .pi, claude: .claude
#     and .claude.json, codex: .codex), git identity (.gitconfig,
#     .config/git), and gh auth (.config/gh), each only when it exists.
#     These are symlinks, not copies: a copied OAuth credential would fork the
#     refresh token, so the first refresh in one copy could sign the other out,
#     and a copied session store would break no-mistakes session reuse.
#     No key directory is ever linked.
#   - The real agent is the first <agent> on PATH outside this script's own
#     directories; it replaces this process (exec), so the agent keeps the
#     pid no-mistakes started and a timeout kill reaches it directly.
#   - Earlier launch HOMEs whose recorded agent pid is gone are removed first;
#     removal never follows the links inside them.
#
# Exit: the agent's own status; 127 when the agent name is not pi, claude, or
# codex, or no real agent binary is found (a refusal names the agent).
set -u

SELF=$(readlink -f "${BASH_SOURCE[0]}")
SELF_DIR=$(dirname "$SELF")
INVOKED_DIR=$(cd "$(dirname "$0")" && pwd -P)
AGENT=$(basename "$0")

refuse() {
  printf 'fm-nm-agent-home: %s\n' "$1" >&2
  exit 127
}

case "$AGENT" in
  pi) LINKS=(.pi) ;;
  claude) LINKS=(.claude .claude.json) ;;
  codex) LINKS=(.codex) ;;
  *) refuse "unsupported agent '$AGENT' (supported: pi, claude, codex); invoke through bin/nm-agent-home/<agent>" ;;
esac
LINKS+=(.gitconfig .config/git .config/gh)

REAL_HOME=${HOME:-}
[ -n "$REAL_HOME" ] && [ -d "$REAL_HOME" ] || refuse "HOME is unset or missing; cannot locate $AGENT's config"

# Resolve the real agent from PATH with this script's directories removed, and
# refuse anything that resolves back to this script.
search_path=
IFS=: read -ra path_dirs <<< "${PATH:-}"
for dir in "${path_dirs[@]}"; do
  [ -n "$dir" ] || continue
  real_dir=$(cd "$dir" 2>/dev/null && pwd -P) || continue
  if [ "$real_dir" = "$SELF_DIR" ] || [ "$real_dir" = "$INVOKED_DIR" ]; then
    continue
  fi
  search_path=${search_path:+$search_path:}$dir
done
REAL_AGENT=$(PATH=$search_path command -v "$AGENT" 2>/dev/null) || REAL_AGENT=
[ -n "$REAL_AGENT" ] || refuse "no real $AGENT found on PATH outside $INVOKED_DIR"
[ "$(readlink -f "$REAL_AGENT")" != "$SELF" ] || refuse "$AGENT on PATH resolves back to this launcher"

ROOT_TMP=${TMPDIR:-/tmp}
ROOT_TMP=${ROOT_TMP%/}

# Prune launch HOMEs left by agents that have exited. rm -rf removes symlinks
# themselves and never descends through them.
for old in "$ROOT_TMP"/fm-nm-agent-home.*; do
  [ -d "$old" ] && [ ! -L "$old" ] && [ -O "$old" ] || continue
  [ -f "$old/.fm-nm-agent-pid" ] || continue
  old_pid=$(head -n1 "$old/.fm-nm-agent-pid" 2>/dev/null) || continue
  case "$old_pid" in '' | *[!0-9]*) continue ;; esac
  kill -0 "$old_pid" 2>/dev/null && continue
  rm -rf -- "$old"
done

SANDBOX=$(mktemp -d "$ROOT_TMP/fm-nm-agent-home.XXXXXXXX") || refuse "could not create a throwaway HOME under $ROOT_TMP"
chmod 700 "$SANDBOX" || refuse "could not make $SANDBOX private"
printf '%s\n' "$$" > "$SANDBOX/.fm-nm-agent-pid" || refuse "could not record the launch in $SANDBOX"

for rel in "${LINKS[@]}"; do
  [ -e "$REAL_HOME/$rel" ] || continue
  case "$rel" in */*) mkdir -p "$SANDBOX/${rel%/*}" || refuse "could not prepare $SANDBOX/${rel%/*}" ;; esac
  ln -s "$REAL_HOME/$rel" "$SANDBOX/$rel" || refuse "could not link $rel into $SANDBOX"
done

for name in $(compgen -e); do
  case "$name" in SOPS_AGE_*) unset "$name" ;; esac
done
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

export HOME="$SANDBOX"
exec "$REAL_AGENT" "$@"
