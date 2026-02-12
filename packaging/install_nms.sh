#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-}"

APP_DIR="${APP_DIR:-/opt/nms/app}"
VENV_DIR="${VENV_DIR:-/opt/nms/venv}"
NMS_USER="${NMS_USER:-nms}"
NMS_GROUP="${NMS_GROUP:-nms}"

CONFIG_DIR="${CONFIG_DIR:-/etc/nms}"
CONFIG_FILE="${CONFIG_FILE:-/etc/nms/config.yaml}"

DB_NAME="${DB_NAME:-nms}"
DB_USER="${DB_USER:-nms}"
DB_PASS="${DB_PASS:-}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"

API_APP_IMPORT="${API_APP_IMPORT:-}"
WORKER_MODULE="${WORKER_MODULE:-}"
MIGRATE_CMD="${MIGRATE_CMD:-}"
ENSURE_ADMIN_CMD="${ENSURE_ADMIN_CMD:-}"   # use __PASS__ placeholder

WORKER_ROLES_DEFAULT="poller,processor,alerts,availability,traps,backup"
WORKER_ROLES="${WORKER_ROLES:-$WORKER_ROLES_DEFAULT}"

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"

ENABLE_CADDY="${ENABLE_CADDY:-true}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"

log() { echo -e "\n==> $*\n"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root: sudo $0"; }

rand_pw() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
}

validate_required_vars() {
  [[ -n "$API_APP_IMPORT" ]] || die "API_APP_IMPORT is required (e.g. app.main:app)"
  [[ -n "$WORKER_MODULE" ]] || die "WORKER_MODULE is required (e.g. yourpkg.worker.main)"
  [[ -n "$MIGRATE_CMD" ]] || die "MIGRATE_CMD is required (e.g. python -m yourpkg.db migrate)"
  [[ -n "$ENSURE_ADMIN_CMD" ]] || die "ENSURE_ADMIN_CMD is required (use __PASS__ placeholder)"
}

ensure_group_user() {
  if ! getent group "$NMS_GROUP" >/dev/null 2>&1; then
    groupadd --system "$NMS_GROUP"
  fi
  if ! id -u "$NMS_USER" >/dev/null 2>&1; then
    useradd --system --home /opt/nms --shell /usr/sbin/nologin --gid "$NMS_GROUP" "$NMS_USER"
  fi
}

install_packages() {
  log "Installing OS packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y install \
    ca-certificates curl git jq \
    python3 python3-venv python3-pip \
    postgresql postgresql-contrib \
    caddy \
    build-essential libpq-dev
  systemctl enable --now postgresql
}

clone_or_validate_repo() {
  log "Setting up NMS app source at $APP_DIR"
  install -d -m 0755 "$(dirname "$APP_DIR")"
  if [[ -d "$APP_DIR/.git" ]]; then
    log "Repo already exists at $APP_DIR (leaving as-is)"
  elif [[ -d "$APP_DIR" && -n "$(ls -A "$APP_DIR" 2>/dev/null || true)" ]]; then
    log "Directory $APP_DIR exists and is non-empty (leaving as-is)"
  else
    [[ -n "$REPO_URL" ]] || die "REPO_URL is empty and $APP_DIR is not populated. Set REPO_URL or place code in $APP_DIR."
    git clone "$REPO_URL" "$APP_DIR"
  fi
  chown -R "$NMS_USER:$NMS_GROUP" "$(dirname "$APP_DIR")"
}

setup_venv() {
  log "Creating venv at $VENV_DIR and installing deps"
  install -d -m 0755 "$(dirname "$VENV_DIR")"
  if [[ ! -d "$VENV_DIR" ]]; then
    sudo -u "$NMS_USER" python3 -m venv "$VENV_DIR"
  fi
  sudo -u "$NMS_USER" "$VENV_DIR/bin/pip" install --upgrade pip wheel setuptools

  if [[ -f "$APP_DIR/requirements.txt" ]]; then
    sudo -u "$NMS_USER" "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"
  elif [[ -f "$APP_DIR/pyproject.toml" ]]; then
    sudo -u "$NMS_USER" "$VENV_DIR/bin/pip" install -e "$APP_DIR"
  else
    die "No requirements.txt or pyproject.toml found in $APP_DIR"
  fi
}

setup_postgres_db() {
  log "Configuring Postgres DB/user"
  if [[ -z "$DB_PASS" ]]; then DB_PASS="$(rand_pw)"; fi

  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 \
    || sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"

  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 \
    || sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};" >/dev/null
}

write_config() {
  log "Writing /etc/nms config + initial credentials"
  install -d -m 0750 "$CONFIG_DIR"
  chown root:"$NMS_GROUP" "$CONFIG_DIR"

  if [[ -z "$ADMIN_PASS" ]]; then ADMIN_PASS="$(rand_pw)"; fi

  cat > "$CONFIG_FILE" <<EOF
database_url: "postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log_level: "info"
http:
  bind_host: "127.0.0.1"
  bind_port: 8000
EOF

  chmod 0640 "$CONFIG_FILE"
  chown root:"$NMS_GROUP" "$CONFIG_FILE"

  cat > "$CONFIG_DIR/initial-credentials.txt" <<EOF
NMS Initial Credentials
======================
URL: https://<server-ip>/
Username: ${ADMIN_USER}
Password: ${ADMIN_PASS}

Change this password immediately.
EOF
  chmod 0600 "$CONFIG_DIR/initial-credentials.txt"
  chown root:root "$CONFIG_DIR/initial-credentials.txt"
}

install_systemd_units() {
  log "Installing systemd units"
  cat > /etc/systemd/system/nms-api.service <<EOF
[Unit]
Description=NMS API (FastAPI)
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=${NMS_USER}
Group=${NMS_GROUP}
WorkingDirectory=${APP_DIR}
Environment=NMS_CONFIG=${CONFIG_FILE}
Environment=PYTHONUNBUFFERED=1
ExecStart=${VENV_DIR}/bin/uvicorn ${API_APP_IMPORT} --host 127.0.0.1 --port 8000
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/nms-worker@.service <<EOF
[Unit]
Description=NMS Worker (%i)
After=network-online.target postgresql.service nms-api.service
Wants=network-online.target

[Service]
User=${NMS_USER}
Group=${NMS_GROUP}
WorkingDirectory=${APP_DIR}
Environment=NMS_CONFIG=${CONFIG_FILE}
Environment=SERVICE_ROLE=%i
Environment=PYTHONUNBUFFERED=1
ExecStart=${VENV_DIR}/bin/python -m ${WORKER_MODULE}
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now nms-api.service

  IFS=',' read -r -a roles <<< "$WORKER_ROLES"
  for r in "${roles[@]}"; do
    r="$(echo "$r" | xargs)"
    [[ -z "$r" ]] && continue
    systemctl enable --now "nms-worker@${r}.service"
  done
}

run_migrations_and_admin() {
  log "Running migrations + ensuring admin (best-effort)"
  set +e
  sudo -u "$NMS_USER" env NMS_CONFIG="$CONFIG_FILE" bash -lc "cd '$APP_DIR' && ${VENV_DIR}/bin/${MIGRATE_CMD}"
  mig_rc=$?
  set -e
  if [[ $mig_rc -ne 0 ]]; then
    echo "WARN: MIGRATE_CMD failed (rc=$mig_rc). Update MIGRATE_CMD for your app." >&2
  fi

  local cmd="${ENSURE_ADMIN_CMD/__PASS__/$ADMIN_PASS}"
  set +e
  sudo -u "$NMS_USER" env NMS_CONFIG="$CONFIG_FILE" bash -lc "cd '$APP_DIR' && ${VENV_DIR}/bin/${cmd}"
  adm_rc=$?
  set -e
  if [[ $adm_rc -ne 0 ]]; then
    echo "WARN: ENSURE_ADMIN_CMD failed (rc=$adm_rc). Update ENSURE_ADMIN_CMD for your app." >&2
  fi
}

setup_caddy() {
  [[ "$ENABLE_CADDY" == "true" ]] || return 0
  log "Configuring Caddy reverse proxy"
  cat > "$CADDYFILE" <<'EOF'
{
  local_certs
}
:443 {
  reverse_proxy 127.0.0.1:8000
}
EOF
  systemctl enable --now caddy
  systemctl restart caddy
}

final_message() {
  log "Done"
  echo "UI: https://<server-ip>/"
  echo "Initial creds: $CONFIG_DIR/initial-credentials.txt"
  echo
  echo "Logs:"
  echo "  journalctl -u nms-api -f"
  echo "  journalctl -u nms-worker@poller -f"
}

main() {
  need_root
  validate_required_vars
  install_packages
  ensure_group_user
  clone_or_validate_repo
  setup_venv
  setup_postgres_db
  write_config
  install_systemd_units
  run_migrations_and_admin
  setup_caddy
  final_message
}
main "$@"
