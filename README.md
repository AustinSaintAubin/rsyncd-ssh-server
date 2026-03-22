# rsyncd & rsyncd SSH Service Backup Target

Small Docker setup for an `rsyncd` backup target, with an optional `rsync` over SSH service for encrypted Synology Hyper Backup connections and similar.

## Setup

Edit the example files for your environment and rename them if you want the conventional names, for example `docker-compose.example.env` to `.env` and `secrets/rsyncd.example.secrets` to `secrets/rsyncd.secrets`.

Generate a password with:

```bash
openssl rand -base64 68 | tr -dc 'A-Za-z0-9' | head -c 64
```

Create the host data directory from `RSYNCD_HOST_DATA_DIR`, then start the stack with the example env file:

```bash
docker compose --file docker-compose.yaml --env-file docker-compose.example.env up --detach --build
```

If you renamed the env file to `.env`, you can just run:

```bash
docker compose up --detach --build
```

To also start the optional SSH service:

```bash
docker compose --profile ssh --file docker-compose.yaml --env-file docker-compose.example.env up --detach --build
```

Use either `RSYNCD_USERS` in the env file or mount `secrets/rsyncd.secrets` at `/run/secrets/rsyncd_secrets`. SSH users are derived from `RSYNCD_USERS` or the secrets file plus `RSYNCD_MODULES`. `RSYNC_SSH_USERS` is only needed if you want to override that behavior.

## Synology

For plain `rsyncd`:

- Server type: `rsync-compatible server`
- Server name or IP: your Docker host
- Port: `873` or `RSYNCD_PORT`
- Username: a user allowed by the target module
- Password: the matching password from `RSYNCD_USERS` or the secrets file
- Backup module: the module name

For encrypted transport over SSH:

- Server type: `rsync-compatible server`
- Transfer encryption: `On`
- Server name or IP: your Docker host
- Port: `2222` or `RSYNC_SSH_PORT`
- Username: the SSH user for that module
- Password: the matching SSH password
- Backup module: the rsync module name, for example `nas-01`
- Directory: leave blank unless you intentionally want a subfolder inside that module

The SSH container serves Synology's `rsync --server --daemon .` flow and proxies local `127.0.0.1:873` back to the `rsyncd` service so encrypted Hyper Backup connections can still reach the rsync modules.

## Testing

List available modules from the host:

```bash
rsync rsync://SERVER_IP_HOSTNAME:873/
```

Or from inside the `rsyncd` container:

```bash
docker exec rsyncd-server rsync rsync://127.0.0.1/
```

List files in an example module:

```bash
rsync rsync://servers_user@SERVER_IP_HOSTNAME:873/servers-main/
```

List files in an example module with a password file:

```bash
chmod 600 secrets/rsync.example.pass
rsync --password-file=secrets/rsync.example.pass rsync://servers_user@SERVER_IP_HOSTNAME:873/servers-main/
```

Test the Synology-style SSH flow by listing modules:

```bash
rsync -e 'ssh -p 2222' nas-01@SERVER_IP_HOSTNAME::
```

Then list one module:

```bash
rsync -e 'ssh -p 2222' nas-01@SERVER_IP_HOSTNAME::nas-01
```

## Troubleshooting

- If Synology says SSH authentication failed, type the password manually and confirm it matches the user in `RSYNCD_USERS` or the active secrets file.
- If SSH login works but Synology cannot find modules, test the same flow manually with `rsync -e 'ssh -p 2222' USER@HOST::`.
- If you see `rsync: did not see server greeting`, the SSH service is not successfully handling the `rsync --server --daemon .` flow yet.
- A simple working pattern is one SSH user per backup module, for example `nas-01` -> `nas-01`.

Check logs with:

```bash
docker compose logs --tail 200 rsyncd rsync-ssh
```
