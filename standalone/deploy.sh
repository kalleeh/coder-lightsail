#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT="${SCRIPT_DIR}/cloud-init.yaml"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() { gum style --foreground 1 --bold "ERROR: $*"; exit 1; }

require_gum() {
  command -v gum &>/dev/null && return
  echo "gum is required but not installed."
  echo "  brew install gum          # macOS"
  echo "  sudo apt install gum      # Debian/Ubuntu"
  echo "  go install github.com/charmbracelet/gum@latest"
  echo "See https://github.com/charmbracelet/gum"
  exit 1
}

require_cli() {
  local cmd=$1 name=$2
  command -v "$cmd" &>/dev/null && return
  gum style --foreground 1 --bold "$name CLI ('$cmd') is not installed."
  case "$cmd" in
    limactl)   gum style "  brew install lima" ;;
    aws)       gum style "  brew install awscli   # or pip install awscli" ;;
    doctl)     gum style "  brew install doctl" ;;
    hcloud)    gum style "  brew install hcloud" ;;
    wg)        gum style "  brew install wireguard-tools" ;;
    qrencode)  gum style "  brew install qrencode" ;;
  esac
  exit 1
}

styled_box() { gum style --border double --padding "1 2" --border-foreground 6 "$@"; }

# ── WireGuard VPN + SSH key + AI credentials helpers ─────────────────────────

WG_TMPDIR=""
WG_PEER_COUNT=1
SSH_PUBKEY=""
SSH_PRIVKEY_FILE=""
BEDROCK_API_KEY=""
BEDROCK_REGION=""

# Arrays for multi-peer support
declare -a WG_PHONE_PRIVKEYS=()
declare -a WG_PHONE_PUBKEYS=()

setup_wireguard() {
  local peer_count
  peer_count=$(gum choose --header "How many devices to configure?" "1" "2" "3")
  WG_PEER_COUNT="$peer_count"

  WG_TMPDIR=$(mktemp -d)

  # SSH key: reuse existing or generate new
  local existing_keys
  existing_keys=$(find "$SCRIPT_DIR" -maxdepth 1 -name "dev-box-*" ! -name "*.pub" -type f 2>/dev/null || true)

  local key_choice="Generate new key"
  if [[ -n "$existing_keys" ]]; then
    key_choice=$({ echo "$existing_keys"; echo "Generate new key"; echo "Enter custom path"; } | gum choose --header "SSH key")
  else
    key_choice=$(printf "Generate new key\nEnter custom path\n" | gum choose --header "SSH key")
  fi

  if [[ "$key_choice" == "Generate new key" ]]; then
    ssh-keygen -t ed25519 -f "$WG_TMPDIR/ssh_key" -N "" -C "deploy-$(date +%Y%m%d)" -q
    SSH_PUBKEY=$(cat "$WG_TMPDIR/ssh_key.pub")
    local key_name="dev-box-$(date +%Y%m%d-%H%M%S)"
    SSH_PRIVKEY_FILE="${SCRIPT_DIR}/${key_name}"
    cp "$WG_TMPDIR/ssh_key" "$SSH_PRIVKEY_FILE"
    chmod 600 "$SSH_PRIVKEY_FILE"
  elif [[ "$key_choice" == "Enter custom path" ]]; then
    SSH_PRIVKEY_FILE=$(gum input --header "Path to SSH private key")
    [[ ! -f "$SSH_PRIVKEY_FILE" ]] && die "Key not found: $SSH_PRIVKEY_FILE"
    SSH_PUBKEY=$(ssh-keygen -y -f "$SSH_PRIVKEY_FILE")
  else
    SSH_PRIVKEY_FILE="$key_choice"
    SSH_PUBKEY=$(ssh-keygen -y -f "$SSH_PRIVKEY_FILE")
  fi

  # Prompt for Bedrock credentials (optional)
  if gum confirm "Configure AWS Bedrock for Claude Code / Kiro CLI?"; then
    BEDROCK_REGION=$(gum input --header "AWS Bedrock region" --value "eu-north-1")
    BEDROCK_API_KEY=$(gum input --header "Bedrock API key (or leave empty for IAM role)" --password)
  fi

  # Generate WireGuard server key pair
  wg genkey | tee "$WG_TMPDIR/server.key" | wg pubkey > "$WG_TMPDIR/server.pub"

  WG_SERVER_PRIVKEY=$(cat "$WG_TMPDIR/server.key")
  WG_SERVER_PUBKEY=$(cat "$WG_TMPDIR/server.pub")

  # Generate WireGuard key pairs for each device/peer
  WG_PHONE_PRIVKEYS=()
  WG_PHONE_PUBKEYS=()
  for i in $(seq 1 "$peer_count"); do
    wg genkey | tee "$WG_TMPDIR/phone${i}.key" | wg pubkey > "$WG_TMPDIR/phone${i}.pub"
    WG_PHONE_PRIVKEYS+=("$(cat "$WG_TMPDIR/phone${i}.key")")
    WG_PHONE_PUBKEYS+=("$(cat "$WG_TMPDIR/phone${i}.pub")")
  done
}

build_cloud_init() {
  local user="${1:-ubuntu}"
  local provider="${2:-}"
  local tmp_ci="$WG_TMPDIR/cloud-init-wg.yaml"
  cp "$CLOUD_INIT" "$tmp_ci"

  # Inject generated SSH public key into cloud-init as a top-level directive.
  # Must be inserted near the top (after #cloud-config), not appended at the end,
  # because appending would place it inside or after the runcmd block.
  local tmp_key="$WG_TMPDIR/cloud-init-key.yaml"
  {
    head -1 "$tmp_ci"  # #cloud-config line
    echo ""
    echo "ssh_authorized_keys:"
    echo "  - ${SSH_PUBKEY}"
    echo ""
    tail -n +2 "$tmp_ci"  # rest of the file
  } > "$tmp_key"
  mv "$tmp_key" "$tmp_ci"

  # Fix user paths per provider (#1)
  # DigitalOcean and Hetzner use root as default user
  if [[ "$user" == "root" ]]; then
    sed "s|/home/ubuntu|/root|g; s|ubuntu:ubuntu|root:root|g; s|chsh -s /usr/bin/zsh ubuntu|chsh -s /usr/bin/zsh root|g; s|chown -R ubuntu:ubuntu|chown -R root:root|g" "$tmp_ci" > "${tmp_ci}.tmp"
    mv "${tmp_ci}.tmp" "$tmp_ci"
  fi

  # Build WireGuard peer blocks for all devices
  local peers_block=""
  for i in $(seq 1 "$WG_PEER_COUNT"); do
    local idx=$((i - 1))
    local peer_ip="10.100.0.$((i + 1))"
    peers_block+="
      [Peer]  # Device ${i}
      PublicKey = ${WG_PHONE_PUBKEYS[$idx]}
      AllowedIPs = ${peer_ip}/32
"
  done

  # Append WireGuard server config to write_files section.
  # We insert it just before the "runcmd:" line so it lands inside write_files.
  local wg_write_files
  wg_write_files=$(cat <<WGEOF

  # -- WireGuard server config --
  - path: /etc/wireguard/wg0.conf
    owner: root:root
    permissions: "0600"
    content: |
      [Interface]
      PrivateKey = ${WG_SERVER_PRIVKEY}
      Address = 10.100.0.1/24
      ListenPort = 51820
${peers_block}
WGEOF
  )

  # Insert WireGuard write_files entry before the runcmd section.
  # Uses a temp file approach instead of awk -v (BSD awk on macOS
  # cannot handle multi-line strings in -v assignments).
  local wg_block_file="$WG_TMPDIR/wg-block.yaml"
  echo "$wg_write_files" > "$wg_block_file"
  local tmp_insert="$WG_TMPDIR/cloud-init-insert.yaml"
  local runcmd_line
  runcmd_line=$(grep -n '^runcmd:' "$tmp_ci" | head -1 | cut -d: -f1)
  if [[ -n "$runcmd_line" ]]; then
    head -n "$((runcmd_line - 1))" "$tmp_ci" > "$tmp_insert"
    cat "$wg_block_file" >> "$tmp_insert"
    echo "" >> "$tmp_insert"

    # Add AI credentials file if configured
    if [[ -n "$BEDROCK_REGION" ]]; then
      local ai_home="/home/ubuntu"
      [[ "$user" == "root" ]] && ai_home="/root"
      local ai_content="export CLAUDE_CODE_USE_BEDROCK=1\nexport AWS_REGION=${BEDROCK_REGION}"
      [[ -n "$BEDROCK_API_KEY" ]] && ai_content="${ai_content}\nexport AWS_BEARER_TOKEN_BEDROCK=${BEDROCK_API_KEY}"
      {
        echo "  # -- AI credentials (Claude Code / Kiro CLI) --"
        echo "  - path: ${ai_home}/.ai-credentials"
        echo "    owner: ${user}:${user}"
        echo '    permissions: "0600"'
        echo "    content: |"
        echo "      export CLAUDE_CODE_USE_BEDROCK=1"
        echo "      export AWS_REGION=${BEDROCK_REGION}"
        echo "      export ANTHROPIC_MODEL='eu.anthropic.claude-opus-4-6-v1:0'"
        if [[ -n "$BEDROCK_API_KEY" ]]; then
          echo "      export AWS_BEARER_TOKEN_BEDROCK=${BEDROCK_API_KEY}"
        fi
        echo ""
      } >> "$tmp_insert"
    fi
    tail -n +"$runcmd_line" "$tmp_ci" >> "$tmp_insert"
    mv "$tmp_insert" "$tmp_ci"
  fi

  # Append WireGuard runcmd entries and firewall rules at the end.
  # Providers with their own firewall (Lightsail, EC2) allow SSH from
  # anywhere in ufw since the provider firewall is the outer security layer.
  # Providers without a firewall (DO, Hetzner) restrict SSH to WireGuard only.
  if [[ "$provider" == "lightsail" || "$provider" == "ec2" ]]; then
    cat >> "$tmp_ci" <<'RUNCMD'

  # -- WireGuard VPN --
  - apt-get install -y wireguard
  - systemctl enable --now wg-quick@wg0
  - ufw default deny incoming
  - ufw allow 51820/udp
  - ufw allow 22/tcp
  - ufw --force enable
RUNCMD
  else
    cat >> "$tmp_ci" <<'RUNCMD'

  # -- WireGuard VPN --
  - apt-get install -y wireguard
  - systemctl enable --now wg-quick@wg0
  - ufw default deny incoming
  - ufw allow 51820/udp
  - ufw allow from 10.100.0.0/24 to any port 22
  - ufw --force enable
RUNCMD
  fi

  # Cloud-init completion marker (#8)
  echo "  - touch /var/lib/cloud/.cloud-init-complete" >> "$tmp_ci"

  # Lightsail doesn't support #cloud-config YAML natively.
  # Its --user-data only accepts shell scripts. We wrap the complete
  # cloud-init YAML (already built above with all injections) in a
  # thin bash script that writes it to disk and runs cloud-init's
  # own modules to process it. No custom parser needed.
  if [[ "$provider" == "lightsail" ]]; then
    local tmp_wrapper="$WG_TMPDIR/cloud-init-wrapper.sh"
    {
      echo "#!/bin/bash"
      echo "set -x"
      echo ""
      echo "# Write the complete cloud-init config"
      echo "cat > /etc/cloud/cloud.cfg.d/99-devbox.cfg << 'ENDOFCLOUDINIT'"
      # Paste the fully-built cloud-init YAML (minus the #cloud-config header)
      tail -n +2 "$tmp_ci"
      echo "ENDOFCLOUDINIT"
      echo ""
      echo "# Process using cloud-init's own modules"
      echo "# --frequency always forces execution even if modules already ran"
      echo "cloud-init single --name write_files --frequency always"
      echo "cloud-init single --name package_update_upgrade_install --frequency always"
      echo "cloud-init single --name runcmd --frequency always"
      echo ""
      echo "# Scrub secrets from user-data cache"
      echo "rm -f /var/lib/cloud/instance/scripts/part-001"
      echo "rm -f /var/lib/cloud/instance/user-data.txt"
      echo "rm -f /var/lib/cloud/instances/*/user-data.txt 2>/dev/null"
      echo "iptables -A OUTPUT -d 169.254.169.254 -p tcp --dport 80 -m string --string \"user-data\" --algo bm -j DROP 2>/dev/null || true"
    } > "$tmp_wrapper"
    echo "$tmp_wrapper"
    return
  fi

  echo "$tmp_ci"
}

show_qr() {
  local server_ip="$1" ssh_user="$2"

  gum style --bold --foreground 2 "WireGuard VPN configured!"
  echo ""

  # Show QR code for each device
  for i in $(seq 1 "$WG_PEER_COUNT"); do
    local idx=$((i - 1))
    local peer_ip="10.100.0.$((i + 1))"

    local phone_conf
    phone_conf=$(cat <<PHONEEOF
[Interface]
PrivateKey = ${WG_PHONE_PRIVKEYS[$idx]}
Address = ${peer_ip}/24
DNS = 1.1.1.1

[Peer]
PublicKey = ${WG_SERVER_PUBKEY}
Endpoint = ${server_ip}:51820
AllowedIPs = 10.100.0.1/32
PersistentKeepalive = 25
PHONEEOF
    )

    if [[ "$WG_PEER_COUNT" -gt 1 ]]; then
      gum style --bold --foreground 6 "── Device ${i} of ${WG_PEER_COUNT} ──"
    fi

    gum style --bold "1. Scan this QR code with the WireGuard app"
    gum style --bold "2. Enable the tunnel"
    gum style --bold "3. Connect:  ssh ${ssh_user}@10.100.0.1"
    echo ""

    echo "$phone_conf" | qrencode -t ansiutf8
    echo ""

    gum style --foreground 3 "Device ${i} config (in case QR doesn't scan):"
    echo "$phone_conf"
    echo ""

    # Save config locally so QR can be regenerated later
    local conf_file="${SCRIPT_DIR}/wireguard-device${i}.conf"
    echo "$phone_conf" > "$conf_file"
    chmod 600 "$conf_file"
  done

  gum style --foreground 6 "WireGuard configs saved to ${SCRIPT_DIR}/wireguard-device*.conf"
  gum style --foreground 6 "Regenerate QR anytime: qrencode -t ansiutf8 < wireguard-device1.conf"
  echo ""

  styled_box \
    "SSH over WireGuard:" \
    "  ssh -i ${SSH_PRIVKEY_FILE} ${ssh_user}@10.100.0.1" \
    "" \
    "SSH private key saved to:" \
    "  ${SSH_PRIVKEY_FILE}" \
    "" \
    "To use from iOS (Termius):" \
    "  AirDrop ${SSH_PRIVKEY_FILE} to your phone"

  # Cloud-init progress note (#8)
  echo ""
  gum style --foreground 3 "Cloud-init is still configuring the server. Wait 2-3 minutes after"
  gum style --foreground 3 "connecting before all tools are available."
  gum style --foreground 3 "Check progress with: tail -f /var/log/cloud-init-output.log"
}

cleanup_wireguard() {
  [[ -n "$WG_TMPDIR" && -d "$WG_TMPDIR" ]] && rm -rf "$WG_TMPDIR"
}

# ── Provider: Lima (local) ───────────────────────────────────────────────────

lima_create() {
  local cpus memory name
  cpus=$(gum choose --header "CPUs" 1 2 4)
  memory=$(gum choose --header "Memory" "2GiB" "4GiB" "8GiB")
  name=$(gum input --header "Instance name" --value "dev-box")

  gum style --bold "Summary"
  styled_box "Provider: Lima (local)" "CPUs:     $cpus" "Memory:   $memory" "Name:     $name"
  gum confirm "Create this VM?" || exit 0

  local tmpfile
  tmpfile=$(mktemp /tmp/lima-XXXXXX.yaml)
  trap 'rm -f "$tmpfile"' EXIT

  # Build Lima YAML with embedded cloud-init runcmd as provision script
  cat > "$tmpfile" <<YAML
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"
cpus: ${cpus}
memory: "${memory}"
vmType: "vz"
mountType: "virtiofs"
YAML

  # Append cloud-init provision block -- embed the full cloud-init YAML
  {
    echo "provision:"
    echo "  - mode: cloud-init"
    echo "    script: |"
    sed 's/^/      /' "$CLOUD_INIT"
  } >> "$tmpfile"

  gum spin --title "Creating Lima VM '$name'..." -- limactl create --name "$name" "$tmpfile" --tty=false
  gum spin --title "Starting Lima VM '$name'..." -- limactl start "$name"

  styled_box "Lima VM '$name' is running!" "" "Connect with:" "  limactl shell $name"
}

lima_destroy() {
  local instances
  instances=$(limactl list --format '{{.Name}}' 2>/dev/null | grep -v '^$' || true)
  [[ -z "$instances" ]] && die "No Lima instances found."

  local target
  target=$(echo "$instances" | gum choose --header "Select instance to destroy")
  gum confirm "Destroy Lima VM '$target'? This is irreversible." || exit 0
  gum spin --title "Destroying '$target'..." -- limactl delete --force "$target"
  gum style --foreground 2 --bold "Destroyed '$target'."
  gum style --foreground 3 "Remember to remove the WireGuard tunnel from your phone/device."
}

lima_status() {
  limactl list
}

# ── Provider: AWS Lightsail ──────────────────────────────────────────────────

lightsail_create() {
  local region bundle key_name name ssh_user="ubuntu"
  region=$(gum choose --header "Region" us-east-1 eu-west-1 eu-north-1 ap-southeast-1)
  bundle=$(gum choose --header "Bundle" small_3_0 medium_3_0 large_3_0)

  # SSH key selection from provider API (optional -- we generate our own via cloud-init)
  local available_keys key_name=""
  available_keys=$(aws lightsail get-key-pairs --region "$region" --query 'keyPairs[].name' --output text | tr '\t' '\n' || true)
  if [[ -n "$available_keys" ]]; then
    key_name=$(echo "$available_keys" "$(gum style --faint '(skip - use generated key only)')" | gum choose --header "SSH key (optional)")
    [[ "$key_name" == *"skip"* ]] && key_name=""
  fi

  name=$(gum input --header "Instance name" --value "dev-box")

  local key_display="${key_name:-generated (via cloud-init)}"
  gum style --bold "Summary"
  styled_box "Provider: AWS Lightsail" "Region:   $region" "Bundle:   $bundle" "SSH key:  $key_display" "Name:     $name"
  gum confirm "Create this instance?" || exit 0

  # Set up WireGuard keys and build modified cloud-init
  setup_wireguard
  trap 'cleanup_wireguard' EXIT
  local wg_cloud_init
  wg_cloud_init=$(build_cloud_init "$ssh_user" "lightsail")

  local key_flag=()
  [[ -n "$key_name" ]] && key_flag=(--key-pair-name "$key_name")

  gum spin --title "Creating Lightsail instance '$name'..." -- \
    aws lightsail create-instances \
      --instance-names "$name" \
      --availability-zone "${region}a" \
      --blueprint-id ubuntu_24_04 \
      --bundle-id "$bundle" \
      "${key_flag[@]}" \
      --user-data "$(cat "$wg_cloud_init")" \
      --region "$region"

  gum spin --title "Waiting for instance to be running..." -- \
    aws lightsail wait instance-running --instance-name "$name" --region "$region" 2>/dev/null || sleep 15

  # Update Lightsail firewall: replace default rules (SSH 22) with WireGuard only
  gum spin --title "Configuring firewall (WireGuard only)..." -- \
    aws lightsail put-instance-public-ports \
      --instance-name "$name" \
      --port-infos "fromPort=51820,toPort=51820,protocol=udp" \
      --region "$region"

  # Allocate and attach a static IP (#5)
  local static_ip_name="${name}-ip"
  gum spin --title "Allocating static IP..." -- \
    aws lightsail allocate-static-ip --static-ip-name "$static_ip_name" --region "$region"
  gum spin --title "Attaching static IP..." -- \
    aws lightsail attach-static-ip --static-ip-name "$static_ip_name" --instance-name "$name" --region "$region"

  local ip
  ip=$(aws lightsail get-static-ip --static-ip-name "$static_ip_name" --region "$region" \
       --query 'staticIp.ipAddress' --output text)

  show_qr "$ip" "$ssh_user"
}

lightsail_destroy() {
  local region instances target
  region=$(gum choose --header "Region" us-east-1 eu-west-1 eu-north-1 ap-southeast-1)
  instances=$(aws lightsail get-instances --region "$region" \
    --query 'instances[].name' --output text | tr '\t' '\n' || true)
  [[ -z "$instances" ]] && die "No Lightsail instances in $region."

  target=$(echo "$instances" | gum choose --header "Select instance to destroy")
  gum confirm "Destroy Lightsail instance '$target'? This is irreversible." || exit 0
  gum spin --title "Destroying '$target'..." -- \
    aws lightsail delete-instance --instance-name "$target" --region "$region"

  # Release the static IP (#5)
  aws lightsail release-static-ip --static-ip-name "${target}-ip" --region "$region" 2>/dev/null || true

  gum style --foreground 2 --bold "Destroyed '$target'."
  gum style --foreground 3 "Remember to remove the WireGuard tunnel from your phone/device."
}

lightsail_status() {
  aws lightsail get-instances --query \
    'instances[].{Name:name,State:state.name,IP:publicIpAddress,Blueprint:blueprintId}' \
    --output table
}

# ── Provider: AWS EC2 ────────────────────────────────────────────────────────

ec2_create() {
  local region itype key_name name ssh_user="ubuntu"
  region=$(gum choose --header "Region" us-east-1 us-west-2 eu-west-1 eu-north-1 ap-southeast-1)
  itype=$(gum choose --header "Instance type" t3.small t3.medium t3.large)

  # SSH key selection from provider API (optional -- we generate our own via cloud-init)
  local available_keys key_name=""
  available_keys=$(aws ec2 describe-key-pairs --region "$region" --query 'KeyPairs[].KeyName' --output text | tr '\t' '\n' || true)
  if [[ -n "$available_keys" ]]; then
    key_name=$(echo "$available_keys" "$(gum style --faint '(skip - use generated key only)')" | gum choose --header "SSH key (optional)")
    [[ "$key_name" == *"skip"* ]] && key_name=""
  fi

  name=$(gum input --header "Instance name" --value "dev-box")

  local key_display="${key_name:-generated (via cloud-init)}"
  gum style --bold "Summary"
  styled_box "Provider: AWS EC2" "Region:   $region" "Type:     $itype" "Key pair: $key_display" "Name:     $name"
  gum confirm "Create this instance?" || exit 0

  # Set up WireGuard keys and build modified cloud-init
  setup_wireguard
  trap 'cleanup_wireguard' EXIT
  local wg_cloud_init
  wg_cloud_init=$(build_cloud_init "$ssh_user" "ec2")

  # Look up latest Ubuntu 24.04 AMI
  local ami
  ami=$(gum spin --title "Looking up Ubuntu 24.04 AMI..." --show-output -- \
    aws ec2 describe-images --region "$region" \
      --owners 099720109477 \
      --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
                "Name=state,Values=available" \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  [[ -z "$ami" || "$ami" == "None" ]] && die "Could not find Ubuntu 24.04 AMI in $region."

  # Create security group (WireGuard UDP only - no SSH from public internet)
  local sg_name="coder-deploy-${name}" sg_id vpc_id
  vpc_id=$(aws ec2 describe-vpcs --region "$region" \
    --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' --output text)

  sg_id=$(aws ec2 describe-security-groups --region "$region" \
    --filters "Name=group-name,Values=$sg_name" "Name=vpc-id,Values=$vpc_id" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

  if [[ "$sg_id" == "None" || -z "$sg_id" ]]; then
    sg_id=$(gum spin --title "Creating security group..." --show-output -- \
      aws ec2 create-security-group --region "$region" \
        --group-name "$sg_name" --description "WireGuard access for $name" \
        --vpc-id "$vpc_id" --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --region "$region" \
      --group-id "$sg_id" --protocol udp --port 51820 --cidr 0.0.0.0/0 >/dev/null
  fi

  # Launch instance
  local key_flag=()
  [[ -n "$key_name" ]] && key_flag=(--key-name "$key_name")

  local instance_id
  instance_id=$(gum spin --title "Launching EC2 instance..." --show-output -- \
    aws ec2 run-instances --region "$region" \
      --image-id "$ami" --instance-type "$itype" \
      "${key_flag[@]}" --security-group-ids "$sg_id" \
      --user-data "file://${wg_cloud_init}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]" \
      --query 'Instances[0].InstanceId' --output text)

  gum spin --title "Waiting for instance to be running..." -- \
    aws ec2 wait instance-running --region "$region" --instance-ids "$instance_id"

  # Allocate and associate an Elastic IP (#5)
  local alloc_id
  alloc_id=$(gum spin --title "Allocating Elastic IP..." --show-output -- \
    aws ec2 allocate-address --region "$region" --query 'AllocationId' --output text)
  gum spin --title "Associating Elastic IP..." -- \
    aws ec2 associate-address --region "$region" --instance-id "$instance_id" --allocation-id "$alloc_id"

  local ip
  ip=$(aws ec2 describe-addresses --region "$region" --allocation-ids "$alloc_id" \
       --query 'Addresses[0].PublicIp' --output text)

  show_qr "$ip" "$ssh_user"
}

ec2_destroy() {
  local region instances target iid
  region=$(gum choose --header "Region" us-east-1 us-west-2 eu-west-1 eu-north-1 ap-southeast-1)
  instances=$(aws ec2 describe-instances --region "$region" \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0]]' \
    --output text | while read -r id nm; do echo "${id}  ${nm:-(unnamed)}"; done || true)
  [[ -z "$instances" ]] && die "No EC2 instances in $region."

  target=$(echo "$instances" | gum choose --header "Select instance to terminate")
  iid=$(echo "$target" | awk '{print $1}')
  gum confirm "Terminate EC2 instance $iid? This is irreversible." || exit 0

  # Release Elastic IP before terminating (#5)
  local eip_alloc
  eip_alloc=$(aws ec2 describe-addresses --region "$region" \
    --filters "Name=instance-id,Values=$iid" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null || echo "None")
  if [[ "$eip_alloc" != "None" && -n "$eip_alloc" ]]; then
    aws ec2 release-address --region "$region" --allocation-id "$eip_alloc" 2>/dev/null || true
  fi

  gum spin --title "Terminating '$iid'..." -- \
    aws ec2 terminate-instances --region "$region" --instance-ids "$iid"

  # Try to clean up security group (#3)
  local sg_name="coder-deploy-$(echo "$target" | awk '{print $2}')"
  local sg_id
  sg_id=$(aws ec2 describe-security-groups --region "$region" \
    --filters "Name=group-name,Values=$sg_name" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
  if [[ "$sg_id" != "None" && -n "$sg_id" ]]; then
    sleep 5  # Wait for instance to fully release the SG
    aws ec2 delete-security-group --region "$region" --group-id "$sg_id" 2>/dev/null || true
  fi

  gum style --foreground 2 --bold "Terminated '$iid'."
  gum style --foreground 3 "Remember to remove the WireGuard tunnel from your phone/device."
}

ec2_status() {
  aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key==`Name`].Value|[0],State:State.Name,IP:PublicIpAddress,Type:InstanceType}' \
    --output table
}

# ── Provider: DigitalOcean ───────────────────────────────────────────────────

do_create() {
  local region size ssh_key name ssh_user="root"
  region=$(gum choose --header "Region" nyc1 lon1 fra1 sgp1)
  size=$(gum choose --header "Size" s-1vcpu-2gb s-2vcpu-4gb s-4vcpu-8gb)

  # SSH key selection from provider API (optional -- we generate our own via cloud-init)
  local available_keys ssh_key=""
  available_keys=$(doctl compute ssh-key list --format Name --no-header || true)
  if [[ -n "$available_keys" ]]; then
    ssh_key=$(echo "$available_keys" "$(gum style --faint '(skip - use generated key only)')" | gum choose --header "SSH key (optional)")
    [[ "$ssh_key" == *"skip"* ]] && ssh_key=""
  fi

  name=$(gum input --header "Droplet name" --value "dev-box")

  local key_display="${ssh_key:-generated (via cloud-init)}"
  gum style --bold "Summary"
  styled_box "Provider: DigitalOcean" "Region:   $region" "Size:     $size" "SSH key:  $key_display" "Name:     $name"
  gum style --foreground 3 "Warning: DigitalOcean creates droplets with no provider-level firewall."
  gum style --foreground 3 "All ports are open until cloud-init configures ufw (1-2 minutes)."
  gum style --foreground 3 "Consider adding a DO cloud firewall after creation for defense-in-depth."
  gum confirm "Create this droplet?" || exit 0

  # Set up WireGuard keys and build modified cloud-init
  setup_wireguard
  trap 'cleanup_wireguard' EXIT
  local wg_cloud_init
  wg_cloud_init=$(build_cloud_init "$ssh_user")

  local droplet_id
  local key_flag=()
  [[ -n "$ssh_key" ]] && key_flag=(--ssh-keys "$ssh_key")

  droplet_id=$(gum spin --title "Creating droplet '$name'..." --show-output -- \
    doctl compute droplet create "$name" \
      --region "$region" --size "$size" --image ubuntu-24-04-x64 \
      "${key_flag[@]}" --user-data-file "$wg_cloud_init" \
      --wait --format ID --no-header)

  # DigitalOcean droplet IPs are already static (don't change on reboot)
  local ip
  ip=$(doctl compute droplet get "$droplet_id" --format PublicIPv4 --no-header)

  show_qr "$ip" "$ssh_user"
}

do_destroy() {
  local instances target did
  instances=$(doctl compute droplet list --format "ID,Name,PublicIPv4,Status" --no-header || true)
  [[ -z "$instances" ]] && die "No droplets found."

  target=$(echo "$instances" | gum choose --header "Select droplet to destroy")
  did=$(echo "$target" | awk '{print $1}')
  gum confirm "Destroy droplet $did? This is irreversible." || exit 0
  gum spin --title "Destroying droplet '$did'..." -- doctl compute droplet delete "$did" --force
  gum style --foreground 2 --bold "Destroyed droplet '$did'."
  gum style --foreground 3 "Remember to remove the WireGuard tunnel from your phone/device."
}

do_status() {
  doctl compute droplet list --format "ID,Name,PublicIPv4,Region,Size,Status"
}

# ── Provider: Hetzner ────────────────────────────────────────────────────────

hetzner_create() {
  local location stype ssh_key name ssh_user="root"
  location=$(gum choose --header "Location" nbg1 fsn1 hel1 ash)
  stype=$(gum choose --header "Server type" cx22 cx32 cx42)

  # SSH key selection from provider API (optional -- we generate our own via cloud-init)
  local available_keys ssh_key=""
  available_keys=$(hcloud ssh-key list -o noheader -o columns=name || true)
  if [[ -n "$available_keys" ]]; then
    ssh_key=$(echo "$available_keys" "$(gum style --faint '(skip - use generated key only)')" | gum choose --header "SSH key (optional)")
    [[ "$ssh_key" == *"skip"* ]] && ssh_key=""
  fi

  name=$(gum input --header "Server name" --value "dev-box")

  local key_display="${ssh_key:-generated (via cloud-init)}"
  gum style --bold "Summary"
  styled_box "Provider: Hetzner" "Location: $location" "Type:     $stype" "SSH key:  $key_display" "Name:     $name"
  gum style --foreground 3 "Warning: Hetzner creates servers with no provider-level firewall."
  gum style --foreground 3 "All ports are open until cloud-init configures ufw (1-2 minutes)."
  gum style --foreground 3 "Consider adding a Hetzner firewall after creation for defense-in-depth."
  gum confirm "Create this server?" || exit 0

  # Set up WireGuard keys and build modified cloud-init
  setup_wireguard
  trap 'cleanup_wireguard' EXIT
  local wg_cloud_init
  wg_cloud_init=$(build_cloud_init "$ssh_user")

  local key_flag=()
  [[ -n "$ssh_key" ]] && key_flag=(--ssh-key "$ssh_key")

  local result
  result=$(gum spin --title "Creating server '$name'..." --show-output -- \
    hcloud server create --name "$name" \
      --type "$stype" --image ubuntu-24.04 \
      --location "$location" "${key_flag[@]}" \
      --user-data-from-file "$wg_cloud_init")

  # Hetzner cloud server IPs are already static
  local ip
  ip=$(hcloud server ip "$name")

  show_qr "$ip" "$ssh_user"
}

hetzner_destroy() {
  local instances target
  instances=$(hcloud server list -o noheader -o columns=name 2>/dev/null || true)
  [[ -z "$instances" ]] && die "No Hetzner servers found."

  target=$(echo "$instances" | gum choose --header "Select server to destroy")
  gum confirm "Destroy Hetzner server '$target'? This is irreversible." || exit 0
  gum spin --title "Destroying '$target'..." -- hcloud server delete "$target"
  gum style --foreground 2 --bold "Destroyed '$target'."
  gum style --foreground 3 "Remember to remove the WireGuard tunnel from your phone/device."
}

hetzner_status() {
  hcloud server list
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

choose_provider() {
  gum choose --header "Select provider" \
    "Lima (local)" "AWS Lightsail" "AWS EC2" "DigitalOcean" "Hetzner"
}

cmd_create() {
  local provider
  provider=$(choose_provider)

  # WireGuard tools required for all cloud providers (not Lima)
  if [[ "$provider" != "Lima (local)" ]]; then
    require_cli wg "WireGuard tools"
    require_cli qrencode qrencode
  fi

  case "$provider" in
    "Lima (local)")   require_cli limactl Lima;        lima_create ;;
    "AWS Lightsail")  require_cli aws "AWS CLI";       lightsail_create ;;
    "AWS EC2")        require_cli aws "AWS CLI";       ec2_create ;;
    "DigitalOcean")   require_cli doctl DigitalOcean;  do_create ;;
    "Hetzner")        require_cli hcloud Hetzner;      hetzner_create ;;
  esac
}

cmd_destroy() {
  local provider
  provider=$(choose_provider)

  case "$provider" in
    "Lima (local)")   require_cli limactl Lima;        lima_destroy ;;
    "AWS Lightsail")  require_cli aws "AWS CLI";       lightsail_destroy ;;
    "AWS EC2")        require_cli aws "AWS CLI";       ec2_destroy ;;
    "DigitalOcean")   require_cli doctl DigitalOcean;  do_destroy ;;
    "Hetzner")        require_cli hcloud Hetzner;      hetzner_destroy ;;
  esac
}

cmd_status() {
  local provider
  provider=$(choose_provider)

  case "$provider" in
    "Lima (local)")   require_cli limactl Lima;        lima_status ;;
    "AWS Lightsail")  require_cli aws "AWS CLI";       lightsail_status ;;
    "AWS EC2")        require_cli aws "AWS CLI";       ec2_status ;;
    "DigitalOcean")   require_cli doctl DigitalOcean;  do_status ;;
    "Hetzner")        require_cli hcloud Hetzner;      hetzner_status ;;
  esac
}

# ── Main ─────────────────────────────────────────────────────────────────────

require_gum

[[ -f "$CLOUD_INIT" ]] || die "cloud-init.yaml not found at $CLOUD_INIT"

case "${1:-create}" in
  create)  cmd_create ;;
  destroy) cmd_destroy ;;
  status)  cmd_status ;;
  *)       gum style --bold "Usage: $0 {create|destroy|status}" ; exit 1 ;;
esac
