#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.production.yml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; }
generate_secret() { openssl rand -hex 64; }

# ---------------------------------------------------------------------------
# 1. Check prerequisites
# ---------------------------------------------------------------------------
info "Checking prerequisites..."

if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Install it from https://docs.docker.com/engine/install/"
  exit 1
fi

if ! docker compose version &>/dev/null; then
  error "Docker Compose (v2) is not available. Update Docker or install the compose plugin."
  exit 1
fi

info "Docker $(docker --version | awk '{print $3}') found."

# ---------------------------------------------------------------------------
# 2. Create .env from template if it doesn't exist
# ---------------------------------------------------------------------------
if [ ! -f .env ]; then
  info "Creating .env from .env.example..."
  cp .env.example .env

  # Auto-generate secrets
  sed -i.bak "s/^POSTGRES_PASSWORD=$/POSTGRES_PASSWORD=$(generate_secret)/" .env
  sed -i.bak "s/^SECRET_KEY_BASE=$/SECRET_KEY_BASE=$(generate_secret)/" .env
  sed -i.bak "s/^ANYCABLE_SECRET=$/ANYCABLE_SECRET=$(generate_secret)/" .env
  sed -i.bak "s/^RATING_ENGINE_PASSWORD=$/RATING_ENGINE_PASSWORD=$(generate_secret)/" .env
  rm -f .env.bak

  echo ""
  echo "============================================================"
  echo "  .env file created with auto-generated secrets."
  echo ""
  echo "  You MUST edit .env and set these values before continuing:"
  echo "    - DOMAIN           (your domain name)"
  echo "    - FS_EXTERNAL_SIP_IP  (this server's public IP)"
  echo "    - FS_EXTERNAL_RTP_IP  (this server's public IP)"
  echo "============================================================"
  echo ""
  read -rp "Press Enter after editing .env to continue (or Ctrl+C to abort)..."
fi

# ---------------------------------------------------------------------------
# 3. Validate required settings
# ---------------------------------------------------------------------------
info "Validating configuration..."

source .env

if [ -z "${DOMAIN:-}" ] || [ "$DOMAIN" = "somleng.example.com" ]; then
  error "DOMAIN is not set in .env. Please set it to your domain name."
  exit 1
fi

if [ -z "${FS_EXTERNAL_SIP_IP:-}" ]; then
  error "FS_EXTERNAL_SIP_IP is not set in .env. Please set it to this server's public IP."
  exit 1
fi

if [ -z "${FS_EXTERNAL_RTP_IP:-}" ]; then
  error "FS_EXTERNAL_RTP_IP is not set in .env. Please set it to this server's public IP."
  exit 1
fi

info "Configuration looks good."

# ---------------------------------------------------------------------------
# 4. Pull images
# ---------------------------------------------------------------------------
info "Pulling container images (this may take a few minutes)..."
docker compose -f "$COMPOSE_FILE" pull

# ---------------------------------------------------------------------------
# 5. Bootstrap the database
# ---------------------------------------------------------------------------
info "Bootstrapping the database..."
BOOTSTRAP_OUTPUT=$(docker compose -f "$COMPOSE_FILE" --profile bootstrap run --rm -T somleng-bootstrap 2>&1) || true
echo "$BOOTSTRAP_OUTPUT"

# Extract credentials from bootstrap output
ACCOUNT_SID=$(echo "$BOOTSTRAP_OUTPUT" | grep -oP 'account_sid:\s*\K\S+' || true)
AUTH_TOKEN=$(echo "$BOOTSTRAP_OUTPUT" | grep -oP 'auth_token:\s*\K\S+' || true)
PHONE_NUMBER=$(echo "$BOOTSTRAP_OUTPUT" | grep -oP 'phone_number:\s*\K\S+' || true)

# ---------------------------------------------------------------------------
# 6. Start all services
# ---------------------------------------------------------------------------
info "Starting all services..."
docker compose -f "$COMPOSE_FILE" up -d --wait

# ---------------------------------------------------------------------------
# 7. Print summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Somleng Platform is running!"
echo "============================================================"
echo ""
echo "  Dashboard:  https://${DOMAIN}"
echo "  API Base:   https://${DOMAIN}/api"
echo "  SIP:        ${FS_EXTERNAL_SIP_IP}:5060 (UDP)"
echo ""
if [ -n "${ACCOUNT_SID:-}" ]; then
  echo "  Account SID:  ${ACCOUNT_SID}"
  echo "  Auth Token:   ${AUTH_TOKEN}"
  echo "  Phone Number: ${PHONE_NUMBER}"
  echo ""
fi
echo "  Useful commands:"
echo "    docker compose -f $COMPOSE_FILE ps      # Check service status"
echo "    docker compose -f $COMPOSE_FILE logs -f  # Follow logs"
echo "    docker compose -f $COMPOSE_FILE down     # Stop all services"
echo "============================================================"
