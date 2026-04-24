# Twingate Userspace + Proxytunnel on Spacelift 🚀

Access private databases (Postgres, MySQL, etc.) from [Spacelift](https://spacelift.io) CI/CD runners through [Twingate](https://www.twingate.com) — without root, TUN devices, or NET_ADMIN capabilities.

This repo contains a working example of Twingate's [userspace networking mode](https://www.twingate.com/docs/linux-userspace-networking) integrated with Spacelift, plus a Docker Compose setup for local validation.

## How It Works

Twingate's userspace mode runs as an HTTP CONNECT proxy — no kernel-level networking required. [Proxytunnel](https://github.com/proxytunnel/proxytunnel) bridges the gap between TCP-based tools (like `psql`) and the HTTP proxy:

```
psql → proxytunnel (TCP :5432) → Twingate client (HTTP proxy :9999) → your-database:5432
```

On Spacelift, all three components run as processes inside a single runner container:

```
┌──────────────────────────────────────────────────────────┐
│  Spacelift Runner (user spacelift, UID 1983)             │
│                                                          │
│  twingated --http-proxy 0.0.0.0:9999 --tun off      &   │
│  proxytunnel --standalone=5432 --proxy=127.0.0.1:9999    │
│              --dest=your-database:5432               &   │
│                                                          │
│  psql -h 127.0.0.1 -p 5432  (or terraform, etc.)        │
└──────────────────────────────────────────────────────────┘
```

No `--privileged`, no `NET_ADMIN`, no `/dev/net/tun`, no root.

## Repository Structure

```
.
├── Dockerfile                    # Custom Spacelift runner image
├── .spacelift/
│   └── config.yml                # Runner image + before_init hooks
├── main.tf                       # Minimal Terraform config for the stack
├── .github/
│   └── workflows/
│       └── docker-build.yml      # CI: build on PR, push on merge to main
├── LICENSE
└── README.md
```

## Prerequisites

- A [Twingate](https://www.twingate.com) account with a resource configured for your database
- A Twingate [service account](https://www.twingate.com/docs/services) with access to that resource
- A Twingate [connector](https://www.twingate.com/docs/connectors) running in the same network as your database
- A [Spacelift](https://spacelift.io) account (free trial works)
- A [Docker Hub](https://hub.docker.com) account (for hosting the runner image)

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
runner_image: <your-dockerhub-username>/spacelift-twingate:latest
```

### 3. Create a Spacelift stack

1. Connect your GitHub repo to Spacelift
2. Create a new stack pointing at this repo (branch: `main`, vendor: Terraform)
3. Set the runner image to your pushed image
4. Add these environment variables:

| Variable               | Value                                 | Secret |
| ---------------------- | ------------------------------------- | ------ |
| `TWINGATE_SERVICE_KEY` | Full JSON content of your service key | Yes    |
| `DB_DEST`              | `your-database-host:5432`             | No     |
| `DB_USER`              | Your DB username                      | No     |
| `DB_PASSWORD`          | Your DB password                      | Yes    |
| `DB_NAME`              | Your DB name                          | No     |

### 4. Run a Task

Go to your stack's **Tasks** tab and run:

```
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -p 5432 -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1 AS connection_ok, now(), version();"
```

The `before_init` hooks automatically start the Twingate client and proxytunnel before your command executes.

## CI Setup

The GitHub Actions workflow (`.github/workflows/docker-build.yml`) automatically builds the runner image:

- **On PR** (when `Dockerfile` changes): builds the image to verify it compiles, but does not push
- **On push to main** (when `Dockerfile` changes): builds and pushes to Docker Hub with `latest` and commit SHA tags

### Required GitHub Secrets

Add these to your repo under Settings > Secrets and variables > Actions:

| Secret               | Value                                                                                       |
| -------------------- | ------------------------------------------------------------------------------------------- |
| `DOCKERHUB_USERNAME` | Your Docker Hub username                                                                    |
| `DOCKERHUB_TOKEN`    | A Docker Hub [access token](https://docs.docker.com/security/for-developers/access-tokens/) |

## Spacelift `config.yml` Explained

The `before_init` hooks run before every Spacelift job (Tasks, Terraform runs, etc.):

```yaml
before_init:
  - "printenv TWINGATE_SERVICE_KEY > /etc/twingate/service_key.json"
  - "echo service key written"
  - "bash -c 'twingated --http-proxy 0.0.0.0:9999 --tun off > /tmp/twingate.log 2>&1 &'"
  - "sleep 15"
  - "bash -c 'proxytunnel --standalone=5432 --proxy=127.0.0.1:9999 --dest=$DB_DEST > /tmp/proxytunnel.log 2>&1 &'"
  - "sleep 3"
  - "pg_isready -h 127.0.0.1 -p 5432 || echo tunnel not ready"
```

What each line does:

1. Writes the service key from the Spacelift env var to the path Twingate expects
2. Starts the Twingate client in userspace HTTP proxy mode (background, logs to file)
3. Waits 15 seconds for the client to authenticate
4. Starts proxytunnel bridging TCP:5432 through the HTTP proxy (background, logs to file)
5. Waits 3 seconds for proxytunnel to start listening
6. Checks if the tunnel is accepting connections

To view Twingate logs after a run, execute a Task: `cat /tmp/twingate.log`

## Dockerfile Explained

The custom runner image is based on Ubuntu 22.04 (not Alpine, because proxytunnel isn't in Alpine's repos) and includes:

- **Twingate client** (`twingated`) — the userspace HTTP proxy
- **proxytunnel** — bridges TCP through HTTP CONNECT
- **postgresql-client** (`psql`) — for testing database connectivity
- **procps** — provides `ps`, which Spacelift requires

Key details:

- `/etc/twingate` is pre-created and owned by UID 1983 so the hooks can write the service key
- `/run/user/1983` is pre-created for the Twingate client's IPC socket
- The `spacelift` user (UID 1983) has a home directory (required for Spacelift's `.terraformrc`)

## Adapting for Other Databases

This pattern works for any TCP protocol, not just Postgres. To connect to MySQL on port 3306:

1. In `.spacelift/config.yml`, change the proxytunnel line:

   ```
   proxytunnel --standalone=3306 --proxy=127.0.0.1:9999 --dest=your-mysql-host:3306
   ```

2. Set `DB_DEST` to `your-mysql-host:3306`

3. Install `mysql-client` instead of (or in addition to) `postgresql-client` in the Dockerfile

4. Connect with: `mysql -h 127.0.0.1 -P 3306 -u user -p`

## Troubleshooting

| Issue                                                      | Solution                                                                                                                               |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `invalid runner image`                                     | Check `runner_image` in config.yml — must be a plain image reference with no placeholders. Click **Sync** on the stack after updating. |
| `.terraformrc: no such file or directory`                  | The Dockerfile used `--no-create-home`. Remove that flag, rebuild, push.                                                               |
| `Permission denied` on `/run/user/1983` or `/etc/twingate` | Add `mkdir -p` + `chown 1983:1983` lines to the Dockerfile for those paths.                                                            |
| `sh: Syntax error: "&&" unexpected`                        | Background processes (`&`) conflict with Spacelift's hook chaining in `dash`. Wrap them in `bash -c '...'`.                            |
| `cannot unmarshal !!map` in config.yml                     | Remove comments from inside the `before_init` list. Double-quote all hook lines.                                                       |
| Run appears stuck at "Initializing"                        | Twingate client logs are flooding the console. Add `> /tmp/twingate.log 2>&1` to the twingated command.                                |
| `tunnel not ready` in hooks                                | Informational — the tunnel often connects a few seconds after the check. Increase `sleep 15` if needed.                                |
| Need to see Twingate logs                                  | Run a Task: `tail -50 /tmp/twingate.log`                                                                                               |

## References

- [Twingate Userspace Networking](https://www.twingate.com/docs/linux-userspace-networking)
- [Twingate Headless Client](https://www.twingate.com/docs/services-headless-clients)
- [Spacelift Runtime Configuration](https://docs.spacelift.io/concepts/configuration/runtime-configuration)
- [Spacelift Docker Integration](https://docs.spacelift.io/integrations/docker)
- [Spacelift Tasks](https://docs.spacelift.io/concepts/run/task)

## License

[MIT](LICENSE)
