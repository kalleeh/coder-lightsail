FROM codercom/enterprise-base:ubuntu

# Pre-install system packages that don't persist across container recreation
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      zsh \
      tmux \
      ttyd \
      jq \
      htop \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code || true
