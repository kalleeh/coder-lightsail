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
    AWS_REGION                    = "eu-north-1"                                # Change to your AWS region (e.g. us-east-1, eu-west-1)
    ANTHROPIC_MODEL               = "anthropic.claude-sonnet-4-5-20250929-v1:0" # Bedrock model ID - change to your preferred model
    CLAUDE_CODE_MAX_OUTPUT_TOKENS = "4096"
    MAX_THINKING_TOKENS           = "1024"
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
    echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sPgo8aGVhZD4KPG1ldGEgY2hhcnNldD0idXRmLTgiPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLGluaXRpYWwtc2NhbGU9MSxtYXhpbXVtLXNjYWxlPTEsdXNlci1zY2FsYWJsZT1ubyI+CjxtZXRhIG5hbWU9ImFwcGxlLW1vYmlsZS13ZWItYXBwLWNhcGFibGUiIGNvbnRlbnQ9InllcyI+CjxtZXRhIG5hbWU9ImFwcGxlLW1vYmlsZS13ZWItYXBwLXN0YXR1cy1iYXItc3R5bGUiIGNvbnRlbnQ9ImJsYWNrLXRyYW5zbHVjZW50Ij4KPHRpdGxlPlRlcm1pbmFsPC90aXRsZT4KPHN0eWxlPgoqe21hcmdpbjowO3BhZGRpbmc6MDtib3gtc2l6aW5nOmJvcmRlci1ib3h9Cmh0bWwsYm9keXtoZWlnaHQ6MTAwJTtiYWNrZ3JvdW5kOiMwMDA7b3ZlcmZsb3c6aGlkZGVufQojdGVybS1mcmFtZXt3aWR0aDoxMDAlO2hlaWdodDpjYWxjKDEwMCUgLSA0OHB4KTtib3JkZXI6bm9uZX0KI2tleWJhcnsKICBoZWlnaHQ6NDhweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyOwogIGJhY2tncm91bmQ6IzE2MjEzZTtib3JkZXItdG9wOjFweCBzb2xpZCAjMGYzNDYwOwogIG92ZXJmbG93LXg6YXV0bzstd2Via2l0LW92ZXJmbG93LXNjcm9sbGluZzp0b3VjaDsKICBwYWRkaW5nOjAgNHB4O2dhcDo0cHg7Cn0KI2tleWJhcjo6LXdlYmtpdC1zY3JvbGxiYXJ7ZGlzcGxheTpub25lfQoja2V5YmFyIGJ1dHRvbnsKICBmbGV4OjAgMCBhdXRvO2hlaWdodDozNnB4O21pbi13aWR0aDo0MHB4O3BhZGRpbmc6MCAxMHB4OwogIGJhY2tncm91bmQ6IzFhMWEyZTtjb2xvcjojZTBlMGUwOwogIGJvcmRlcjoxcHggc29saWQgIzBmMzQ2MDtib3JkZXItcmFkaXVzOjZweDsKICBmb250LXNpemU6MTNweDtmb250LWZhbWlseTotYXBwbGUtc3lzdGVtLHN5c3RlbS11aSxtb25vc3BhY2U7CiAgdG91Y2gtYWN0aW9uOm1hbmlwdWxhdGlvbjstd2Via2l0LXRhcC1oaWdobGlnaHQtY29sb3I6dHJhbnNwYXJlbnQ7CiAgdXNlci1zZWxlY3Q6bm9uZTstd2Via2l0LXVzZXItc2VsZWN0Om5vbmU7Cn0KI2tleWJhciBidXR0b246YWN0aXZle2JhY2tncm91bmQ6IzBmMzQ2MH0KI2tleWJhciBidXR0b24ubW9ke2NvbG9yOiNlOTQ1NjB9CiNrZXliYXIgYnV0dG9uLm1vZC5hY3RpdmV7YmFja2dyb3VuZDojZTk0NTYwO2NvbG9yOiNmZmY7Ym9yZGVyLWNvbG9yOiNlOTQ1NjB9CiNrZXliYXIgLnNlcHt3aWR0aDoxcHg7aGVpZ2h0OjI0cHg7YmFja2dyb3VuZDojMGYzNDYwO2ZsZXg6MCAwIDFweH0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KPGlmcmFtZSBpZD0idGVybS1mcmFtZSIgc3JjPSIvVFRZRF9QQVRILyI+PC9pZnJhbWU+CjxkaXYgaWQ9ImtleWJhciI+CiAgPGJ1dHRvbiBkYXRhLXRtdXg9IkVzY2FwZSI+RXNjPC9idXR0b24+CiAgPGJ1dHRvbiBkYXRhLXRtdXg9IlRhYiI+VGFiPC9idXR0b24+CiAgPGRpdiBjbGFzcz0ic2VwIj48L2Rpdj4KICA8YnV0dG9uIGRhdGEtdG11eD0iVXAiPiYjOTY1MDs8L2J1dHRvbj4KICA8YnV0dG9uIGRhdGEtdG11eD0iRG93biI+JiM5NjYwOzwvYnV0dG9uPgogIDxidXR0b24gZGF0YS10bXV4PSJMZWZ0Ij4mIzk2NjQ7PC9idXR0b24+CiAgPGJ1dHRvbiBkYXRhLXRtdXg9IlJpZ2h0Ij4mIzk2NTQ7PC9idXR0b24+CiAgPGRpdiBjbGFzcz0ic2VwIj48L2Rpdj4KICA8YnV0dG9uIGRhdGEta2V5PSJDb250cm9sIiBjbGFzcz0ibW9kIj5DdHJsPC9idXR0b24+CiAgPGJ1dHRvbiBkYXRhLXRtdXg9IkMtYyI+Qy1jPC9idXR0b24+CiAgPGJ1dHRvbiBkYXRhLXRtdXg9IkMtZCI+Qy1kPC9idXR0b24+CiAgPGJ1dHRvbiBkYXRhLXRtdXg9IkMtYSI+Qy1hPC9idXR0b24+CiAgPGJ1dHRvbiBkYXRhLXRtdXg9IkMtbCI+Qy1sPC9idXR0b24+CiAgPGJ1dHRvbiBkYXRhLXRtdXg9IkMteiI+Qy16PC9idXR0b24+CiAgPGRpdiBjbGFzcz0ic2VwIj48L2Rpdj4KICA8YnV0dG9uIGRhdGEtdG11eD0iRW50ZXIiPkVudGVyPC9idXR0b24+CiAgPGRpdiBjbGFzcz0ic2VwIj48L2Rpdj4KICA8YnV0dG9uIGRhdGEtbGl0PSJ8Ij58PC9idXR0b24+CiAgPGJ1dHRvbiBkYXRhLWxpdD0ifiI+fjwvYnV0dG9uPgogIDxidXR0b24gZGF0YS1saXQ9ImAiPmA8L2J1dHRvbj4KPC9kaXY+CjxzY3JpcHQ+CihmdW5jdGlvbigpewogIHZhciBmcmFtZT1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGVybS1mcmFtZScpOwogIHZhciBiYXNlPWxvY2F0aW9uLnBhdGhuYW1lLnJlcGxhY2UoL1teL10qJC8sJycpOwogIHZhciB0dHlkUGF0aD1iYXNlLnJlcGxhY2UoL2FwcHNcL21vYmlsZS10ZXJtaW5hbFwvJC8sICdhcHBzL3Rlcm1pbmFsLycpOwogIGZyYW1lLnNyYz10dHlkUGF0aDsKCiAgdmFyIGN0cmxBY3RpdmU9ZmFsc2U7CiAgdmFyIGN0cmxCdG49ZG9jdW1lbnQucXVlcnlTZWxlY3RvcignW2RhdGEta2V5PSJDb250cm9sIl0nKTsKCiAgZnVuY3Rpb24gc2VuZFRtdXgoa2V5KXsKICAgIGZldGNoKGJhc2UrJ3NlbmQnLHttZXRob2Q6J1BPU1QnLGJvZHk6a2V5fSkuY2F0Y2goZnVuY3Rpb24oKXt9KTsKICB9CiAgZnVuY3Rpb24gc2VuZExpdGVyYWwoY2gpewogICAgZmV0Y2goYmFzZSsnc2VuZGxpdCcse21ldGhvZDonUE9TVCcsYm9keTpjaH0pLmNhdGNoKGZ1bmN0aW9uKCl7fSk7CiAgfQoKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcja2V5YmFyIGJ1dHRvbicpLmZvckVhY2goZnVuY3Rpb24oYnRuKXsKICAgIGZ1bmN0aW9uIGhhbmRsZXIoZSl7CiAgICAgIGUucHJldmVudERlZmF1bHQoKTtlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICBpZihidG4uZGF0YXNldC5rZXk9PT0nQ29udHJvbCcpewogICAgICAgIGN0cmxBY3RpdmU9IWN0cmxBY3RpdmU7YnRuLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsY3RybEFjdGl2ZSk7cmV0dXJuOwogICAgICB9CiAgICAgIGlmKGJ0bi5kYXRhc2V0LnRtdXgpewogICAgICAgIHNlbmRUbXV4KGJ0bi5kYXRhc2V0LnRtdXgpOwogICAgICB9ZWxzZSBpZihidG4uZGF0YXNldC5saXQpewogICAgICAgIGlmKGN0cmxBY3RpdmUpewogICAgICAgICAgdmFyIGNvZGU9J0MtJytidG4uZGF0YXNldC5saXQudG9Mb3dlckNhc2UoKTsKICAgICAgICAgIHNlbmRUbXV4KGNvZGUpOwogICAgICAgICAgY3RybEFjdGl2ZT1mYWxzZTtjdHJsQnRuLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpOwogICAgICAgIH1lbHNlewogICAgICAgICAgc2VuZExpdGVyYWwoYnRuLmRhdGFzZXQubGl0KTsKICAgICAgICB9CiAgICAgIH0KICAgICAgaWYoY3RybEFjdGl2ZSYmYnRuLmRhdGFzZXQudG11eCYmIWJ0bi5kYXRhc2V0LnRtdXguc3RhcnRzV2l0aCgnQy0nKSl7CiAgICAgICAgLy8gVXNlciBwcmVzc2VkIEN0cmwgdGhlbiBhIG5vbi1jdHJsIGtleSwgcmVzZXQKICAgICAgICBjdHJsQWN0aXZlPWZhbHNlO2N0cmxCdG4uY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJyk7CiAgICAgIH0KICAgIH0KICAgIGJ0bi5hZGRFdmVudExpc3RlbmVyKCd0b3VjaHN0YXJ0JyxoYW5kbGVyLHtwYXNzaXZlOmZhbHNlfSk7CiAgICBidG4uYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJyxoYW5kbGVyKTsKICB9KTsKfSkoKTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgo=' | base64 -d > ~/.local/share/mobile-terminal/index.html
    echo 'Y29uc3QgaHR0cCA9IHJlcXVpcmUoJ2h0dHAnKTsKY29uc3QgZnMgPSByZXF1aXJlKCdmcycpOwpjb25zdCBwYXRoID0gcmVxdWlyZSgncGF0aCcpOwpjb25zdCB7IGV4ZWMgfSA9IHJlcXVpcmUoJ2NoaWxkX3Byb2Nlc3MnKTsKCmNvbnN0IEhUTUwgPSBmcy5yZWFkRmlsZVN5bmMocGF0aC5qb2luKF9fZGlybmFtZSwgJ2luZGV4Lmh0bWwnKSk7CgpodHRwLmNyZWF0ZVNlcnZlcigocmVxLCByZXMpID0+IHsKICAvLyB0bXV4IHNlbmQta2V5cyBmb3Igc3BlY2lhbCBrZXlzIChFc2NhcGUsIFRhYiwgVXAsIEMtYywgZXRjLikKICBpZiAocmVxLm1ldGhvZCA9PT0gJ1BPU1QnICYmIHJlcS51cmwgPT09ICcvc2VuZCcpIHsKICAgIGxldCBib2R5ID0gJyc7CiAgICByZXEub24oJ2RhdGEnLCBjID0+IGJvZHkgKz0gYyk7CiAgICByZXEub24oJ2VuZCcsICgpID0+IHsKICAgICAgY29uc3Qga2V5ID0gYm9keS50cmltKCk7CiAgICAgIC8vIFNhbml0aXplOiBvbmx5IGFsbG93IGtub3duIHRtdXgga2V5IG5hbWVzCiAgICAgIGlmICgvXihFc2NhcGV8VGFifFVwfERvd258TGVmdHxSaWdodHxFbnRlcnxCU3BhY2V8Qy1bYS16XXxNLVthLXpdKSQvLnRlc3Qoa2V5KSkgewogICAgICAgIGV4ZWMoJ3RtdXggc2VuZC1rZXlzIC10IG1haW4gJyArIGtleSwgKGVycikgPT4gewogICAgICAgICAgcmVzLndyaXRlSGVhZChlcnIgPyA1MDAgOiAyMDAsIHsnQ29udGVudC1UeXBlJzondGV4dC9wbGFpbid9KTsKICAgICAgICAgIHJlcy5lbmQoZXJyID8gJ2Vycm9yJyA6ICdvaycpOwogICAgICAgIH0pOwogICAgICB9IGVsc2UgewogICAgICAgIHJlcy53cml0ZUhlYWQoNDAwLCB7J0NvbnRlbnQtVHlwZSc6J3RleHQvcGxhaW4nfSk7CiAgICAgICAgcmVzLmVuZCgnaW52YWxpZCBrZXknKTsKICAgICAgfQogICAgfSk7CiAgICByZXR1cm47CiAgfQoKICAvLyB0bXV4IHNlbmQta2V5cyAtbCBmb3IgbGl0ZXJhbCBjaGFyYWN0ZXJzICh8LCB+LCBgKQogIGlmIChyZXEubWV0aG9kID09PSAnUE9TVCcgJiYgcmVxLnVybCA9PT0gJy9zZW5kbGl0JykgewogICAgbGV0IGJvZHkgPSAnJzsKICAgIHJlcS5vbignZGF0YScsIGMgPT4gYm9keSArPSBjKTsKICAgIHJlcS5vbignZW5kJywgKCkgPT4gewogICAgICBjb25zdCBjaCA9IGJvZHkudHJpbSgpOwogICAgICAvLyBTYW5pdGl6ZTogb25seSBhbGxvdyBzaW5nbGUgcHJpbnRhYmxlIGNoYXJhY3RlcnMKICAgICAgaWYgKGNoLmxlbmd0aCA9PT0gMSAmJiBjaC5jaGFyQ29kZUF0KDApID49IDMyICYmIGNoLmNoYXJDb2RlQXQoMCkgPD0gMTI2KSB7CiAgICAgICAgZXhlYygidG11eCBzZW5kLWtleXMgLXQgbWFpbiAtbCAnIiArIGNoLnJlcGxhY2UoLycvZywgIidcXCcnIikgKyAiJyIsIChlcnIpID0+IHsKICAgICAgICAgIHJlcy53cml0ZUhlYWQoZXJyID8gNTAwIDogMjAwLCB7J0NvbnRlbnQtVHlwZSc6J3RleHQvcGxhaW4nfSk7CiAgICAgICAgICByZXMuZW5kKGVyciA/ICdlcnJvcicgOiAnb2snKTsKICAgICAgICB9KTsKICAgICAgfSBlbHNlIHsKICAgICAgICByZXMud3JpdGVIZWFkKDQwMCwgeydDb250ZW50LVR5cGUnOid0ZXh0L3BsYWluJ30pOwogICAgICAgIHJlcy5lbmQoJ2ludmFsaWQgY2hhcicpOwogICAgICB9CiAgICB9KTsKICAgIHJldHVybjsKICB9CgogIC8vIFNlcnZlIGluZGV4Lmh0bWwgZm9yIGV2ZXJ5dGhpbmcgZWxzZQogIHJlcy53cml0ZUhlYWQoMjAwLCB7J0NvbnRlbnQtVHlwZSc6J3RleHQvaHRtbCd9KTsKICByZXMuZW5kKEhUTUwpOwp9KS5saXN0ZW4oNzY4MiwgKCkgPT4gewogIGNvbnNvbGUubG9nKCdNb2JpbGUgdGVybWluYWwgc2VydmVyIG9uIHBvcnQgNzY4MicpOwp9KTsK' | base64 -d > ~/.local/share/mobile-terminal/serve-mobile.js
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
    while ! command -v ttyd &>/dev/null; do sleep 2; done
    while ! command -v tmux &>/dev/null; do sleep 2; done
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
    while ! command -v node &>/dev/null; do sleep 2; done
    while [ ! -f ~/.local/share/mobile-terminal/serve-mobile.js ]; do sleep 2; done
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
