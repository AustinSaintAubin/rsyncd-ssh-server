#!/bin/sh
set -eu

generated_config_path="/etc/ssh/sshd_config.generated"
module_definitions_path="/etc/rsyncd.modules"
state_dir="${RSYNC_SSH_STATE_DIR:-/state}"
host_key_dir="$state_dir/host_keys"
secret_source="/run/secrets/rsyncd_secrets"
secret_target="/etc/rsyncd.secrets"
rsyncd_users="${RSYNCD_USERS:-}"
rsyncd_modules="${RSYNCD_MODULES:-}"
rsync_ssh_users="${RSYNC_SSH_USERS:-}"
next_uid="${RSYNC_SSH_UID_START:-2000}"
rsync_proxy_enabled="${RSYNC_SSH_RSYNC_PROXY_ENABLED:-true}"
rsync_proxy_host="${RSYNC_SSH_RSYNC_TARGET_HOST:-rsyncd}"
rsync_proxy_port="${RSYNC_SSH_RSYNC_TARGET_PORT:-873}"
rsync_ssh_log_level="${RSYNC_SSH_LOG_LEVEL:-INFO}"

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

emit_force_command() {
  printf 'ForceCommand /usr/local/bin/ssh-force-command.sh\n'
}

start_rsync_proxy() {
  if [ "$(normalize_bool "$rsync_proxy_enabled")" != "yes" ]; then
    return
  fi

  echo "Starting localhost rsync proxy to ${rsync_proxy_host}:${rsync_proxy_port}"
  socat TCP-LISTEN:873,bind=127.0.0.1,fork,reuseaddr TCP:"${rsync_proxy_host}:${rsync_proxy_port}" &
}

validate_user_path() {
  user_path="$1"

  case "$user_path" in
    *".."*)
      echo "error: SSH user path cannot contain '..': $user_path" >&2
      exit 1
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

ensure_host_key() {
  key_type="$1"
  key_path="$host_key_dir/ssh_host_${key_type}_key"

  if [ ! -f "$key_path" ]; then
    ssh-keygen -q -N '' -t "$key_type" -f "$key_path"
  fi
}

require_secret_user() {
  username="$1"

  if ! awk -F: -v username="$username" 'NF >= 2 && $1 == username { found = 1 } END { exit found ? 0 : 1 }' "$secret_target"; then
    echo "error: active secrets file must contain credentials for user '$username'" >&2
    exit 1
  fi
}

prepare_secret_file() {
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
}

derive_ssh_users_from_rsync_config() {
  module_map_file=$(mktemp)
  derived_users_file=$(mktemp)
  conflict_users=""

  while IFS= read -r module_line || [ -n "$module_line" ]; do
    module_line=$(trim "$module_line")
    [ -n "$module_line" ] || continue

    IFS='|' read -r module_name module_data_path auth_users read_only list_module use_chroot comment extra <<EOF
$module_line
EOF

    if [ -n "${extra:-}" ]; then
      echo "error: invalid module definition (too many fields): $module_line" >&2
      rm -f "$module_map_file" "$derived_users_file"
      exit 1
    fi

    module_name=$(trim "${module_name:-}")
    module_data_path=$(trim "${module_data_path:-}")
    auth_users=$(trim "${auth_users:-}")
    read_only=$(trim "${read_only:-}")
    list_module=$(trim "${list_module:-}")
    use_chroot=$(trim "${use_chroot:-}")

    if [ -z "$module_name" ] || [ -z "$auth_users" ] || [ -z "$read_only" ] || [ -z "$list_module" ] || [ -z "$use_chroot" ]; then
      echo "error: invalid module definition (missing required fields): $module_line" >&2
      rm -f "$module_map_file" "$derived_users_file"
      exit 1
    fi

    validate_user_path "$module_data_path"
    module_path=$(resolve_data_path "$module_data_path")

    while IFS= read -r module_user || [ -n "$module_user" ]; do
      module_user=$(trim "$module_user")
      [ -n "$module_user" ] || continue

      require_secret_user "$module_user"

      existing_path=$(awk -F'|' -v username="$module_user" '$1 == username { print $2; exit }' "$module_map_file")

      if [ -z "$existing_path" ]; then
        printf '%s|%s\n' "$module_user" "$module_path" >> "$module_map_file"
      elif [ "$existing_path" != "$module_path" ] && [ "$existing_path" != "__CONFLICT__" ]; then
        awk -F'|' -v OFS='|' -v username="$module_user" '
          $1 == username { $2 = "__CONFLICT__" }
          { print }
        ' "$module_map_file" > "${module_map_file}.tmp"
        mv "${module_map_file}.tmp" "$module_map_file"
        conflict_users="${conflict_users}${conflict_users:+, }$module_user"
      fi
    done <<EOF
$(printf '%s' "$auth_users" | tr ',' '\n')
EOF
  done <<EOF
$rsyncd_modules
EOF

  if [ -n "$conflict_users" ]; then
    echo "warning: skipping SSH auto-derivation for user(s) with multiple module paths: $conflict_users" >&2
    echo "warning: set RSYNC_SSH_USERS explicitly if you want SSH access for those users" >&2
  fi

  while IFS=: read -r username password extra || [ -n "$username$password${extra:-}" ]; do
    username=$(trim "${username:-}")
    password=${password:-}
    [ -n "$username" ] || continue
    [ -n "$password" ] || continue

    user_path=$(awk -F'|' -v username="$username" '$1 == username { print $2; exit }' "$module_map_file")
    [ -n "$user_path" ] || continue
    [ "$user_path" != "__CONFLICT__" ] || continue

    printf '%s|%s|%s\n' "$username" "$password" "$user_path" >> "$derived_users_file"
  done < "$secret_target"

  if [ ! -s "$derived_users_file" ]; then
    echo "error: no SSH users could be derived from RSYNCD_USERS/secrets and RSYNCD_MODULES" >&2
    rm -f "$module_map_file" "$derived_users_file"
    exit 1
  fi

  cat "$derived_users_file"
  rm -f "$module_map_file" "$derived_users_file"
}

install -d -m 0755 /data /run/sshd /var/run/sshd "$state_dir" "$host_key_dir"

ensure_host_key rsa
ensure_host_key ed25519
prepare_secret_file
start_rsync_proxy

if [ -n "$rsyncd_modules" ]; then
  printf '%s\n' "$rsyncd_modules" > "$module_definitions_path"
  chmod 0644 "$module_definitions_path"
fi

if [ -z "$rsync_ssh_users" ]; then
  if [ ! -f "$secret_target" ]; then
    echo "error: set RSYNC_SSH_USERS or provide RSYNCD_USERS / $secret_source for SSH mode" >&2
    exit 1
  fi

  if [ -z "$rsyncd_modules" ]; then
    echo "error: RSYNCD_MODULES must be set when deriving SSH users automatically" >&2
    exit 1
  fi

  rsync_ssh_users=$(derive_ssh_users_from_rsync_config)
fi

allow_users=""
user_count=0

while IFS= read -r user_line || [ -n "$user_line" ]; do
  user_line=$(trim "$user_line")
  [ -n "$user_line" ] || continue

  IFS='|' read -r username password user_path uid gid extra <<EOF
$user_line
EOF

  if [ -n "${extra:-}" ]; then
    echo "error: invalid RSYNC_SSH_USERS entry (too many fields): $user_line" >&2
    exit 1
  fi

  username=$(trim "${username:-}")
  password=$(trim "${password:-}")
  user_path=$(trim "${user_path:-}")
  uid=$(trim "${uid:-}")
  gid=$(trim "${gid:-}")

  if [ -z "$username" ] || [ -z "$password" ]; then
    echo "error: invalid RSYNC_SSH_USERS entry (missing username or password): $user_line" >&2
    exit 1
  fi

  validate_user_path "$user_path"
  home_path=$(resolve_data_path "$user_path")

  if [ -z "$uid" ]; then
    uid="$next_uid"
    next_uid=$((next_uid + 1))
  fi

  if [ -z "$gid" ]; then
    gid="$uid"
  fi

  install -d -m 0755 "$home_path"

  if ! getent group "$username" >/dev/null 2>&1; then
    addgroup -g "$gid" "$username"
  elif [ "$(getent group "$username" | awk -F: '{ print $3 }')" != "$gid" ]; then
    groupmod -g "$gid" "$username"
  fi

  if ! id "$username" >/dev/null 2>&1; then
    adduser -D -h "$home_path" -s /usr/local/bin/ssh-shell-wrapper.sh -G "$username" -u "$uid" "$username"
  else
    usermod -d "$home_path" -s /usr/local/bin/ssh-shell-wrapper.sh -g "$username" -u "$uid" "$username"
  fi

  printf '%s:%s\n' "$username" "$password" | chpasswd
  if [ "$home_path" != "/data" ]; then
    chown "$uid:$gid" "$home_path"
  fi

  allow_users="${allow_users}${allow_users:+ }$username"
  user_count=$((user_count + 1))
done <<EOF
$rsync_ssh_users
EOF

if [ "$user_count" -eq 0 ]; then
  echo "error: no SSH users were created" >&2
  exit 1
fi

cat > "$generated_config_path" <<EOF
Port 22
ListenAddress 0.0.0.0
Protocol 2
LogLevel $rsync_ssh_log_level
HostKey $host_key_dir/ssh_host_rsa_key
HostKey $host_key_dir/ssh_host_ed25519_key
PasswordAuthentication $(normalize_bool "${RSYNC_SSH_PASSWORD_AUTH:-true}")
KbdInteractiveAuthentication no
PubkeyAuthentication $(normalize_bool "${RSYNC_SSH_PUBKEY_AUTH:-true}")
PermitRootLogin no
PermitEmptyPasswords no
PermitUserEnvironment no
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers $allow_users
AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no
X11Forwarding no
PrintMotd no
PidFile /var/run/sshd.pid
Subsystem sftp internal-sftp -l VERBOSE
$(emit_force_command)
EOF

exec /usr/sbin/sshd -D -e -f "$generated_config_path"
