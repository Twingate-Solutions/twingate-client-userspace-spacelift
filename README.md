# Twingate Userspace + Proxytunnel on Spacelift

Access private databases (Postgres, MySQL, etc.) from [Spacelift](https://spacelift.io) CI/CD runners through [Twingate](https://www.twingate.com) — without root, TUN devices, or NET_ADMIN capabilities.

This repo contains a working example of Twingate's [userspace networking mode](https://www.twingate.com/docs/linux-userspace-networking) integrated with Spacelift, plus a Docker Compose setup for local validation.

## How It Works

Twingate's userspace mode runs as an HTTP CONNECT proxy — no kernel-level networking required. [Proxytunnel](https://github.com/proxytunnel/proxytunnel) bridges the gap between TCP-based tools (like `psql`) and the HTTP proxy:

```
psql --> proxytunnel (TCP :5432) --> twingated (HTTP proxy :9999) --> Twingate network --> your-database:5432
```

On Spacelift, all three components run as processes inside a single runner container. The `init.sh` script (baked into the image) starts everything automatically:

```
+----------------------------------------------------------+
|  Spacelift Runner (user spacelift, UID 1983)             |
|                                                          |
|  init.sh starts:                                         |
|    twingated --http-proxy 127.0.0.1:9999 --tun off       |
|    proxytunnel --standalone=$TUNNEL_LOCAL_PORT            |
|               --proxy=127.0.0.1:9999                     |
|               --dest=$TUNNEL_DEST                        |
|                                                          |
|  Then Spacelift runs your commands:                      |
|    psql -h 127.0.0.1 -p $TUNNEL_LOCAL_PORT               |
|    terraform apply (with provider pointing to localhost)  |
+----------------------------------------------------------+
```

No `--privileged`, no `NET_ADMIN`, no `/dev/net/tun`, no root.

**HTTP-proxy-only mode:** If `TUNNEL_DEST` is not set, `init.sh` only starts the Twingate HTTP proxy. Tools that support `http_proxy`/`https_proxy` env vars can use it directly without proxytunnel.

## Repository Structure

```
.
├── Dockerfile                    # Custom Spacelift runner image
├── init.sh                       # Startup script (baked into image)
├── docker-compose.yml            # Local validation with 3 services
├── .env.example                  # Template for docker-compose env vars
├── .spacelift/
│   └── config.yml                # Runner image + before_init hook
├── main.tf                       # Minimal Terraform config for the stack
├── .github/
│   └── workflows/
│       └── docker-build.yml      # CI: build on PR, push on merge to main
├── LICENSE
└── README.md
```

## Environment Variables

| Variable | Required | Secret | Default | Description |
|---|---|---|---|---|
| `TWINGATE_SERVICE_KEY` | Yes | Yes | — | Full JSON content of your Twingate service key |
| `TUNNEL_DEST` | No | No | — | Private resource address, e.g. `db.internal:5432`. If unset, only the HTTP proxy starts |
| `TUNNEL_LOCAL_PORT` | If `TUNNEL_DEST` set | No | — | Local port the tunnel listens on |
| `TWINGATE_PROXY_PORT` | No | No | `9999` | Internal Twingate HTTP proxy port |
| `DB_USER` | For smoke test | No | — | DB username (Docker Compose smoke test only) |
| `DB_PASSWORD` | For smoke test | Yes | — | DB password (Docker Compose smoke test only) |
| `DB_NAME` | For smoke test | No | — | DB name (Docker Compose smoke test only) |

## Prerequisites

- A [Twingate](https://www.twingate.com) account with a resource configured for your database
- A Twingate [service account](https://www.twingate.com/docs/services) with access to that resource
- A Twingate [connector](https://www.twingate.com/docs/connectors) running in the same network as your database
- A [Spacelift](https://spacelift.io) account (free trial works)
- A [Docker Hub](https://hub.docker.com) account (for hosting the runner image)

## Quick Start: Docker Compose

Use this to validate the setup locally before deploying to Spacelift.

### 1. Configure environment

```bash
cp .env.example .env
```

Edit `.env` and fill in **all** values, including `TWINGATE_SERVICE_KEY` (paste the full JSON content of your service key).

### 2. Start the stack

```bash
docker compose up
```

This starts three services:
- **twingate-client** — Twingate HTTP proxy (official `twingate/client:latest` image)
- **db-local** — proxytunnel bridge (TCP tunnel through the proxy)
- **app** — psql smoke test (runs a query and exits)

### 3. Test from host

Once running, you can also connect from your host machine:

```bash
PGPASSWORD='your_password' psql -h localhost -p 5432 -U postgres -d postgres \
  -c "SELECT 1 AS connection_ok, now(), version();"
```

## Quick Start: Spacelift

### 1. Build and push the runner image

```bash
# Build for AMD64 (Spacelift public workers are AMD64)
docker build --platform linux/amd64 -t <your-dockerhub-username>/spacelift-twingate:latest .
docker push <your-dockerhub-username>/spacelift-twingate:latest
```

Or let GitHub Actions handle it (see [CI Setup](#ci-setup) below).

### 2. Update `.spacelift/config.yml`

Replace the `runner_image` with your Docker Hub image:

```yaml
version: "2"
stack_defaults:
  runner_image: <your-dockerhub-username>/spacelift-twingate:latest
  before_init:
    - "init.sh"
```

### 3. Create a Spacelift stack

1. Connect your GitHub repo to Spacelift
2. Create a new stack pointing at this repo (branch: `main`, vendor: Terraform)
3. Set the runner image to your pushed image
4. Add environment variables (via stack settings or a shared Context):

| Variable | Value | Secret |
|---|---|---|
| `TWINGATE_SERVICE_KEY` | Full JSON content of your service key | Yes |
| `TUNNEL_DEST` | `your-database-host:5432` | No |
| `TUNNEL_LOCAL_PORT` | `5432` | No |
| `DB_USER` | Your DB username (for testing) | No |
| `DB_PASSWORD` | Your DB password (for testing) | Yes |
| `DB_NAME` | Your DB name (for testing) | No |

### 4. Testing on Spacelift

Go to your stack's **Tasks** tab and run:

```
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -p "$TUNNEL_LOCAL_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1 AS connection_ok, now(), version();"
```

Expected output: a row with `connection_ok = 1`.

To check logs, run these as Tasks:

```
cat /tmp/twingate.log
```

```
cat /tmp/proxytunnel.log
```

## CI Setup

The GitHub Actions workflow (`.github/workflows/docker-build.yml`) automatically builds the runner image:

- **On PR** (when `Dockerfile`, `init.sh`, or the workflow changes): builds the image to verify it compiles, but does not push
- **On push to main** (when those files change): builds and pushes to Docker Hub with `latest` and commit SHA tags

### Required GitHub Secrets

Add these to your repo under Settings > Secrets and variables > Actions:

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | A Docker Hub [access token](https://docs.docker.com/security/for-developers/access-tokens/) |

## Spacelift `config.yml` Explained

The `before_init` hook runs before every Spacelift job (Tasks, Terraform runs, etc.):

```yaml
before_init:
  - "init.sh"
```

The `init.sh` script (baked into the runner image at `/usr/local/bin/init.sh`) handles everything:

1. Starts `twingated` as an HTTP CONNECT proxy on `127.0.0.1:9999` (twingated reads `TWINGATE_SERVICE_KEY` from the environment natively — no file needed)
2. Waits for the proxy to come online and verifies it's listening
3. If `TUNNEL_DEST` is set, starts `proxytunnel` to bridge TCP through the proxy
4. Reports the tunnel endpoint

To view logs after a run, execute a Task: `cat /tmp/twingate.log`

## Dockerfile Explained

The custom runner image is based on Ubuntu 22.04 and includes:

- **Twingate client** (`twingated`) — installed via `curl install.sh | bash` (architecture-safe, works on both AMD64 and ARM64)
- **proxytunnel** — bridges TCP through HTTP CONNECT
- **postgresql-client** (`psql`) — for testing database connectivity
- **procps** — provides `ps`, which Spacelift requires

Key details:

- `/run/user/1983` is pre-created for the Twingate client's IPC socket
- `/etc/twingate` is **not** needed — `twingated` reads the service key from the `TWINGATE_SERVICE_KEY` environment variable natively
- The `spacelift` user (UID 1983) has a home directory (required for Spacelift's `.terraformrc`)
- `init.sh` is copied to `/usr/local/bin/init.sh` and made executable

## Adapting for Other Databases

This pattern works for any TCP protocol, not just Postgres. To connect to MySQL on port 3306:

1. Set `TUNNEL_DEST` to `your-mysql-host:3306`
2. Set `TUNNEL_LOCAL_PORT` to `3306`
3. Install `mysql-client` instead of (or in addition to) `postgresql-client` in the Dockerfile
4. Connect with: `mysql -h 127.0.0.1 -P 3306 -u user -p`

## Troubleshooting

| Issue | Solution |
|---|---|
| `invalid runner image` | Check `runner_image` in config.yml — must be a plain image reference with no placeholders. Click **Sync** on the stack after updating. |
| `.terraformrc: no such file or directory` | The Dockerfile used `--no-create-home`. Remove that flag, rebuild, push. |
| `Permission denied` on `/run/user/1983` | Add `mkdir -p` + `chown 1983:1983` lines to the Dockerfile for that path. |
| `sh: Syntax error: "&&" unexpected` | Background processes (`&`) conflict with Spacelift's hook chaining in `dash`. This is why we use `init.sh` instead of inline hooks. |
| Run appears stuck at "Initializing" | Twingate client logs are flooding the console. Logs are redirected to `/tmp/twingate.log` by default in `init.sh`. |
| `TWINGATE_SERVICE_KEY not set` | Make sure the env var is set (not empty) in Spacelift stack settings, marked as secret. |
| `init.sh: not found` | Make sure the runner image was rebuilt and pushed after adding `init.sh`. |
| `tunnel not ready` | The tunnel often connects a few seconds after init. Increase `sleep 12` in `init.sh` if needed. |
| Need to see Twingate logs | Run a Task: `cat /tmp/twingate.log` |
| Need to see proxytunnel logs | Run a Task: `cat /tmp/proxytunnel.log` |

## References

- [Twingate Userspace Networking](https://www.twingate.com/docs/linux-userspace-networking)
- [Twingate Headless Client](https://www.twingate.com/docs/services-headless-clients)
- [Spacelift Runtime Configuration](https://docs.spacelift.io/concepts/configuration/runtime-configuration)
- [Spacelift Docker Integration](https://docs.spacelift.io/integrations/docker)
- [Spacelift Tasks](https://docs.spacelift.io/concepts/run/task)

## License

[MIT](LICENSE)
