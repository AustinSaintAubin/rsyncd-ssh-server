#!/bin/sh
set -eu

generated_config_path="/etc/ssh/sshd_config.generated"
state_dir="${RSYNC_SSH_STATE_DIR:-/state}"
host_key_dir="$state_dir/host_keys"
rsync_ssh_users="${RSYNC_SSH_USERS:-}"
next_uid="${RSYNC_SSH_UID_START:-2000}"

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

validate_user_path() {
  user_path="$1"

  case "$user_path" in
    *".."*)
      echo "error: SSH user path cannot contain '..': $user_path" >&2
      exit 1
      ;;
  esac
}

resolve_user_path() {
  username="$1"
  user_path="$2"

  case "$user_path" in
    "")
      printf '/data/%s\n' "$username"
      ;;
    /*)
      printf '%s\n' "$user_path"
      ;;
    .)
      printf '/data/%s\n' "$username"
      ;;
    *)
      printf '/data/%s\n' "$user_path"
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

install -d -m 0755 /data /run/sshd /var/run/sshd "$state_dir" "$host_key_dir"

if [ -z "$rsync_ssh_users" ]; then
  echo "error: RSYNC_SSH_USERS must be set when starting the rsync-ssh service" >&2
  exit 1
fi

ensure_host_key rsa
ensure_host_key ed25519

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
  home_path=$(resolve_user_path "$username" "$user_path")

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
  fi

  if ! id "$username" >/dev/null 2>&1; then
    adduser -D -h "$home_path" -s /bin/sh -G "$username" -u "$uid" "$username"
  fi

  printf '%s:%s\n' "$username" "$password" | chpasswd
  chown "$uid:$gid" "$home_path"

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
Subsystem sftp internal-sftp
EOF

exec /usr/sbin/sshd -D -e -f "$generated_config_path"
