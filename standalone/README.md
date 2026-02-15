# Standalone Dev Box (cloud-init)

A single `cloud-init.yaml` that provisions a complete development environment on a fresh Ubuntu 24.04 VPS -- no Docker, no Coder, no Terraform. It installs the same tooling as the Coder agent-shell template directly on the host.

## What's installed

| Category | Tools |
|---|---|
| System packages | zsh, tmux, git, curl, jq, htop, build-essential |
| Runtime | Node.js LTS (NodeSource) |
| CLI tools | Starship prompt, fzf, zoxide, Claude Code, Kiro CLI |
| Shell | zsh with history, completion, emacs keybindings |
| Multiplexer | tmux (Ctrl-a prefix, mouse, 50k scrollback) |
| Security | SSH key-only auth, password login disabled |

## How to use

There are two ways to deploy: the automated deploy script (recommended) or manual cloud-init.

### Automated (deploy.sh)

The deploy script handles instance creation, WireGuard VPN setup, and teardown across multiple providers. See the **Deploy Script** section below for full details.

```
./deploy.sh create    # interactive prompts for provider, region, size
./deploy.sh destroy   # select and tear down an instance
./deploy.sh status    # list running instances
```

### Manual (paste cloud-init)

If you prefer to create the instance yourself, paste the contents of `cloud-init.yaml` as user data in your cloud provider's console.

**AWS Lightsail:**

1. Open the Lightsail console and click **Create instance**.
2. Select **Ubuntu 24.04 LTS**.
3. Under **Add launch script**, paste the full contents of `cloud-init.yaml`.
4. Choose your instance plan, name it, and create.
5. SSH in once the instance is running:
   ```
   ssh ubuntu@<public-ip>
   ```

**EC2 / any cloud with cloud-init:**

Pass `cloud-init.yaml` as **user data** when launching the instance. On EC2 this is the "User data" field in the Advanced Details section.

### Verify provisioning

Cloud-init runs on first boot and may take a few minutes. You can tail the log:

```
tail -f /var/log/cloud-init-output.log
```

Once complete, open a new shell (or run `zsh`) and everything should be ready.

## Deploy Script

`deploy.sh` is an interactive CLI that creates, destroys, and inspects dev box instances. It uses [gum](https://github.com/charmbracelet/gum) for prompts and configures a WireGuard VPN tunnel on every cloud instance so you can SSH over an encrypted private network instead of exposing port 22 to the internet.

### Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| `gum` | Interactive prompts and styled output | `brew install gum` |
| `wireguard-tools` | Generate WireGuard key pairs | `brew install wireguard-tools` |
| `qrencode` | Render the client config as a terminal QR code | `brew install qrencode` |
| Provider CLI | Talk to your cloud provider (see table below) | varies |

### Supported providers

| Provider | CLI | Install |
|---|---|---|
| Lima (local VM) | `limactl` | `brew install lima` |
| AWS Lightsail | `aws` | `brew install awscli` |
| AWS EC2 | `aws` | `brew install awscli` |
| DigitalOcean | `doctl` | `brew install doctl` |
| Hetzner | `hcloud` | `brew install hcloud` |

Lima runs a local VM and does not set up WireGuard. All cloud providers configure the WireGuard tunnel automatically.

### Commands

```
./deploy.sh create    # Pick a provider, configure instance, deploy
./deploy.sh destroy   # Pick a provider, select an instance, tear it down
./deploy.sh status    # Pick a provider, list running instances
```

If no argument is given, `create` is the default.

### WireGuard flow

When you run `create` for a cloud provider, the script:

1. Generates an ephemeral WireGuard key pair for the server and a key pair for the client.
2. Injects the server-side WireGuard config into `cloud-init.yaml` before passing it as user data.
3. Waits for the instance to come up and retrieves its public IP.
4. Prints a QR code in the terminal containing the full client tunnel config.

To connect:

1. Open the WireGuard app on your phone or laptop.
2. Scan the QR code (or paste the printed config manually).
3. Enable the tunnel.
4. SSH into the dev box over the VPN:
   ```
   ssh ubuntu@10.100.0.1    # Lightsail / EC2
   ssh root@10.100.0.1      # DigitalOcean / Hetzner
   ```

The client is assigned `10.100.0.2`; the server is `10.100.0.1`.

## Security

The deploy script configures a locked-down firewall (UFW) on every cloud instance:

- **SSH is not exposed to the public internet.** Port 22 is not open in the firewall or security group.
- **Only WireGuard (UDP 51820) is reachable from the internet.** This is the single ingress rule.
- **SSH is restricted to the WireGuard subnet.** UFW allows port 22 only from `10.100.0.0/24`, so connections must come through the tunnel.
- **Key material is ephemeral.** Private keys are generated into a temporary directory and cleaned up after the deploy completes. They are not written to disk permanently on the local machine.

For manual deploys (pasting `cloud-init.yaml` directly), the WireGuard configuration is not included and SSH is accessible on the public IP. You should restrict access with your provider's firewall or security group rules.

## How to customize

- **Add packages**: Append to the `packages:` list.
- **Change shell config**: Edit the `.zshrc` block under `write_files:`.
- **Add environment variables**: Add `export` lines to the `.zshrc` block, or add a new file under `write_files:` (e.g. `/home/ubuntu/.env`).
- **Swap Node version**: Change the NodeSource URL in `runcmd:` (e.g. `setup_22.x` for Node 22).
- **Skip a tool**: Remove or comment out its `runcmd:` entry.
