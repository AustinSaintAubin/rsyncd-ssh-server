#!/bin/sh
set -eu

config_path="${RSYNCD_CONFIG_PATH:-/config/rsyncd.conf}"
generated_config_path="/etc/rsyncd.conf"
secret_source="/run/secrets/rsyncd_secrets"
secret_target="/etc/rsyncd.secrets"
rsyncd_users="${RSYNCD_USERS:-}"

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

normalize_bool() {
  value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

  case "$value" in
    true|yes|1)
      printf 'yes\n'
      ;;
    false|no|0)
      printf 'no\n'
      ;;
    *)
      echo "error: invalid boolean value '$1'" >&2
      exit 1
      ;;
  esac
}

require_secret_user() {
  username="$1"

  if ! awk -F: -v username="$username" 'NF >= 2 && $1 == username { found = 1 } END { exit found ? 0 : 1 }' "$secret_target"; then
    echo "error: active secrets file must contain credentials for user '$username'" >&2
    exit 1
  fi
}

validate_module_path() {
  module_path="$1"

  case "$module_path" in
    "")
      echo "error: module path cannot be empty" >&2
      exit 1
      ;;
    *".."*)
      echo "error: module path cannot contain '..': $module_path" >&2
      exit 1
      ;;
  esac
}

resolve_module_path() {
  module_path="$1"

  case "$module_path" in
    /*)
      printf '%s\n' "$module_path"
      ;;
    .)
      printf '/data\n'
      ;;
    *)
      printf '/data/%s\n' "$module_path"
      ;;
  esac
}

install -d -m 0755 /data /var/run/rsync

if [ -n "$rsyncd_users" ]; then
  : > "$secret_target"

  while IFS= read -r user_line || [ -n "$user_line" ]; do
    user_line=$(trim "$user_line")
    [ -n "$user_line" ] || continue

    case "$user_line" in
      *:*)
        username=$(trim "${user_line%%:*}")
        password=${user_line#*:}
        ;;
      *)
        echo "error: invalid RSYNCD_USERS entry (expected username:password): $user_line" >&2
        exit 1
        ;;
    esac

    if [ -z "$username" ] || [ -z "$password" ]; then
      echo "error: invalid RSYNCD_USERS entry (missing username or password): $user_line" >&2
      exit 1
    fi

    printf '%s:%s\n' "$username" "$password" >> "$secret_target"
  done <<EOF
$rsyncd_users
EOF

  chmod 0600 "$secret_target"
elif [ -f "$secret_source" ]; then
  install -m 0600 "$secret_source" "$secret_target"
fi

if [ -f "$config_path" ]; then
  echo "Using custom rsyncd config from $config_path"
  exec rsync --daemon --no-detach --config="$config_path"
fi

if [ ! -f "$secret_target" ]; then
  echo "error: neither RSYNCD_USERS nor $secret_source was provided" >&2
  exit 1
fi

rsyncd_modules="${RSYNCD_MODULES:-}"
if [ -z "$rsyncd_modules" ]; then
  rsyncd_modules="${RSYNCD_MODULE_NAME:-synology}|.|${RSYNCD_AUTH_USER:-synobackup}|false|true|false|${RSYNCD_MODULE_COMMENT:-Synology Hyper Backup target}"
fi

cat > "$generated_config_path" <<EOF
uid = ${RSYNCD_UID:-root}
gid = ${RSYNCD_GID:-root}
reverse lookup = no
max connections = ${RSYNCD_MAX_CONNECTIONS:-4}
timeout = ${RSYNCD_TIMEOUT:-600}
log file = /dev/stdout
pid file = /var/run/rsync/rsyncd.pid

EOF

module_count=0

while IFS= read -r module_line || [ -n "$module_line" ]; do
  module_line=$(trim "$module_line")
  [ -n "$module_line" ] || continue

  IFS='|' read -r module_name module_data_path auth_users read_only list_module use_chroot comment extra <<EOF
$module_line
EOF

  if [ -n "${extra:-}" ]; then
    echo "error: invalid module definition (too many fields): $module_line" >&2
    exit 1
  fi

  module_name=$(trim "${module_name:-}")
  module_data_path=$(trim "${module_data_path:-}")
  auth_users=$(trim "${auth_users:-}")
  read_only=$(trim "${read_only:-}")
  list_module=$(trim "${list_module:-}")
  use_chroot=$(trim "${use_chroot:-}")
  comment=$(trim "${comment:-}")

  if [ -z "$module_name" ] || [ -z "$module_data_path" ] || [ -z "$auth_users" ] || [ -z "$read_only" ] || [ -z "$list_module" ] || [ -z "$use_chroot" ]; then
    echo "error: invalid module definition (missing required fields): $module_line" >&2
    exit 1
  fi

  validate_module_path "$module_data_path"
  read_only=$(normalize_bool "$read_only")
  list_module=$(normalize_bool "$list_module")
  use_chroot=$(normalize_bool "$use_chroot")
  module_path=$(resolve_module_path "$module_data_path")

  install -d -m 0755 "$module_path"

  while IFS= read -r module_user || [ -n "$module_user" ]; do
    module_user=$(trim "$module_user")
    [ -n "$module_user" ] || continue
    require_secret_user "$module_user"
  done <<EOF
$(printf '%s' "$auth_users" | tr ',' '\n')
EOF

  cat >> "$generated_config_path" <<EOF
[$module_name]
    path = $module_path
    comment = $comment
    auth users = $auth_users
    secrets file = $secret_target
    read only = $read_only
    list = $list_module
    use chroot = $use_chroot

EOF

  module_count=$((module_count + 1))
done <<EOF
$rsyncd_modules
EOF

if [ "$module_count" -eq 0 ]; then
  echo "error: no rsync modules were generated" >&2
  exit 1
fi

exec rsync --daemon --no-detach --config="$generated_config_path"
