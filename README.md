# rsyncd Backup Target

Small Docker setup for a real `rsyncd` daemon that works well as a backup destination for Synology Hyper Backup and other rsync clients.

## Setup

1. Copy `docker-compose.example.env` to `.env`.
2. Create the host backup directory from `RSYNCD_HOST_DATA_DIR`.
3. Set `RSYNCD_USERS` and `RSYNCD_MODULES` in `.env` or your `--env-file`.
4. Optionally, instead of `RSYNCD_USERS`, mount a file to `/run/secrets/rsyncd_secrets`.
5. Optionally build the image first:

```bash
docker compose --file docker-compose.yaml --env-file .env build
```

6. Start the service:

```bash
docker compose --file docker-compose.yaml --env-file .env up --detach --build
```

The compose project name, port, host storage path, global daemon settings, `RSYNCD_USERS`, and `RSYNCD_MODULES` all come from `.env` or `--env-file`.

Useful global settings exposed via env include:
- `RSYNCD_ADDRESS` -> `address`
- `RSYNCD_LISTEN_BACKLOG` -> `listen backlog`
- `RSYNCD_MAX_CONNECTIONS` -> `max connections`
- `RSYNCD_TIMEOUT` -> `timeout`
- `RSYNCD_STRICT_MODES` -> `strict modes`
- `RSYNCD_LOGGING_TRANSFER` -> `transfer logging`
- `RSYNCD_LOGGING_FORMAT` -> `log format`

Each `RSYNCD_MODULES` line uses:

```text
MODULE_NAME|MODULE_PATH|AUTH_USERS|READ_ONLY|LIST|USE_CHROOT|COMMENT
```

If `MODULE_PATH` starts with `/`, it is treated as an absolute path and used as-is. If it is empty or `.`, the module uses the root `/data` directory. Otherwise it is treated as relative to `/data`, which is backed by `RSYNCD_HOST_DATA_DIR`. Relative paths may be nested, for example `synology/main` becomes `/data/synology/main`. `AUTH_USERS` may contain one user or a comma-separated list of users.

`RSYNCD_USERS` uses one `username:password` pair per line. If `RSYNCD_USERS` is set, the container generates `/etc/rsyncd.secrets` at startup and overwrites any previously generated copy. If `RSYNCD_USERS` is unset, the container will use `/run/secrets/rsyncd_secrets` when that file is mounted.

Env-only `.env` syntax:

```dotenv
RSYNCD_USERS='synobackup:replace-with-a-long-random-password
readonlyuser:replace-with-a-different-password'

RSYNCD_MODULES='synology_main|synology/main|synobackup,readonlyuser|false|true|false|Main Synology backup target
readonly_seed||readonlyuser|true|true|false|Read-only seed module
nas-00|/mnt/testing|nas-00_user|false|true|false|Synology NAS-00 backup target'
```

Treat `RSYNCD_MODULES` as one variable whose value contains newline-separated module definitions. Do not expect multiple `RSYNCD_MODULES=` entries to merge. Treat `RSYNCD_USERS` the same way: one multiline variable, not multiple merged entries.

Optional file-based secrets:

```text
/run/secrets/rsyncd_secrets
```

That file should contain one `username:password` pair per line, for example:

```text
synobackup:replace-with-a-long-random-password
readonlyuser:replace-with-a-different-password
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
- Password: the matching password from `RSYNCD_USERS` or `/run/secrets/rsyncd_secrets`
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
