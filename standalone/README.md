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

### AWS Lightsail

1. Open the Lightsail console and click **Create instance**.
2. Select **Ubuntu 24.04 LTS**.
3. Under **Add launch script**, paste the full contents of `cloud-init.yaml`.
4. Choose your instance plan, name it, and create.
5. SSH in once the instance is running:
   ```
   ssh ubuntu@<public-ip>
   ```

### EC2 / any cloud with cloud-init

Pass `cloud-init.yaml` as **user data** when launching the instance. On EC2 this is the "User data" field in the Advanced Details section.

### Verify provisioning

Cloud-init runs on first boot and may take a few minutes. You can tail the log:

```
tail -f /var/log/cloud-init-output.log
```

Once complete, open a new shell (or run `zsh`) and everything should be ready.

## How to customize

- **Add packages**: Append to the `packages:` list.
- **Change shell config**: Edit the `.zshrc` block under `write_files:`.
- **Add environment variables**: Add `export` lines to the `.zshrc` block, or add a new file under `write_files:` (e.g. `/home/ubuntu/.env`).
- **Swap Node version**: Change the NodeSource URL in `runcmd:` (e.g. `setup_22.x` for Node 22).
- **Skip a tool**: Remove or comment out its `runcmd:` entry.
