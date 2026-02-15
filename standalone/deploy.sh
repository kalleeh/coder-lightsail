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
    limactl) gum style "  brew install lima" ;;
    aws)     gum style "  brew install awscli   # or pip install awscli" ;;
    doctl)   gum style "  brew install doctl" ;;
    hcloud)  gum style "  brew install hcloud" ;;
  esac
  exit 1
}

styled_box() { gum style --border double --padding "1 2" --border-foreground 6 "$@"; }

# ── Provider: Lima (local) ───────────────────────────────────────────────────

lima_create() {
  local cpus memory name
  cpus=$(gum choose --header "CPUs" 1 2 4)
  memory=$(gum choose --header "Memory" "2GiB" "4GiB" "8GiB")
  name=$(gum input --header "Instance name" --value "coder-dev")

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
}

lima_status() {
  limactl list
}

# ── Provider: AWS Lightsail ──────────────────────────────────────────────────

lightsail_create() {
  local region bundle key_name name
  region=$(gum choose --header "Region" us-east-1 eu-west-1 eu-north-1 ap-southeast-1)
  bundle=$(gum choose --header "Bundle" small_3_0 medium_3_0 large_3_0)
  key_name=$(gum input --header "SSH key name (in Lightsail)")
  name=$(gum input --header "Instance name" --value "coder-dev")

  gum style --bold "Summary"
  styled_box "Provider: AWS Lightsail" "Region:   $region" "Bundle:   $bundle" "SSH key:  $key_name" "Name:     $name"
  gum confirm "Create this instance?" || exit 0

  gum spin --title "Creating Lightsail instance '$name'..." -- \
    aws lightsail create-instances \
      --instance-names "$name" \
      --availability-zone "${region}a" \
      --blueprint-id ubuntu_24_04 \
      --bundle-id "$bundle" \
      --key-pair-name "$key_name" \
      --user-data "$(cat "$CLOUD_INIT")" \
      --region "$region"

  gum spin --title "Waiting for instance to be running..." -- \
    aws lightsail wait instance-running --instance-name "$name" --region "$region" 2>/dev/null || sleep 15

  local ip
  ip=$(aws lightsail get-instance --instance-name "$name" --region "$region" \
       --query 'instance.publicIpAddress' --output text)

  styled_box "Lightsail instance '$name' is running!" "" "IP:   $ip" "SSH:  ssh ubuntu@$ip"
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
  gum style --foreground 2 --bold "Destroyed '$target'."
}

lightsail_status() {
  aws lightsail get-instances --query \
    'instances[].{Name:name,State:state.name,IP:publicIpAddress,Blueprint:blueprintId}' \
    --output table
}

# ── Provider: AWS EC2 ────────────────────────────────────────────────────────

ec2_create() {
  local region itype key_name name
  region=$(gum choose --header "Region" us-east-1 us-west-2 eu-west-1 eu-north-1 ap-southeast-1)
  itype=$(gum choose --header "Instance type" t3.small t3.medium t3.large)
  key_name=$(gum input --header "Key pair name (in EC2)")
  name=$(gum input --header "Instance name" --value "coder-dev")

  gum style --bold "Summary"
  styled_box "Provider: AWS EC2" "Region:   $region" "Type:     $itype" "Key pair: $key_name" "Name:     $name"
  gum confirm "Create this instance?" || exit 0

  # Look up latest Ubuntu 24.04 AMI
  local ami
  ami=$(gum spin --title "Looking up Ubuntu 24.04 AMI..." --show-output -- \
    aws ec2 describe-images --region "$region" \
      --owners 099720109477 \
      --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
                "Name=state,Values=available" \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  [[ -z "$ami" || "$ami" == "None" ]] && die "Could not find Ubuntu 24.04 AMI in $region."

  # Create security group
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
        --group-name "$sg_name" --description "SSH access for $name" \
        --vpc-id "$vpc_id" --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --region "$region" \
      --group-id "$sg_id" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
  fi

  # Launch instance
  local instance_id
  instance_id=$(gum spin --title "Launching EC2 instance..." --show-output -- \
    aws ec2 run-instances --region "$region" \
      --image-id "$ami" --instance-type "$itype" \
      --key-name "$key_name" --security-group-ids "$sg_id" \
      --user-data "file://${CLOUD_INIT}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]" \
      --query 'Instances[0].InstanceId' --output text)

  gum spin --title "Waiting for instance to be running..." -- \
    aws ec2 wait instance-running --region "$region" --instance-ids "$instance_id"

  local ip
  ip=$(aws ec2 describe-instances --region "$region" --instance-ids "$instance_id" \
       --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

  styled_box "EC2 instance '$name' is running!" "" "ID:   $instance_id" "IP:   $ip" "SSH:  ssh ubuntu@$ip"
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
  gum spin --title "Terminating '$iid'..." -- \
    aws ec2 terminate-instances --region "$region" --instance-ids "$iid"
  gum style --foreground 2 --bold "Terminated '$iid'."
}

ec2_status() {
  aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key==`Name`].Value|[0],State:State.Name,IP:PublicIpAddress,Type:InstanceType}' \
    --output table
}

# ── Provider: DigitalOcean ───────────────────────────────────────────────────

do_create() {
  local region size ssh_key name
  region=$(gum choose --header "Region" nyc1 lon1 fra1 sgp1)
  size=$(gum choose --header "Size" s-1vcpu-2gb s-2vcpu-4gb s-4vcpu-8gb)
  ssh_key=$(gum input --header "SSH key name (in DigitalOcean)")
  name=$(gum input --header "Droplet name" --value "coder-dev")

  gum style --bold "Summary"
  styled_box "Provider: DigitalOcean" "Region:   $region" "Size:     $size" "SSH key:  $ssh_key" "Name:     $name"
  gum confirm "Create this droplet?" || exit 0

  local droplet_id
  droplet_id=$(gum spin --title "Creating droplet '$name'..." --show-output -- \
    doctl compute droplet create "$name" \
      --region "$region" --size "$size" --image ubuntu-24-04-x64 \
      --ssh-keys "$ssh_key" --user-data-file "$CLOUD_INIT" \
      --wait --format ID --no-header)

  local ip
  ip=$(doctl compute droplet get "$droplet_id" --format PublicIPv4 --no-header)

  styled_box "Droplet '$name' is running!" "" "ID:   $droplet_id" "IP:   $ip" "SSH:  ssh root@$ip"
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
}

do_status() {
  doctl compute droplet list --format "ID,Name,PublicIPv4,Region,Size,Status"
}

# ── Provider: Hetzner ────────────────────────────────────────────────────────

hetzner_create() {
  local location stype ssh_key name
  location=$(gum choose --header "Location" nbg1 fsn1 hel1 ash)
  stype=$(gum choose --header "Server type" cx22 cx32 cx42)
  ssh_key=$(gum input --header "SSH key name (in Hetzner)")
  name=$(gum input --header "Server name" --value "coder-dev")

  gum style --bold "Summary"
  styled_box "Provider: Hetzner" "Location: $location" "Type:     $stype" "SSH key:  $ssh_key" "Name:     $name"
  gum confirm "Create this server?" || exit 0

  local result
  result=$(gum spin --title "Creating server '$name'..." --show-output -- \
    hcloud server create --name "$name" \
      --type "$stype" --image ubuntu-24.04 \
      --location "$location" --ssh-key "$ssh_key" \
      --user-data-from-file "$CLOUD_INIT")

  local ip
  ip=$(hcloud server ip "$name")

  styled_box "Hetzner server '$name' is running!" "" "IP:   $ip" "SSH:  ssh root@$ip"
}

hetzner_destroy() {
  local instances target
  instances=$(hcloud server list -o noheader -o columns=name 2>/dev/null || true)
  [[ -z "$instances" ]] && die "No Hetzner servers found."

  target=$(echo "$instances" | gum choose --header "Select server to destroy")
  gum confirm "Destroy Hetzner server '$target'? This is irreversible." || exit 0
  gum spin --title "Destroying '$target'..." -- hcloud server delete "$target"
  gum style --foreground 2 --bold "Destroyed '$target'."
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
