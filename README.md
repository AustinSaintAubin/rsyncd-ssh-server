# rsyncd Backup Target

Small Docker setup for a real `rsyncd` daemon that works well as a backup destination for Synology Hyper Backup and other rsync clients.

## Setup

1. Copy `docker-compose.example.env` to `.env`.
2. Create the host backup directory from `RSYNCD_HOST_DATA_DIR`.
3. Copy `secrets/rsyncd.secrets.example` to `secrets/rsyncd.secrets`.
4. Add one `username:password` line per rsync user in the secret file.
5. Set `RSYNCD_MODULES` in `.env` or your `--env-file`.
6. Optionally build the image first:

```bash
docker compose --file docker-compose.yaml --env-file .env build
```

7. Start the service:

```bash
docker compose --file docker-compose.yaml --env-file .env up --detach --build
```

The compose project name, port, host storage path, global daemon settings, and `RSYNCD_MODULES` all come from `.env` or `--env-file`.

Each `RSYNCD_MODULES` line uses:

```text
MODULE_NAME|RELATIVE_DATA_PATH|AUTH_USERS|READ_ONLY|LIST|USE_CHROOT|COMMENT
```

`RELATIVE_DATA_PATH` is relative to `/data`, which is backed by `RSYNCD_HOST_DATA_DIR`. `AUTH_USERS` may contain one user or a comma-separated list of users that exist in `secrets/rsyncd.secrets`.

The default example is intentionally a single Hyper Backup module for `synobackup`. If you add more module lines or more auth users, add matching `username:password` entries to `secrets/rsyncd.secrets` before starting the container.

Required `.env` syntax:

```dotenv
RSYNCD_MODULES='synology_main|synology-main|synobackup|false|true|false|Main Synology backup target'
```

Treat `RSYNCD_MODULES` as one variable whose value contains newline-separated module definitions. Do not expect multiple `RSYNCD_MODULES=` entries to merge.

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

Send a test file against one of the example modules above:

```bash
mkdir --parents /tmp/rsyncd-test
printf 'hello\n' > /tmp/rsyncd-test/hello.txt
rsync --archive --verbose /tmp/rsyncd-test/ rsync://synobackup@localhost:873/synology_main
```

Check logs:

```bash
docker compose --file docker-compose.yaml --env-file .env logs --follow
```
