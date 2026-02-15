# Coder on Lightsail

A self-hosted [Coder](https://coder.com/) deployment for AWS Lightsail or any Ubuntu VPS.
One script sets up a production-ready remote development environment with automatic HTTPS,
persistent Docker workspaces, and an optional AI coding assistant (Claude Code via AWS Bedrock).

## Architecture

```
                    Internet
                       |
               DNS (A record)
                       |
             +-------------------+
             |   Caddy (HTTPS)   |   Automatic Let's Encrypt SSL
             +-------------------+
                       |
             +-------------------+
             |   Coder Server    |   Workspace orchestration, AI Bridge
             |   (port 7080)     |
             +-------------------+
                    /      \
     +-------------+        +-------------------+
     | PostgreSQL  |        | Docker Workspaces  |
     | (persistent)|        | (per-user)         |
     +-------------+        +-------------------+
```

Coder listens on port 7080 bound to localhost only. All external traffic goes through Caddy's HTTPS reverse proxy.

The included **agent-shell** template provisions Docker-based workspaces with:

- **Browser terminal** -- ttyd + tmux session accessible from any browser
- **Mobile terminal** -- touch-friendly terminal with on-screen key bar (Esc, Tab, Ctrl, arrows) for iOS/iPadOS
- **Claude Code CLI** -- AI coding assistant powered by AWS Bedrock
- **Developer tools** -- zsh, Starship prompt, fzf, zoxide, git, Node.js

## Prerequisites

| Requirement | Details |
|---|---|
| **VPS** | Ubuntu 24.04 LTS (AWS Lightsail, EC2, DigitalOcean, Hetzner, etc.) |
| **Domain** | A domain or subdomain with a DNS A record pointing to the server IP |
| **Ports** | 22 (SSH), 80 (HTTP), 443 (HTTPS) open in your cloud provider's firewall |
| **AWS credentials** | *Optional.* Only needed if you want Bedrock-powered AI features (Claude Code, AI Bridge) |

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/kalleeh/coder-lightsail.git
cd coder-lightsail
```

### 2. Configure environment variables

```bash
cp .env.example .env
nano .env          # or vim, or any editor
```

At minimum, set `DOMAIN` and `CODER_ACCESS_URL` to your domain:

```
DOMAIN=coder.example.com
CODER_ACCESS_URL=https://coder.example.com
```

Leave `POSTGRES_PASSWORD` as-is -- the setup script will auto-generate a secure password on first run.

See the [Configuration Reference](#configuration-reference) below for all available variables.

### 3. Run the setup script

```bash
sudo bash setup.sh
```

The script is **idempotent** (safe to re-run). It will:

1. Validate your `.env` configuration
2. Generate a secure database password (if not already set)
3. Install Docker and the Compose plugin
4. Install and configure Caddy as a reverse proxy with automatic HTTPS
5. Configure the UFW firewall (ports 22, 80, 443)
6. Start the Coder + PostgreSQL stack via Docker Compose
7. Wait for Coder to become healthy

### 4. Create your admin account

Open `https://your-domain.com` in a browser. The first user to sign up becomes the admin.

### 5. Push the workspace template

From a machine with the [Coder CLI](https://coder.com/docs/install) installed:

```bash
# Install the CLI (if needed)
curl -fsSL https://your-domain.com/install.sh | sh

# Authenticate
coder login https://your-domain.com

# Push the agent-shell template
coder templates push agent-shell --directory ./agent-shell
```

You can now create workspaces from the **agent-shell** template in the Coder dashboard.

## Configuration Reference

All configuration lives in the `.env` file. See `.env.example` for annotated defaults.

| Variable | Required | Default | Description |
|---|---|---|---|
| `DOMAIN` | Yes | `coder.example.com` | Domain name pointing to this server (no protocol prefix) |
| `CODER_ACCESS_URL` | Yes | `https://coder.example.com` | Full URL Coder uses to generate links and webhooks |
| `DOCKER_GID` | No | `999` | Docker group GID on the host; setup.sh detects this automatically |
| `CODER_VERSION` | No | `latest` | Coder server image tag; pin to a specific version for stability |
| `POSTGRES_USER` | Yes | `coder` | PostgreSQL database user |
| `POSTGRES_PASSWORD` | No | *auto-generated* | Database password; setup.sh generates one if left as the placeholder |
| `POSTGRES_DB` | Yes | `coder` | PostgreSQL database name |
| `AWS_REGION` | No | `us-east-1` | AWS region for Bedrock API calls |
| `AWS_ACCESS_KEY_ID` | No | *(empty)* | AWS access key; omit if using an IAM instance role |
| `AWS_SECRET_ACCESS_KEY` | No | *(empty)* | AWS secret key; omit if using an IAM instance role |
| `CODER_AIBRIDGE_BEDROCK_MODEL` | No | `anthropic.claude-sonnet-4-5-*` | Default Bedrock model for the AI Bridge |
| `CODER_AIBRIDGE_MODELS` | No | *(see .env.example)* | Comma-separated list of Bedrock models available to users |

## Template Customization

The workspace template lives in `agent-shell/template.tf`. Common modifications:

### Change the AWS region or Bedrock model

Edit the `env` block inside `resource "coder_agent" "main"`:

```hcl
env = {
  AWS_REGION      = "us-east-1"                                 # your region
  ANTHROPIC_MODEL = "anthropic.claude-sonnet-4-5-20250929-v1:0" # your model ID
  # ...
}
```

### Change the container image

Edit the `docker_container.workspace` resource:

```hcl
resource "docker_container" "workspace" {
  image = "codercom/enterprise-base:ubuntu"   # change to any Docker image
  # ...
}
```

### Add or remove developer tools

Modify the `startup_script` inside `resource "coder_agent" "main"`. Tools installed into
`~/.local/bin` persist across workspace restarts (the home directory is a Docker volume).
System packages installed via `apt-get` are reinstalled on each workspace rebuild.

## Cost

| Component | Estimated Monthly Cost |
|---|---|
| Lightsail instance (small: 1 vCPU, 2 GB) | $10 |
| Lightsail instance (medium: 2 vCPU, 4 GB) | $20 |
| Lightsail instance (large: 2 vCPU, 8 GB) | $40 |
| Automated snapshots (optional) | ~$8 |
| **Total** | **$10 -- $50/month** |

Any VPS provider with comparable pricing works. The stack requires at minimum 1 vCPU and 2 GB RAM.

## Project Structure

```
coder-lightsail/
  .env.example          Environment variable template (copy to .env)
  setup.sh              Bootstrap script -- installs Docker, Caddy, starts the stack
  docker-compose.yaml   Coder server + PostgreSQL container definitions
  Caddyfile             Reverse proxy template (HTTPS termination)
  agent-shell/
    template.tf         Coder workspace template (Docker container, tools, terminal apps)
  .gitignore            Ignores .env, Terraform state, SSH keys
  LICENSE               MIT license
  README.md             This file
```

## Useful Commands

```bash
# View logs
docker compose logs -f

# Restart the stack
docker compose restart

# Stop the stack
docker compose down

# Caddy logs
journalctl -u caddy -f

# Re-run setup (idempotent)
sudo bash setup.sh
```

## Troubleshooting

**Caddy shows "certificate error" or HTTPS doesn't work**
- Verify your DNS A record points to the server's public IP: `dig your-domain.com`
- Ensure ports 80 and 443 are open in your cloud provider's firewall (separate from UFW)
- Check Caddy logs: `journalctl -u caddy -f`

**Coder shows "502 Bad Gateway"**
- Coder may still be starting. Wait 30-60 seconds and refresh.
- Check Coder logs: `docker compose logs coder`

**Workspace fails to start or agent is unhealthy**
- Check the agent startup logs in the Coder dashboard
- Verify Docker socket permissions: the DOCKER_GID in `.env` must match the host's docker group
- Check: `getent group docker | cut -d: -f3` and compare with DOCKER_GID in `.env`

**"Permission denied" accessing Docker socket**
- Run `setup.sh` again -- it auto-detects and updates the Docker group GID

**Cannot connect to workspace terminal**
- The ttyd and mobile terminal scripts wait up to 5 minutes for dependencies to install
- Check script logs: `coder ssh <workspace> -- cat /tmp/coder-script-*.log`

## Backup and Restore

### Database backup
```bash
docker compose exec -T database pg_dump -U coder coder | gzip > "backup-$(date +%Y%m%d-%H%M%S).sql.gz"
```

### Restore from backup
```bash
gunzip -c backup-YYYYMMDD-HHMMSS.sql.gz | docker compose exec -T database psql -U coder coder
```

Consider automating daily backups with a cron job and keeping the last 7 days.

## License

[MIT](LICENSE)
