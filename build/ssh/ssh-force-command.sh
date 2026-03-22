#!/bin/sh
set -eu

trace_file="${RSYNC_SSH_TRACE_FILE:-/tmp/ssh-command-trace.log}"
original_command="${SSH_ORIGINAL_COMMAND:-}"
module_definitions_path="${RSYNC_SSH_MODULES_PATH:-/etc/rsyncd.modules}"

timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
user_name="$(id -un)"
pwd_path="$(pwd)"
home_path="${HOME:-}"

echo "[ssh-force] user=$user_name original_command=$original_command" >&2

trace_dir="$(dirname "$trace_file")"
if mkdir -p "$trace_dir" 2>/dev/null; then
  printf '%s user=%s home=%s pwd=%s original_command=%s\n' \
    "$timestamp" "$user_name" "$home_path" "$pwd_path" "$original_command" >> "$trace_file" 2>/dev/null || true
fi

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

normalize_bool() {
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    true|yes|1)
      printf 'yes\n'
      ;;
    false|no|0)
      printf 'no\n'
      ;;
    *)
      printf 'no\n'
      ;;
  esac
}

resolve_data_path() {
  data_path="$1"

  case "$data_path" in
    "")
      printf '/data\n'
      ;;
    /*)
      printf '%s\n' "$data_path"
      ;;
    .)
      printf '/data\n'
      ;;
    *)
      printf '/data/%s\n' "$data_path"
      ;;
  esac
}

user_allowed_for_module() {
  current_user="$1"
  auth_users="$2"

  while IFS= read -r candidate || [ -n "$candidate" ]; do
    candidate="$(trim "$candidate")"
    [ -n "$candidate" ] || continue

    if [ "$candidate" = "$current_user" ]; then
      return 0
    fi
  done <<EOF
$(printf '%s' "$auth_users" | tr ',' '\n')
EOF

  return 1
}

generate_user_rsyncd_config() {
  current_user="$1"
  config_path="/tmp/rsyncd-ssh-${current_user}.conf"
  module_count=0

  if [ ! -f "$module_definitions_path" ]; then
    echo "[ssh-force] module definitions file not found: $module_definitions_path" >&2
    exit 1
  fi

  cat > "$config_path" <<EOF
reverse lookup = no
use chroot = no
transfer logging = yes
log file = /dev/stderr

EOF

  while IFS= read -r module_line || [ -n "$module_line" ]; do
    module_line="$(trim "$module_line")"
    [ -n "$module_line" ] || continue

    IFS='|' read -r module_name module_data_path auth_users read_only list_module use_chroot comment extra <<EOF
$module_line
EOF

    module_name="$(trim "${module_name:-}")"
    module_data_path="$(trim "${module_data_path:-}")"
    auth_users="$(trim "${auth_users:-}")"
    read_only="$(trim "${read_only:-}")"
    list_module="$(trim "${list_module:-}")"
    use_chroot="$(trim "${use_chroot:-}")"
    comment="$(trim "${comment:-}")"

    [ -n "$module_name" ] || continue
    [ -n "$auth_users" ] || continue

    if ! user_allowed_for_module "$current_user" "$auth_users"; then
      continue
    fi

    module_path="$(resolve_data_path "$module_data_path")"

    cat >> "$config_path" <<EOF
[$module_name]
    path = $module_path
    comment = $comment
    read only = $(normalize_bool "$read_only")
    list = $(normalize_bool "$list_module")
    use chroot = $(normalize_bool "$use_chroot")

EOF
    module_count=$((module_count + 1))
  done < "$module_definitions_path"

  if [ "$module_count" -eq 0 ]; then
    echo "[ssh-force] no rsync modules available for user=$current_user" >&2
    exit 1
  fi

  printf '%s\n' "$config_path"
}

case "$original_command" in
  "rsync --server --daemon ."*)
    config_path="$(generate_user_rsyncd_config "$user_name")"
    echo "[ssh-force] user=$user_name using rsyncd config $config_path for command=$original_command" >&2
    exec rsync --server --daemon --config="$config_path" .
    ;;
esac

if [ -n "$original_command" ]; then
  exec /bin/sh -c "$original_command"
fi

exec /bin/sh
