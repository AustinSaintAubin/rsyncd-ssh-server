# rsyncd Backup Target

Small Docker setup for a real `rsyncd` daemon that works well as a backup destination for Synology Hyper Backup and other rsync clients.

## Setup

1. Copy `docker-compose.example.env` to `.env`.
2. Create the host backup directory from `RSYNCD_HOST_DATA_DIR`.
3. Copy `secrets/rsyncd.secrets.example` to `secrets/rsyncd.secrets`.
4. Add one `username:password` line per rsync user in the secret file.
5. Edit `RSYNCD_MODULES` in `docker-compose.yaml`.
6. Start the service:

```bash
docker compose up -d --build
```

The compose project name, port, host storage path, and global daemon settings come from `.env`. `RSYNCD_MODULES` stays in `docker-compose.yaml` because Compose `.env` files do not support multiline values.

Each `RSYNCD_MODULES` line uses:

```text
MODULE_NAME|RELATIVE_DATA_PATH|AUTH_USERS|READ_ONLY|LIST|USE_CHROOT|COMMENT
```

`RELATIVE_DATA_PATH` is relative to `/data`, which is backed by `RSYNCD_HOST_DATA_DIR`. `AUTH_USERS` may contain one user or a comma-separated list of users that exist in `secrets/rsyncd.secrets`.

Example:

```yaml
RSYNCD_MODULES: |
  synology_main|synology-main|synobackup|false|true|false|Main Synology backup target
  paige_archive|paige-archive|paigeuser|false|false|false|Paige archive target
  readonly_seed|readonly-seed|seeduser|true|true|false|Read-only seed module
```

If you mount a custom config file to `/config/rsyncd.conf`, the container will use that instead of generating one.

## Usage

Connect clients to:

```text
rsync://<AUTH_USER>@<host>:<RSYNCD_PORT>/<MODULE_NAME>
```

For Synology Hyper Backup, use:

- Server type: `rsync-compatible server`
- Server name: your Docker host
- Port: `RSYNCD_PORT`
- Username: one of the users named in `RSYNCD_MODULES`
- Password: value from `secrets/rsyncd.secrets`
- Shared folder: the module name you want to target

## Testing

List available modules:

```bash
rsync rsync://localhost:873/
```

Send a test file against the default example module in `docker-compose.yaml`:

```bash
mkdir -p /tmp/rsyncd-test
printf 'hello\n' > /tmp/rsyncd-test/hello.txt
rsync -av /tmp/rsyncd-test/ rsync://synobackup@localhost:873/synology
```

Check logs:

```bash
docker compose logs -f
```
