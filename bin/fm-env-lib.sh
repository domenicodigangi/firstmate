# shellcheck shell=bash
# Shared .env-style file accessor.
# Usage: . bin/fm-env-lib.sh
#
# This file is the single owner of the one-key .env read: the Relay pairing
# token (bin/fm-x-lib.sh and its callers) and the optional typesafe.ai
# dispatch key (bin/fm-dispatch-resolve.sh) both resolve their value through
# fmx_env_get, so those opt-in secrets in $FM_HOME/.env are parsed by one rule.
# (bin/fm-mail.sh loads its whole .env block itself under the same env-wins
# contract.) The value is printed to the caller's command substitution only;
# nothing is logged.

# fmx_env_get <key> <file>
# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fmx_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# fm_env_file_secure <file>
# A .env holds credentials, so it must be readable by its owner only (mode 600).
# When FILE exists with any group or other permission bit, remove those bits
# silently; FM_BOOTSTRAP_VERBOSE_FACTS=1 prints that as one BOOTSTRAP_INFO fact. A symlinked .env (for example one sealed under ~/.secrets/firstmate/)
# tightens its target. Returns 1 with an ENV_FILE diagnostic when chmod fails.
fm_env_file_secure() {
  local file=$1 mode
  [ -f "$file" ] || return 0
  mode=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null) || return 0
  case "$mode" in *[1-7][0-7] | *[0-7][1-7]) ;; *) return 0 ;; esac
  if chmod go-rwx "$file" 2>/dev/null; then
    [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] \
      || echo "BOOTSTRAP_INFO: tightened $file from mode $mode to owner-only because it holds credentials"
    return 0
  fi
  echo "ENV_FILE: $file is mode $mode (readable beyond its owner) and could not be tightened; run chmod 600 $file"
  return 1
}

