#!/usr/bin/env bash
# =============================================================================
# Somleng Platform — One-Command Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<your-repo>/deploy/install.sh | bash
#
# Or on a fresh server:
#   chmod +x install.sh && ./install.sh --domain chorus-ai.co
#
# Supports: Ubuntu 22.04+, Debian 12+, Amazon Linux 2023, RHEL 9+
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DOMAIN=""
PUBLIC_IP=""
REPO_URL="https://github.com/somleng/somleng-project.git"
BRANCH="main"
INSTALL_DIR="/opt/somleng"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --domain <domain>       Your domain name (e.g., chorus-ai.co)
  --ip <ip>               Public IP of this server (auto-detected if omitted)
  --repo <url>            Git repo URL (default: $REPO_URL)
  --branch <branch>       Git branch (default: $BRANCH)
  --dir <path>            Install directory (default: $INSTALL_DIR)
  -h, --help              Show this help message

Example:
  $0 --domain chorus-ai.co
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)  DOMAIN="$2"; shift 2 ;;
    --ip)      PUBLIC_IP="$2"; shift 2 ;;
    --repo)    REPO_URL="$2"; shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    --dir)     INSTALL_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *)         echo "Unknown option: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
generate_secret() { openssl rand -hex 64; }

# ---------------------------------------------------------------------------
# 1. Detect OS and public IP
# ---------------------------------------------------------------------------
info "Detecting environment..."

if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com || \
              curl -s --max-time 5 https://ifconfig.me || \
              curl -s --max-time 5 https://api.ipify.org || true)
fi

if [ -z "$PUBLIC_IP" ]; then
  error "Could not detect public IP. Pass it with --ip <your-ip>"
  exit 1
fi

ok "Public IP: $PUBLIC_IP"

# ---------------------------------------------------------------------------
# 2. Prompt for domain if not provided
# ---------------------------------------------------------------------------
if [ -z "$DOMAIN" ]; then
  echo ""
  read -rp "Enter your domain name (e.g., chorus-ai.co): " DOMAIN
  echo ""
fi

if [ -z "$DOMAIN" ]; then
  error "Domain is required. Pass it with --domain <your-domain>"
  exit 1
fi

ok "Domain: $DOMAIN"

echo ""
echo "============================================================"
echo "  Before continuing, set up these DNS records:"
echo ""
echo "    A    $DOMAIN        →  $PUBLIC_IP"
echo "    A    *.$DOMAIN      →  $PUBLIC_IP"
echo ""
echo "  The wildcard record enables:"
echo "    apisip.$DOMAIN              — REST API"
echo "    appsip.$DOMAIN              — Main dashboard"
echo "    <carrier>.appsip.$DOMAIN    — Carrier dashboards"
echo "    verifysip.$DOMAIN           — Verify API"
echo "============================================================"
echo ""
read -rp "Press Enter once DNS is configured (or Ctrl+C to abort)..."

# ---------------------------------------------------------------------------
# 3. Install Docker if missing
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  info "Installing Docker..."

  if command -v apt-get &>/dev/null; then
    # Debian / Ubuntu
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | \
      sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  elif command -v yum &>/dev/null; then
    # RHEL / Amazon Linux
    sudo yum install -y docker
    sudo systemctl start docker
    sudo systemctl enable docker
    # Install compose plugin
    sudo mkdir -p /usr/local/lib/docker/cli-plugins
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name"' | sed 's/.*"v//' | sed 's/".*//')
    sudo curl -SL "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  else
    info "Falling back to convenience script..."
    curl -fsSL https://get.docker.com | sh
  fi

  # Add current user to docker group
  if [ "$(id -u)" -ne 0 ]; then
    sudo usermod -aG docker "$USER"
    warn "Added $USER to docker group. Using sudo for remaining commands."
  fi

  ok "Docker installed: $(docker --version)"
else
  ok "Docker already installed: $(docker --version)"
fi

# Ensure we can run docker (use sudo if needed)
DOCKER_CMD="docker"
if ! docker info &>/dev/null 2>&1; then
  DOCKER_CMD="sudo docker"
fi

if ! $DOCKER_CMD compose version &>/dev/null 2>&1; then
  error "Docker Compose (v2) is not available."
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Clone the repo
# ---------------------------------------------------------------------------
info "Setting up $INSTALL_DIR ..."

if [ -d "$INSTALL_DIR/deploy" ]; then
  info "Existing installation found, pulling latest..."
  cd "$INSTALL_DIR"
  git pull --ff-only origin "$BRANCH" || true
else
  sudo mkdir -p "$INSTALL_DIR"
  sudo chown "$(id -u):$(id -g)" "$INSTALL_DIR"
  git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR/deploy"
ok "Deploy files ready at $INSTALL_DIR/deploy"

# ---------------------------------------------------------------------------
# 5. Generate .env
# ---------------------------------------------------------------------------
COMPOSE_FILE="docker-compose.production.yml"

if [ ! -f .env ]; then
  info "Generating .env with secrets..."
  cp .env.example .env

  # Set domain and IPs
  sed -i.bak "s/^DOMAIN=.*/DOMAIN=$DOMAIN/" .env
  sed -i.bak "s/^FS_EXTERNAL_SIP_IP=.*/FS_EXTERNAL_SIP_IP=$PUBLIC_IP/" .env
  sed -i.bak "s/^FS_EXTERNAL_RTP_IP=.*/FS_EXTERNAL_RTP_IP=$PUBLIC_IP/" .env

  # Generate secrets
  sed -i.bak "s/^POSTGRES_PASSWORD=$/POSTGRES_PASSWORD=$(generate_secret)/" .env
  sed -i.bak "s/^SECRET_KEY_BASE=$/SECRET_KEY_BASE=$(generate_secret)/" .env
  sed -i.bak "s/^ANYCABLE_SECRET=$/ANYCABLE_SECRET=$(generate_secret)/" .env
  sed -i.bak "s/^RATING_ENGINE_PASSWORD=$/RATING_ENGINE_PASSWORD=$(generate_secret)/" .env

  rm -f .env.bak
  ok ".env created with auto-generated secrets"
else
  warn ".env already exists, skipping generation"
fi

# ---------------------------------------------------------------------------
# 6. Open firewall ports
# ---------------------------------------------------------------------------
info "Configuring firewall..."

if command -v ufw &>/dev/null; then
  sudo ufw allow 22/tcp   >/dev/null 2>&1 || true
  sudo ufw allow 80/tcp   >/dev/null 2>&1 || true
  sudo ufw allow 443/tcp  >/dev/null 2>&1 || true
  sudo ufw allow 5060/udp >/dev/null 2>&1 || true
  sudo ufw --force enable >/dev/null 2>&1 || true
  ok "UFW: ports 22, 80, 443, 5060/udp opened"
elif command -v firewall-cmd &>/dev/null; then
  sudo firewall-cmd --permanent --add-service=ssh    >/dev/null 2>&1 || true
  sudo firewall-cmd --permanent --add-service=http   >/dev/null 2>&1 || true
  sudo firewall-cmd --permanent --add-service=https  >/dev/null 2>&1 || true
  sudo firewall-cmd --permanent --add-port=5060/udp  >/dev/null 2>&1 || true
  sudo firewall-cmd --reload                         >/dev/null 2>&1 || true
  ok "firewalld: ports 22, 80, 443, 5060/udp opened"
else
  warn "No firewall manager detected. Make sure ports 80, 443, 5060/udp are open."
fi

# ---------------------------------------------------------------------------
# 7. Pull images
# ---------------------------------------------------------------------------
info "Pulling container images (this may take a few minutes)..."
$DOCKER_CMD compose -f "$COMPOSE_FILE" pull

# ---------------------------------------------------------------------------
# 8. Bootstrap database
# ---------------------------------------------------------------------------
info "Bootstrapping the database..."
BOOTSTRAP_OUTPUT=$($DOCKER_CMD compose -f "$COMPOSE_FILE" --profile bootstrap run --rm -T somleng-bootstrap 2>&1) || true
echo "$BOOTSTRAP_OUTPUT"

# Extract credentials (works on both GNU and BSD grep)
ACCOUNT_SID=$(echo "$BOOTSTRAP_OUTPUT" | grep 'account_sid:' | awk '{print $NF}' || true)
AUTH_TOKEN=$(echo "$BOOTSTRAP_OUTPUT" | grep 'auth_token:' | awk '{print $NF}' || true)

# ---------------------------------------------------------------------------
# 9. Start all services
# ---------------------------------------------------------------------------
info "Starting all services..."
$DOCKER_CMD compose -f "$COMPOSE_FILE" up -d --wait

# ---------------------------------------------------------------------------
# 10. Verify
# ---------------------------------------------------------------------------
info "Verifying deployment..."
sleep 5

HEALTH_STATUS=$($DOCKER_CMD compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null | \
  python3 -c "
import sys, json
lines = sys.stdin.read().strip().split('\n')
all_healthy = True
for line in lines:
    svc = json.loads(line)
    name = svc.get('Service','')
    health = svc.get('Health','')
    state = svc.get('State','')
    if state == 'running' and health and health != 'healthy':
        all_healthy = False
        print(f'  UNHEALTHY: {name}')
if all_healthy:
    print('  All services healthy')
" 2>/dev/null || echo "  Could not verify (check manually with: docker compose ps)")

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo ""
echo "  Somleng Platform is running!"
echo ""
echo "============================================================"
echo ""
echo "  Dashboard:       https://appsip.$DOMAIN"
echo "  Carrier Login:   https://my-carrier.appsip.$DOMAIN"
echo "  API Endpoint:    https://apisip.$DOMAIN"
echo "  SIP:             $PUBLIC_IP:5060 (UDP)"
echo ""
if [ -n "${ACCOUNT_SID:-}" ]; then
  echo "  Account SID:     $ACCOUNT_SID"
  echo "  Auth Token:      $AUTH_TOKEN"
  echo ""
  echo "  Test the API:"
  echo "    curl -u \"\$ACCOUNT_SID:\$AUTH_TOKEN\" \\"
  echo "      https://apisip.$DOMAIN/2010-04-01/Accounts/$ACCOUNT_SID.json"
  echo ""
fi
echo "  $HEALTH_STATUS"
echo ""
echo "  Manage:"
echo "    cd $INSTALL_DIR/deploy"
echo "    docker compose -f $COMPOSE_FILE ps        # Status"
echo "    docker compose -f $COMPOSE_FILE logs -f    # Logs"
echo "    docker compose -f $COMPOSE_FILE down       # Stop"
echo "    docker compose -f $COMPOSE_FILE up -d      # Start"
echo ""
echo "  Credentials saved in: $INSTALL_DIR/deploy/.env"
echo ""
echo "============================================================"
