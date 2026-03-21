#!/bin/sh
set -eu

trace_enabled="${RSYNC_SSH_TRACE_COMMANDS:-false}"

case "$(printf '%s' "$trace_enabled" | tr '[:upper:]' '[:lower:]')" in
  true|yes|1)
    echo "[ssh-trace] user=$(id -un) home=${HOME:-} pwd=$(pwd) shell_args=$*" >&2
    echo "[ssh-trace] user=$(id -un) SSH_ORIGINAL_COMMAND=${SSH_ORIGINAL_COMMAND:-}" >&2
    ;;
esac

exec /bin/sh "$@"
