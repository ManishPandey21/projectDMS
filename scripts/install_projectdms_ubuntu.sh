#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ProjectDMS Ubuntu installer.
#
# Default VPS target:
#   ubuntu@57.129.115.147 (vps-5dec80c1)
#
# Typical use from a machine with SSH access to the VPS:
#   bash scripts/install_projectdms_ubuntu.sh --remote
#
# Typical use directly on the Ubuntu server:
#   sudo DEPLOY_PROFILE=staging GITHUB_TOKEN=ghp_xxx bash scripts/install_projectdms_ubuntu.sh --server
#
# Production with HTTPS/domain and real external secrets:
#   sudo DEPLOY_PROFILE=production \
#     PUBLIC_BASE_URL=https://dms.example.com \
#     GITHUB_TOKEN=ghp_xxx \
#     OPENAI_API_KEY=sk-... \
#     AWS_ACCESS_KEY_ID=... \
#     AWS_SECRET_ACCESS_KEY=... \
#     AWS_BUCKET_NAME=... \
#     SMTP_USERNAME=... \
#     SMTP_PASSWORD=... \
#     SMTP_FROM_EMAIL=no-reply@example.com \
#     bash scripts/install_projectdms_ubuntu.sh --server

REMOTE_TARGET=${REMOTE_TARGET:-ubuntu@57.129.115.147}
REMOTE_LABEL=${REMOTE_LABEL:-vps-5dec80c1}
REPO_URL=${REPO_URL:-https://github.com/ManishPandey21/projectDMS.git}
REPO_BRANCH=${REPO_BRANCH:-main}
APP_DIR=${APP_DIR:-/opt/projectDMS}
DEPLOY_PROFILE=${DEPLOY_PROFILE:-staging} # staging or production
PUBLIC_BASE_URL=${PUBLIC_BASE_URL:-}
ENABLE_UFW=${ENABLE_UFW:-false}
FORCE_UPDATE=${FORCE_UPDATE:-false}
REGENERATE_ENV=${REGENERATE_ENV:-false}
RUN_READINESS=${RUN_READINESS:-false}
RUN_POST_VERIFY=${RUN_POST_VERIFY:-false}
ENV_SOURCE_FILE=${ENV_SOURCE_FILE:-}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { printf "${CYAN}[projectDMS]${NC} %s\n" "$*"; }
ok() { printf "${GREEN}[ok]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
die() { printf "${RED}[error]${NC} %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  bash scripts/install_projectdms_ubuntu.sh --remote
  sudo bash scripts/install_projectdms_ubuntu.sh --server

Modes:
  --remote   Copy this script to ubuntu@57.129.115.147 and run it with sudo.
  --server   Install/update the application on the current Ubuntu host.

Important environment variables:
  REMOTE_TARGET        SSH target for --remote. Default: ubuntu@57.129.115.147
  REPO_URL             GitHub repository URL. Default: ManishPandey21/projectDMS
  REPO_BRANCH          Branch to deploy. Default: main
  APP_DIR              Install directory. Default: /opt/projectDMS
  DEPLOY_PROFILE       staging or production. Default: staging
  PUBLIC_BASE_URL      Required for production; defaults to http://57.129.115.147 in staging
  GITHUB_TOKEN         Token for cloning the private GitHub repo over HTTPS
  ENV_SOURCE_FILE      Optional complete .env file to copy into the deployment
  ENABLE_UFW           true to configure UFW for SSH/HTTP/HTTPS. Default: false
  FORCE_UPDATE         true to reset APP_DIR to origin/REPO_BRANCH if local changes exist
  REGENERATE_ENV       true to replace existing .env files. Default: false
  RUN_READINESS        true to run repo pre-deploy readiness checks. Default: false
  RUN_POST_VERIFY      true to run repo post-deploy verification. Default: false

Production requires real values for:
  OPENAI_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_BUCKET_NAME
  SMTP_USERNAME SMTP_PASSWORD SMTP_FROM_EMAIL

Staging can bootstrap local-looking dummy external values so the stack starts,
but AI, S3, and email features will not work until those values are replaced.
EOF
}

mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) mode="remote" ;;
    --server) mode="server" ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

if [[ -z "$mode" ]]; then
  if [[ "$(uname -s 2>/dev/null || true)" == "Linux" && -f /etc/os-release ]]; then
    mode="server"
  else
    mode="remote"
  fi
fi

random_hex() {
  local bytes=${1:-32}
  openssl rand -hex "$bytes"
}

shell_quote() {
  printf "%q" "$1"
}

run_remote() {
  command -v ssh >/dev/null 2>&1 || die "ssh is required for --remote"
  command -v scp >/dev/null 2>&1 || die "scp is required for --remote"

  local script_path=${BASH_SOURCE[0]}
  [[ -f "$script_path" ]] || die "Cannot locate this script at $script_path"

  log "Uploading installer to $REMOTE_TARGET ($REMOTE_LABEL)"
  scp "$script_path" "$REMOTE_TARGET:/tmp/install_projectdms_ubuntu.sh"

  local remote_env=(
    "REPO_URL=$(shell_quote "$REPO_URL")"
    "REPO_BRANCH=$(shell_quote "$REPO_BRANCH")"
    "APP_DIR=$(shell_quote "$APP_DIR")"
    "DEPLOY_PROFILE=$(shell_quote "$DEPLOY_PROFILE")"
    "ENABLE_UFW=$(shell_quote "$ENABLE_UFW")"
    "FORCE_UPDATE=$(shell_quote "$FORCE_UPDATE")"
    "REGENERATE_ENV=$(shell_quote "$REGENERATE_ENV")"
    "RUN_READINESS=$(shell_quote "$RUN_READINESS")"
    "RUN_POST_VERIFY=$(shell_quote "$RUN_POST_VERIFY")"
  )

  if [[ -n "$PUBLIC_BASE_URL" ]]; then
    remote_env+=("PUBLIC_BASE_URL=$(shell_quote "$PUBLIC_BASE_URL")")
  fi

  warn "For private GitHub access, run with GITHUB_TOKEN already exported on the server or pass it in the SSH session intentionally."
  log "Starting remote installation"
  ssh -t "$REMOTE_TARGET" "sudo env ${remote_env[*]} bash /tmp/install_projectdms_ubuntu.sh --server"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run server mode with sudo/root"
  fi
}

require_ubuntu() {
  [[ -f /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This installer is intended for Ubuntu; found ID=${ID:-unknown}"
  ok "Ubuntu detected: ${PRETTY_NAME:-Ubuntu}"
}

install_base_packages() {
  log "Installing base packages"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg git jq openssl ufw lsb-release
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker and docker compose are already installed"
  else
    log "Installing Docker Engine and Compose plugin"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091
    source /etc/os-release
    local codename=${VERSION_CODENAME:-$(lsb_release -cs)}
    cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable
EOF
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  systemctl enable --now docker
  ok "Docker ready: $(docker --version)"
  ok "Compose ready: $(docker compose version)"
}

configure_firewall() {
  if [[ "$ENABLE_UFW" != "true" ]]; then
    warn "Skipping UFW changes. Set ENABLE_UFW=true to allow 22/80/443 and enable UFW."
    return
  fi

  log "Configuring UFW"
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
  ok "UFW enabled for SSH, HTTP, and HTTPS"
}

repo_clone_url() {
  if [[ "$REPO_URL" == https://github.com/* && -n "${GITHUB_TOKEN:-}" ]]; then
    printf "https://x-access-token:%s@%s" "$GITHUB_TOKEN" "${REPO_URL#https://}"
  else
    printf "%s" "$REPO_URL"
  fi
}

checkout_repo() {
  local app_parent
  app_parent=$(dirname "$APP_DIR")
  mkdir -p "$app_parent"

  if [[ -d "$APP_DIR/.git" ]]; then
    log "Updating existing checkout at $APP_DIR"
    git -C "$APP_DIR" remote set-url origin "$(repo_clone_url)"
    git -C "$APP_DIR" fetch origin "$REPO_BRANCH"
    if [[ -n "$(git -C "$APP_DIR" status --porcelain)" && "$FORCE_UPDATE" != "true" ]]; then
      die "Working tree has local changes. Set FORCE_UPDATE=true to reset it."
    fi
    git -C "$APP_DIR" checkout "$REPO_BRANCH"
    if [[ "$FORCE_UPDATE" == "true" ]]; then
      git -C "$APP_DIR" reset --hard "origin/$REPO_BRANCH"
    else
      git -C "$APP_DIR" pull --ff-only origin "$REPO_BRANCH"
    fi
  else
    log "Cloning $REPO_URL#$REPO_BRANCH into $APP_DIR"
    git clone --branch "$REPO_BRANCH" --single-branch "$(repo_clone_url)" "$APP_DIR"
  fi

  git -C "$APP_DIR" remote set-url origin "$REPO_URL"
  ok "Checked out $(git -C "$APP_DIR" rev-parse --short HEAD) on $REPO_BRANCH"
}

default_public_base_url() {
  if [[ -n "$PUBLIC_BASE_URL" ]]; then
    printf "%s" "${PUBLIC_BASE_URL%/}"
    return
  fi
  if [[ "$DEPLOY_PROFILE" == "production" ]]; then
    die "PUBLIC_BASE_URL=https://your-domain is required for production"
  fi
  printf "http://57.129.115.147"
}

require_production_secrets() {
  [[ "$DEPLOY_PROFILE" == "production" ]] || return 0
  local missing=()
  local key
  for key in OPENAI_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_BUCKET_NAME SMTP_USERNAME SMTP_PASSWORD SMTP_FROM_EMAIL; do
    if [[ -z "${!key:-}" ]]; then
      missing+=("$key")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Production deploy requires real external secrets: ${missing[*]}"
  fi
  [[ "$(default_public_base_url)" == https://* ]] || die "Production PUBLIC_BASE_URL must use https://"
}

external_or_dummy() {
  local name=$1
  local prefix=$2
  if [[ -n "${!name:-}" ]]; then
    printf "%s" "${!name}"
  else
    printf "%s-%s" "$prefix" "$(random_hex 12)"
  fi
}

write_env_files() {
  local env_file="$APP_DIR/.env"
  local backend_env="$APP_DIR/backend/.env"
  local client_env="$APP_DIR/client/.env.development"
  local public_base
  public_base=$(default_public_base_url)

  if [[ -f "$env_file" && "$REGENERATE_ENV" != "true" ]]; then
    ok "Keeping existing $env_file"
  elif [[ -n "$ENV_SOURCE_FILE" ]]; then
    [[ -f "$ENV_SOURCE_FILE" ]] || die "ENV_SOURCE_FILE not found: $ENV_SOURCE_FILE"
    install -m 0600 "$ENV_SOURCE_FILE" "$env_file"
    ok "Copied env from $ENV_SOURCE_FILE"
  else
    require_production_secrets

    local secret_key qdrant_key redis_password falkor_password metrics_token langgraph_token smtp_key
    secret_key=$(random_hex 48)
    qdrant_key=$(random_hex 24)
    redis_password=$(random_hex 24)
    falkor_password=$(random_hex 24)
    metrics_token=$(random_hex 24)
    langgraph_token=$(random_hex 24)
    smtp_key=$(random_hex 32)

    local auth_cookie_secure="false"
    local mongo_url="mongodb://mongo:27017/contraclaim"
    local mongo_rs=""
    local redis_url="redis://redis:6379/1"
    local contract_redis_url="redis://redis:6379/0"
    local falkor_url="redis://falkordb:6379"
    local falkor_env_password=""

    if [[ "$DEPLOY_PROFILE" == "production" ]]; then
      auth_cookie_secure="true"
      mongo_url="mongodb://mongo1:27017,mongo2:27017,mongo3:27017/contraclaim?replicaSet=rs0&retryWrites=true"
      mongo_rs="rs0"
      redis_url="redis://:${redis_password}@redis:6379/1"
      contract_redis_url="redis://:${redis_password}@redis:6379/0"
      falkor_url="redis://:${falkor_password}@falkordb:6379"
      falkor_env_password="$falkor_password"
    fi

    umask 077
    cat >"$env_file" <<EOF
COMPOSE_PROJECT_NAME=projectdms
ENVIRONMENT=${DEPLOY_PROFILE}
ENABLE_API_DOCS=false
ALLOW_DEV_HEADERS=false
RBAC_ENTITLEMENT_FAIL_OPEN=false
PUBLIC_BASE_URL=${public_base}
PUBLIC_API_URL=${public_base}/api
APP_URL=${public_base}
CORS_ORIGINS=${public_base}
DATABASE_URL=${mongo_url}
MONGODB_URI=${mongo_url}
MONGODB_DATABASE=contraclaim
MONGODB_APP_NAME=ProjectDMS
MONGODB_REPLICA_SET=${mongo_rs}
MONGODB_RETRY_WRITES=true
MONGODB_ALLOW_STANDALONE_PRODUCTION=false
SECRET_KEY=${secret_key}
AUTH_COOKIE_NAME=cc_access_token
AUTH_COOKIE_SECURE=${auth_cookie_secure}
AUTH_COOKIE_SAMESITE=lax
AUTH_COOKIE_DOMAIN=
OPENAI_API_KEY=$(external_or_dummy OPENAI_API_KEY sk-local)
OPENAI_MODEL=gpt-4o
AWS_ACCESS_KEY_ID=$(external_or_dummy AWS_ACCESS_KEY_ID aws-key)
AWS_SECRET_ACCESS_KEY=$(external_or_dummy AWS_SECRET_ACCESS_KEY aws-secret)
AWS_REGION=${AWS_REGION:-ap-south-1}
AWS_BUCKET_NAME=$(external_or_dummy AWS_BUCKET_NAME projectdms-bucket)
SMTP_HOST=${SMTP_HOST:-smtp.gmail.com}
SMTP_PORT=${SMTP_PORT:-587}
SMTP_USERNAME=$(external_or_dummy SMTP_USERNAME smtp-user)
SMTP_PASSWORD=$(external_or_dummy SMTP_PASSWORD smtp-pass)
SMTP_FROM_EMAIL=${SMTP_FROM_EMAIL:-noreply@projectdms.local}
SMTP_FROM_NAME=ProjectDMS
SMTP_ENCRYPTION=starttls
SMTP_SETTINGS_ENCRYPTION_KEY=${SMTP_SETTINGS_ENCRYPTION_KEY:-$smtp_key}
PAYMENT_PROVIDER=noop
REDIS_PASSWORD=${redis_password}
APP_REDIS_URL=${redis_url}
RUNTIME_STATE_REDIS_URL=${redis_url}
CONTRACT_QUEUE_REDIS_URL=${contract_redis_url}
FALKORDB_ENABLED=true
FALKORDB_HOST=falkordb
FALKORDB_PORT=6379
FALKORDB_URL=${falkor_url}
FALKORDB_GRAPH_NAME=contraclaim
FALKORDB_PASSWORD=${falkor_env_password}
GRAPH_PROVIDER=direct_falkor
GRAPHITI_ENABLED=false
QDRANT_API_KEY=${qdrant_key}
QDRANT_URL=http://qdrant:6333
VECTORDB_URL=http://qdrant:6333
VECTORDB_API_KEY=${qdrant_key}
LANGGRAPH_ENABLED=false
LANGGRAPH_API_TOKEN=${langgraph_token}
METRICS_ENABLED=true
METRICS_TOKEN=${metrics_token}
LOG_LEVEL=INFO
OBSERVABILITY_STORE_RAW_QUERIES=false
ANTIVIRUS_ENABLED=false
CLAMAV_HOST=clamav
CLAMAV_PORT=3310
CLAMAV_FAIL_OPEN=true
UPLOADS_DIR=/app/uploads
SECURE_UPLOADS_DIR=/app/uploads
GENERAL_UPLOAD_MAX_FILE_SIZE_MB=100
UPLOAD_MAX_CONCURRENT_PER_USER=3
UPLOAD_MAX_CONCURRENT_PER_ORG=20
EOF
    ok "Generated $env_file"
    if [[ "$DEPLOY_PROFILE" == "staging" ]]; then
      warn "Generated local-looking dummy OpenAI/AWS/SMTP values for staging. Replace them before relying on AI, S3, or email."
    fi
  fi

  install -m 0600 "$env_file" "$backend_env"
  cat >"$client_env" <<EOF
VITE_API_BASE_URL=/api
VITE_LANGGRAPH_ENABLED=false
EOF

  mkdir -p "$APP_DIR/config/secrets"
  local qdrant_key
  qdrant_key=$(grep -E '^QDRANT_API_KEY=' "$env_file" | tail -n 1 | cut -d= -f2-)
  printf "%s" "$qdrant_key" >"$APP_DIR/config/secrets/qdrant_api_key"
  chmod 0600 "$APP_DIR/config/secrets/qdrant_api_key"
  ok "Environment files prepared"
}

compose_files=()
set_compose_files() {
  case "$DEPLOY_PROFILE" in
    staging)
      compose_files=(-f "$APP_DIR/docker-compose.yml")
      ;;
    production)
      compose_files=(-f "$APP_DIR/docker-compose.mongo-replicaset.yml" -f "$APP_DIR/docker-compose.prod.yml")
      ;;
    *)
      die "DEPLOY_PROFILE must be staging or production"
      ;;
  esac
}

compose() {
  docker compose --env-file "$APP_DIR/.env" "${compose_files[@]}" "$@"
}

run_readiness_checks() {
  [[ "$RUN_READINESS" == "true" ]] || return 0
  if [[ "$DEPLOY_PROFILE" != "production" ]]; then
    warn "Skipping production readiness checks for DEPLOY_PROFILE=$DEPLOY_PROFILE"
    return 0
  fi
  log "Running production readiness checks"
  COMPOSE_FILES="-f docker-compose.mongo-replicaset.yml -f docker-compose.prod.yml" \
    ROOT_DIR="$APP_DIR" ENV_FILE="$APP_DIR/.env" BACKEND_ENV_FILE="$APP_DIR/backend/.env" \
    bash "$APP_DIR/scripts/pre_deploy_readiness.sh" || warn "Readiness script reported issues; continuing because installer checks already passed"
}

start_stack() {
  set_compose_files
  cd "$APP_DIR"

  log "Validating compose configuration"
  compose config >/tmp/projectdms-compose-config.yml
  ok "Compose config is valid"

  run_readiness_checks

  if [[ "$DEPLOY_PROFILE" == "production" ]]; then
    log "Starting MongoDB replica-set members"
    docker compose --env-file "$APP_DIR/.env" -f "$APP_DIR/docker-compose.mongo-replicaset.yml" up -d mongo1 mongo2 mongo3
    log "Initializing MongoDB replica set"
    docker compose --env-file "$APP_DIR/.env" -f "$APP_DIR/docker-compose.mongo-replicaset.yml" run --rm mongo-init
  fi

  log "Pulling base images where available"
  compose pull --ignore-buildable || true

  log "Building and starting ProjectDMS stack"
  compose up -d --build
  ok "Stack started"
}

verify_stack() {
  local attempts=30
  local sleep_seconds=5

  log "Waiting for gateway health"
  for _ in $(seq 1 "$attempts"); do
    if curl -fsS --max-time 5 http://127.0.0.1/health >/dev/null 2>&1; then
      ok "Gateway health endpoint responded"
      break
    fi
    sleep "$sleep_seconds"
  done

  log "Checking backend readiness from inside the backend container"
  if compose exec -T backend curl -fsS --max-time 10 http://localhost:8000/health/ready >/dev/null; then
    ok "Backend ready"
  else
    warn "Backend readiness failed. Inspect: docker compose logs backend"
  fi

  compose ps

  if [[ "$RUN_POST_VERIFY" == "true" && "$DEPLOY_PROFILE" == "production" ]]; then
    log "Running post-deploy verification"
    COMPOSE_FILES="-f docker-compose.mongo-replicaset.yml -f docker-compose.prod.yml" \
      ROOT_DIR="$APP_DIR" ENV_FILE="$APP_DIR/.env" BACKEND_ENV_FILE="$APP_DIR/backend/.env" \
      BACKEND_BASE_URL="http://localhost:8000" PUBLIC_BASE_URL="$(default_public_base_url)" \
      bash "$APP_DIR/scripts/post_deploy_verify.sh" || warn "Post-deploy verification reported warnings/failures"
  fi
}

server_install() {
  require_root
  require_ubuntu
  install_base_packages
  install_docker
  configure_firewall
  checkout_repo
  write_env_files
  start_stack
  verify_stack

  cat <<EOF

ProjectDMS install finished.

Server:      ${REMOTE_LABEL} (${REMOTE_TARGET})
Directory:   ${APP_DIR}
Branch:      ${REPO_BRANCH}
Profile:     ${DEPLOY_PROFILE}
Public URL:  $(default_public_base_url)

Useful commands on the server:
  cd ${APP_DIR}
  docker compose --env-file .env ${compose_files[*]} ps
  docker compose --env-file .env ${compose_files[*]} logs -f backend
  sudo nano ${APP_DIR}/.env

EOF
}

case "$mode" in
  remote) run_remote ;;
  server) server_install ;;
  *) die "Invalid mode: $mode" ;;
esac
