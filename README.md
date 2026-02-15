# Cloud Dev Environment

Two deployment options for a self-hosted development environment on any Ubuntu VPS.
Pick the one that fits your workflow.

## Options

### Option A: Standalone (SSH + tmux)

A single cloud-init config that turns any Ubuntu VPS into a ready-to-use dev box.
No Docker, no overhead. Just SSH in and start working.
Best for solo developers using terminal SSH clients.

See [`standalone/`](standalone/) for setup instructions.

### Option B: Coder (browser + multi-user)

Full [Coder](https://coder.com/) deployment with browser-based terminal, a mobile-friendly
terminal for iOS, and multi-user workspace management. More infrastructure overhead but adds
browser access and workspace templating.

See [`coder/`](coder/) for setup instructions.

## Comparison

| | Standalone | Coder |
|---|---|---|
| **Access method** | SSH | Browser, SSH, mobile |
| **Overhead** | None (bare metal) | Docker + PostgreSQL + Caddy |
| **Multi-user** | No (single user) | Yes (workspace per user) |
| **Browser access** | No | Yes (ttyd + tmux) |
| **Mobile access** | SSH app only | Yes (touch-friendly terminal with on-screen keys) |
| **Cold start time** | ~2 min (cloud-init) | ~5 min (setup.sh + first workspace) |
| **Complexity** | One YAML file | Docker Compose + Terraform template + reverse proxy |

## What's Included

Both options ship the same core developer tooling:

- **zsh** with history, completions, and emacs keybindings
- **tmux** with mouse support and sensible defaults
- **Starship** prompt (minimal, fast)
- **fzf** (fuzzy finder)
- **zoxide** (smart `cd` replacement)
- **Node.js** (LTS)
- **Claude Code CLI** (AI coding assistant)
- **Kiro CLI**

## Quick Start

### Standalone

```bash
# Paste standalone/cloud-init.yaml into your VPS provider's user-data field,
# or apply it manually:
sudo cloud-init init --file standalone/cloud-init.yaml
```

Then SSH in. Everything is ready.

### Coder

```bash
git clone https://github.com/kalleeh/coder-lightsail.git
cd coder-lightsail/coder
cp .env.example .env
nano .env              # set DOMAIN and CODER_ACCESS_URL at minimum
sudo bash setup.sh
```

Open `https://your-domain.com` in a browser. The first user to sign up becomes the admin.

## Project Structure

```
coder-lightsail/
  README.md                  This file
  LICENSE                    MIT license
  .gitignore
  standalone/                Option A: plain VPS with SSH + dev tools
    cloud-init.yaml          Cloud-init user-data config
  coder/                     Option B: full Coder deployment
    .env.example             Environment variable template (copy to .env)
    setup.sh                 Bootstrap script (Docker, Caddy, firewall)
    docker-compose.yaml      Coder server + PostgreSQL
    Caddyfile                HTTPS reverse proxy
    agent-shell/
      template.tf            Coder workspace template
      mobile-terminal.html   Touch-friendly terminal UI
      serve-mobile.js        Mobile terminal server
```

## License

[MIT](LICENSE)
