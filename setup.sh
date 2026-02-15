#!/usr/bin/env bash
# =============================================================================
# setup.sh - Bootstrap a Coder deployment on Ubuntu 24.04 LTS
# =============================================================================
#
# Usage:
#   1. Copy .env.example to .env and fill in your values:
#        cp .env.example .env
#        nano .env
#   2. Run this script as root (or with sudo):
#        sudo bash setup.sh
#
# This script is idempotent -- safe to re-run at any time.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BOLD}========== $* ==========${NC}"; }

# ---------------------------------------------------------------------------
# Resolve script directory (where docker-compose.yaml, .env, etc. live)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================= PRE-FLIGHT CHECKS ============================
header "Pre-flight checks"

# -- Must be root / sudo ----------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root. Re-run with: sudo bash $0"
    exit 1
fi
success "Running as root"

# -- Must be Ubuntu ----------------------------------------------------------
if [[ ! -f /etc/os-release ]]; then
    error "Cannot detect OS. This script requires Ubuntu 24.04 LTS."
    exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    error "This script is designed for Ubuntu, but detected: ${ID:-unknown}"
    exit 1
fi
success "Detected Ubuntu ${VERSION_ID:-unknown}"

# -- Check disk space --
AVAILABLE_MB=$(df -m / | awk 'NR==2 {print $4}')
if [[ "$AVAILABLE_MB" -lt 2048 ]]; then
    error "Less than 2GB disk space available (${AVAILABLE_MB}MB free)."
    error "Docker and Coder need at least 2GB free."
    exit 1
fi
success "Disk space available: ${AVAILABLE_MB}MB"

# -- .env must exist ---------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    error ".env file not found at ${ENV_FILE}"
    echo ""
    echo "  Before running setup.sh you must create a .env file:"
    echo ""
    echo "    cp ${SCRIPT_DIR}/.env.example ${ENV_FILE}"
    echo "    nano ${ENV_FILE}"
    echo ""
    echo "  At minimum, set DOMAIN and CODER_ACCESS_URL to your domain."
    exit 1
fi
success ".env file found"

# -- Source .env -------------------------------------------------------------
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
chmod 600 "$ENV_FILE"

# -- Validate required variables ---------------------------------------------
REQUIRED_VARS=(DOMAIN CODER_ACCESS_URL POSTGRES_USER POSTGRES_DB)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable ${var} is not set in .env"
        exit 1
    fi
done
success "All required .env variables are set (DOMAIN=${DOMAIN})"

# -- Validate domain is not a placeholder --
if [[ "$DOMAIN" == "coder.example.com" ]]; then
    error "DOMAIN is still set to the example value 'coder.example.com'"
    error "Edit .env and set your real domain before running setup."
    exit 1
fi


# ===================== GENERATE SECURE DB CREDENTIALS =======================
header "Database credentials"

if [[ -z "${POSTGRES_PASSWORD:-}" ]] || [[ "${POSTGRES_PASSWORD}" == "CHANGE_ME_USE_A_STRONG_RANDOM_PASSWORD" ]]; then
    info "Generating a secure random POSTGRES_PASSWORD ..."
    NEW_PW="$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)"

    # Write it into the .env file (replace the existing line)
    if grep -q '^POSTGRES_PASSWORD=' "$ENV_FILE"; then
        sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${NEW_PW}|" "$ENV_FILE"
    else
        echo "POSTGRES_PASSWORD=${NEW_PW}" >> "$ENV_FILE"
    fi

    # Export for the rest of this script
    export POSTGRES_PASSWORD="${NEW_PW}"
    success "POSTGRES_PASSWORD generated and written to .env"
else
    success "POSTGRES_PASSWORD is already set"
fi


# ============================ INSTALL DOCKER ================================
header "Docker"

if command -v docker &>/dev/null; then
    success "Docker is already installed ($(docker --version))"
else
    info "Installing Docker via official apt repository ..."

    # Prerequisites
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg >/dev/null

    # Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    # Docker apt source
    if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
          https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
          > /etc/apt/sources.list.d/docker.list
    fi

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null

    # Enable and start Docker
    systemctl enable --now docker

    success "Docker installed ($(docker --version))"
fi

# Ensure the docker compose plugin is available
if ! docker compose version &>/dev/null; then
    error "docker compose plugin not found. Please install docker-compose-plugin."
    exit 1
fi
success "Docker Compose plugin available ($(docker compose version --short))"

# -- Detect and persist Docker GID --
DOCKER_GID=$(getent group docker | cut -d: -f3)
if [[ -n "$DOCKER_GID" ]]; then
    if grep -q '^DOCKER_GID=' "$ENV_FILE"; then
        sed -i "s|^DOCKER_GID=.*|DOCKER_GID=${DOCKER_GID}|" "$ENV_FILE"
    else
        echo "DOCKER_GID=${DOCKER_GID}" >> "$ENV_FILE"
    fi
    export DOCKER_GID
    success "Docker group GID detected: ${DOCKER_GID}"
else
    warn "Could not detect Docker group GID. Using default 999."
    export DOCKER_GID=999
fi


# ============================ INSTALL CADDY =================================
header "Caddy"

if command -v caddy &>/dev/null; then
    success "Caddy is already installed ($(caddy version))"
else
    info "Installing Caddy via official apt repository ..."

    apt-get install -y -qq debian-common >/dev/null 2>&1 || true
    apt-get install -y -qq apt-transport-https curl >/dev/null

    # Caddy GPG key
    if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    fi

    # Caddy apt source
    if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
    fi

    apt-get update -qq
    apt-get install -y -qq caddy >/dev/null

    success "Caddy installed ($(caddy version))"
fi


# ========================= CONFIGURE CADDY ==================================
header "Configure Caddy"

CADDYFILE_SRC="${SCRIPT_DIR}/Caddyfile"
CADDYFILE_DEST="/etc/caddy/Caddyfile"

if [[ ! -f "$CADDYFILE_SRC" ]]; then
    error "Caddyfile not found at ${CADDYFILE_SRC}"
    exit 1
fi

info "Deploying Caddyfile for domain: ${DOMAIN}"
cp "$CADDYFILE_SRC" "$CADDYFILE_DEST"
success "Caddyfile deployed to ${CADDYFILE_DEST}"

# Caddy runs as a systemd service. We set DOMAIN in its environment
# override so that Caddy's {$DOMAIN} env var syntax resolves correctly.
mkdir -p /etc/systemd/system/caddy.service.d
cat > /etc/systemd/system/caddy.service.d/override.conf <<EOF
[Service]
Environment="DOMAIN=${DOMAIN}"
EOF

systemctl daemon-reload

# Validate Caddyfile syntax
if caddy validate --config "$CADDYFILE_DEST" --adapter caddyfile >/dev/null 2>&1; then
    success "Caddyfile syntax is valid"
else
    error "Caddyfile validation failed. Check ${CADDYFILE_DEST}"
    exit 1
fi

# Reload or start Caddy
if systemctl is-active --quiet caddy; then
    systemctl reload caddy
    success "Caddy reloaded"
else
    systemctl enable --now caddy
    success "Caddy started and enabled"
fi


# =========================== CONFIGURE FIREWALL =============================
header "Firewall (ufw)"

if command -v ufw &>/dev/null; then
    # Ensure SSH is allowed BEFORE enabling ufw (to avoid lockout)
    ufw allow 22/tcp   >/dev/null 2>&1
    ufw allow 80/tcp   >/dev/null 2>&1
    ufw allow 443/tcp  >/dev/null 2>&1

    # Enable ufw non-interactively (idempotent)
    ufw --force enable >/dev/null 2>&1

    success "ufw enabled -- ports 22, 80, 443 are open"
else
    warn "ufw not found. Skipping firewall configuration."
    warn "Make sure ports 22, 80, and 443 are open in your cloud provider's firewall."
fi


# ========================= START THE STACK ==================================
header "Start Coder stack"

info "Running docker compose up -d ..."
cd "$SCRIPT_DIR"
docker compose up -d

success "Docker Compose stack started"


# ====================== WAIT FOR CODER TO BE HEALTHY =======================
header "Waiting for Coder to become healthy"

CODER_URL="http://localhost:7080"
HEALTH_ENDPOINT="${CODER_URL}/api/v2/buildinfo"
MAX_WAIT=120  # seconds
INTERVAL=3
ELAPSED=0

info "Polling ${HEALTH_ENDPOINT} (timeout: ${MAX_WAIT}s) ..."

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${HEALTH_ENDPOINT}" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        success "Coder is healthy (HTTP ${HTTP_CODE})"
        break
    fi
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
    echo -ne "  Waiting... ${ELAPSED}s / ${MAX_WAIT}s (last HTTP status: ${HTTP_CODE})\r"
done

echo "" # clear the \r line

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    warn "Coder did not respond within ${MAX_WAIT}s."
    warn "Check logs with: docker compose -f ${SCRIPT_DIR}/docker-compose.yaml logs coder"
    warn "Continuing anyway -- it may still be starting up."
fi


# ========================= PRINT NEXT STEPS =================================
header "Setup complete"

echo ""
echo -e "${GREEN}Coder is up and running!${NC}"
echo ""
echo -e "${BOLD}Access URL:${NC}  https://${DOMAIN}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo "  1. Open https://${DOMAIN} in your browser."
echo "     Create your first admin account on the initial setup page."
echo ""
echo "  2. Push a workspace template. From this directory:"
echo ""
echo "     # Install the Coder CLI (if not already on your local machine):"
echo "     curl -fsSL https://${DOMAIN}/install.sh | sh"
echo ""
echo "     # Login to your Coder instance:"
echo "     coder login https://${DOMAIN}"
echo ""
echo "     # Push the agent-shell template:"
echo "     coder templates push agent-shell --directory ${SCRIPT_DIR}/agent-shell"
echo ""
echo "  3. Create a workspace from the template in the Coder dashboard."
echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo ""
echo "  View logs:       docker compose -f ${SCRIPT_DIR}/docker-compose.yaml logs -f"
echo "  Restart stack:   docker compose -f ${SCRIPT_DIR}/docker-compose.yaml restart"
echo "  Stop stack:      docker compose -f ${SCRIPT_DIR}/docker-compose.yaml down"
echo "  Caddy logs:      journalctl -u caddy -f"
echo "  Re-run setup:    sudo bash ${SCRIPT_DIR}/setup.sh"
echo ""
