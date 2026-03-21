# rsyncd Backup Target

Small Docker setup for a real `rsyncd` daemon that works well as a backup destination for Synology Hyper Backup and other rsync clients.

It can also run an optional `rsync` over SSH service for encrypted transport.

## Setup

Edit the example files for your environment and rename them if you want the conventional names, for example `docker-compose.example.env` to `.env` and `secrets/rsyncd.example.secrets` to `secrets/rsyncd.secrets`.

```bash
openssl rand -base64 68 | tr -dc 'A-Za-z0-9' | head -c 64
```

Create the host backup directory from `RSYNCD_HOST_DATA_DIR`.

Run it with the example env file:

```bash
docker compose --file docker-compose.yaml --env-file docker-compose.example.env up --detach --build
```

If you renamed the env file to `.env`, you can use:

```bash
docker compose up --detach --build
```

To start the optional SSH-based backup service too:

```bash
docker compose --profile ssh --file docker-compose.yaml --env-file docker-compose.example.env up --detach --build rsync-ssh
```

Use either:

- `RSYNCD_USERS` in the env file, or
- a mounted `secrets/rsyncd.secrets` file at `/run/secrets/rsyncd_secrets`

If you use the secrets file approach, uncomment the example secrets mount in [`docker-compose.yaml`](/nas-01/volume1/docker/rsync-server/docker-compose.yaml). The comments in [`docker-compose.example.env`](/nas-01/volume1/docker/rsync-server/docker-compose.example.env) show the expected `RSYNCD_USERS` and `RSYNCD_MODULES` format.

For SSH mode, set `RSYNC_SSH_USERS` in the env file. Each line uses `USERNAME|PASSWORD|PATH|UID|GID`. `PATH`, `UID`, and `GID` are optional.

## Usage

Connect clients to:

```text
rsync://<AUTH_USER>@<host>:<RSYNCD_PORT>/<MODULE_NAME>
```

For Synology Hyper Backup, use:

- Server type: `rsync-compatible server`
- Server name: your Docker host
- Port: `RSYNCD_PORT`
- Username: a user allowed by the target module
- Password: the matching password from `RSYNCD_USERS` or `secrets/rsyncd.secrets`
- Shared folder: the module name you want to target

For encrypted transport with SSH, use the SSH-based backup option in Synology and connect to:

- Server name: your Docker host
- Port: `RSYNC_SSH_PORT`
- Username: one of the users in `RSYNC_SSH_USERS`
- Password: the matching SSH password
- Directory: the user path from `RSYNC_SSH_USERS`

## Testing

List available modules:
```bash
rsync rsync://SERVER_IP_HOSTNAME:873/
```

Or from inside the container:
```bash
docker exec rsyncd-server rsync rsync://127.0.0.1/
```

List files in an example module:
```bash
rsync rsync://servers_user@SERVER_IP_HOSTNAME:873/servers-main/
```

List files in an example module, using stored password
```bash
cat ../secrets/rsync.example.pass
chmod 600 ../secrets/rsync.example.pass
rsync --password-file=../secrets/rsync.example.pass rsync://servers_user@SERVER_IP_HOSTNAME:873/servers-main/
```

Test the SSH service:
```bash
ssh -p 2222 nas-03@SERVER_IP_HOSTNAME
```

Send a test file over SSH:
```bash
rsync --archive --verbose --rsh='ssh -p 2222' /tmp/rsyncd-test/ nas-03@SERVER_IP_HOSTNAME:./
```

Send a test file against one of the example modules:

```bash
mkdir --parents /tmp/rsyncd-test
printf 'hello\n' > /tmp/rsyncd-test/hello.txt
rsync --archive --verbose /tmp/rsyncd-test/ rsync://servers_user@SERVER_IP_HOSTNAME:873/servers-main
```

Follow logs:

```bash
docker compose --file docker-compose.yaml --env-file docker-compose.example.env logs --follow
```
