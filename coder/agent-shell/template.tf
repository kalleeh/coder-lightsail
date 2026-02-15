terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

provider "docker" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# =============================================================================
# Configuration
# Customize the values below for your deployment:
#   - AWS region and Bedrock model in the coder_agent env block
#   - Container image in docker_container.workspace
# =============================================================================

# Secure secret for Bedrock API key
data "coder_parameter" "bedrock_api_key" {
  name         = "bedrock_api_key"
  display_name = "Bedrock API Key"
  description  = "Your AWS Bedrock API key for Claude Code"
  type         = "string"
  mutable      = true
  default      = ""
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  env = {
    AWS_BEARER_TOKEN_BEDROCK      = data.coder_parameter.bedrock_api_key.value
    CLAUDE_CODE_USE_BEDROCK       = "1"
    AWS_REGION                    = "us-east-1"                                 # Change to your AWS region
    ANTHROPIC_MODEL               = "anthropic.claude-sonnet-4-5-20250929-v1:0" # Bedrock model ID - change to your preferred model
    CLAUDE_CODE_MAX_OUTPUT_TOKENS = "16384"
    MAX_THINKING_TOKENS           = "8192"
  }

  startup_script = <<-EOT
    #!/bin/bash

    export DEBIAN_FRONTEND=noninteractive

    # --- System packages (don't persist across container recreation) ---
    (sudo apt-get update && sudo apt-get install -y zsh tmux ttyd) </dev/null >/dev/null 2>&1

    # Install Node.js (required for MCP servers)
    if ! command -v node &> /dev/null; then
      (curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs) </dev/null >/dev/null 2>&1
    fi

    # --- User-space tools (persist in home volume) ---
    mkdir -p ~/.local/bin
    export PATH="$HOME/.local/bin:$HOME/.fzf/bin:$PATH"

    # Starship prompt
    if [ ! -f ~/.local/bin/starship ]; then
      (curl -fsSL https://starship.rs/install.sh | sh -s -- --bin-dir ~/.local/bin --yes) </dev/null >/dev/null 2>&1
    fi

    # fzf (fuzzy finder)
    if [ ! -d ~/.fzf ]; then
      git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf >/dev/null 2>&1
      ~/.fzf/install --bin --no-bash --no-fish --no-zsh >/dev/null 2>&1
    fi

    # zoxide (smart cd)
    if [ ! -f ~/.local/bin/zoxide ]; then
      (curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh) </dev/null >/dev/null 2>&1
    fi

    # Claude Code
    if ! command -v claude &> /dev/null; then
      (sudo npm install -g @anthropic-ai/claude-code || true) </dev/null >/dev/null 2>&1
    fi

    # Kiro CLI
    if [ ! -f ~/.local/bin/kiro-cli ]; then
      (curl -fsSL https://cli.kiro.dev/install | bash || true) </dev/null >/dev/null 2>&1
    fi

    # Configure Kiro CLI with Context7 MCP server
    mkdir -p ~/.config/kiro
    if [ ! -f ~/.config/kiro/config.json ] || grep -q '"Context7"' ~/.config/kiro/config.json 2>/dev/null; then
      cat > ~/.config/kiro/config.json << 'KIROCONF'
{
  "mcpServers": {
    "Context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"],
      "env": {},
      "disabled": false,
      "autoApprove": []
    }
  }
}
KIROCONF
    fi

    # --- Set zsh as default shell ---
    sudo chsh -s $(which zsh) coder 2>/dev/null || true

    # --- Shell configuration ---
    # Only write configs if they don't exist or are still coder-managed
    if [ ! -f ~/.zshrc ] || grep -q "# coder-managed-shell" ~/.zshrc 2>/dev/null; then
      cat > ~/.zshrc << 'ZSHRC'
# coder-managed-shell
# Remove or edit this comment to prevent Coder from overwriting your config.

export PATH="$HOME/.local/bin:$HOME/.fzf/bin:$PATH"

# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt share_history
setopt hist_ignore_dups
setopt hist_ignore_space

# Key bindings (emacs mode)
bindkey -e
bindkey '^[[A' history-search-backward
bindkey '^[[B' history-search-forward

# Completion
autoload -Uz compinit && compinit -C

# Starship prompt
eval "$(starship init zsh)"

# fzf keybindings and completion
[ -f ~/.fzf/bin/fzf ] && eval "$(fzf --zsh 2>/dev/null)" || true

# zoxide (use 'z' instead of 'cd')
eval "$(zoxide init zsh)"

# Aliases
alias ll="ls -la --color=auto"
alias gs="git status"
alias gd="git diff"
alias gl="git log --oneline -20"

# Default working directory
[[ "$PWD" == "$HOME" ]] && cd ~/projects
ZSHRC
    fi

    # Starship config (minimal, fast)
    mkdir -p ~/.config
    if [ ! -f ~/.config/starship.toml ] || grep -q "# coder-managed" ~/.config/starship.toml 2>/dev/null; then
      cat > ~/.config/starship.toml << 'STARSHIP'
# coder-managed
format = "$directory$git_branch$git_status$character"

[directory]
truncation_length = 3
truncation_symbol = "…/"

[git_branch]
format = "[$branch]($style) "
style = "bold purple"

[git_status]
format = '([$all_status$ahead_behind]($style) )'
style = "bold red"

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
STARSHIP
    fi

    # tmux config
    if [ ! -f ~/.tmux.conf ] || grep -q "# coder-managed" ~/.tmux.conf 2>/dev/null; then
      cat > ~/.tmux.conf << 'TMUX'
# coder-managed
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"
set -g default-shell /usr/bin/zsh

# Mouse support (scroll, click panes, resize)
set -g mouse on

# Start windows/panes at 1 instead of 0
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# Prefix: Ctrl-a
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# Split panes with | and -
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# New window keeps current path
bind c new-window -c "#{pane_current_path}"

# Status bar
set -g status-style "bg=default,fg=white"
set -g status-left "#[bold]#S "
set -g status-right ""
set -g status-left-length 20

# Scrollback
set -g history-limit 50000
TMUX
    fi

    # Create projects directory
    mkdir -p ~/projects

    # Configure git
    git config --global user.name "${data.coder_workspace_owner.me.name}"
    git config --global user.email "${data.coder_workspace_owner.me.email}"

    # Mobile terminal wrapper (iframe + key bar + tmux send-keys API on port 7682)
    mkdir -p ~/.local/share/mobile-terminal
    echo '${base64encode(file("${path.module}/mobile-terminal.html"))}' | base64 -d > ~/.local/share/mobile-terminal/index.html
    echo '${base64encode(file("${path.module}/serve-mobile.js"))}' | base64 -d > ~/.local/share/mobile-terminal/serve-mobile.js
  EOT
}

# Run ttyd as a separate long-running process (avoids pipe warning in startup script)
resource "coder_script" "ttyd" {
  agent_id     = coder_agent.main.id
  display_name = "ttyd"
  icon         = "/icon/terminal.svg"
  run_on_start = true
  script       = <<-EOT
    # Wait for ttyd to be installed by startup script
    WAITED=0
    while ! command -v ttyd &>/dev/null; do
      sleep 2; WAITED=$((WAITED+2))
      [ $WAITED -ge 300 ] && echo "ERROR: ttyd not found after 300s" && exit 1
    done
    while ! command -v tmux &>/dev/null; do
      sleep 2; WAITED=$((WAITED+2))
      [ $WAITED -ge 300 ] && echo "ERROR: tmux not found after 300s" && exit 1
    done
    exec ttyd --writable -p 7681 tmux new -A -s main
  EOT
}

# Run mobile terminal server as a separate long-running process
resource "coder_script" "mobile_terminal" {
  agent_id     = coder_agent.main.id
  display_name = "Mobile Terminal Server"
  icon         = "/icon/terminal.svg"
  run_on_start = true
  script       = <<-EOT
    # Wait for node and the HTML/JS files to be ready
    WAITED=0
    while ! command -v node &>/dev/null; do
      sleep 2; WAITED=$((WAITED+2))
      [ $WAITED -ge 300 ] && echo "ERROR: node not found after 300s" && exit 1
    done
    while [ ! -f ~/.local/share/mobile-terminal/serve-mobile.js ]; do
      sleep 2; WAITED=$((WAITED+2))
      [ $WAITED -ge 300 ] && echo "ERROR: mobile terminal files not found after 300s" && exit 1
    done
    cd ~/.local/share/mobile-terminal && exec node serve-mobile.js
  EOT
}

# Browser terminal (ttyd + tmux)
resource "coder_app" "terminal" {
  agent_id     = coder_agent.main.id
  slug         = "terminal"
  display_name = "Terminal"
  url          = "http://localhost:7681"
  icon         = "/icon/terminal.svg"
  subdomain    = false
}

# Mobile terminal (ttyd iframe + key bar for iOS)
resource "coder_app" "mobile_terminal" {
  agent_id     = coder_agent.main.id
  slug         = "mobile-terminal"
  display_name = "Mobile Terminal"
  url          = "http://localhost:7682"
  icon         = "/icon/terminal.svg"
  subdomain    = false
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = "codercom/enterprise-base:ubuntu"
  name  = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"

  command = ["sh", "-c", coder_agent.main.init_script]

  env = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
  }
}
