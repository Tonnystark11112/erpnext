#!/usr/bin/env bash
# Railway entrypoint for ERPNext + HRMS. Idempotent: safe to run on every boot.
set -euo pipefail

BENCH=/home/frappe/frappe-bench
SITES="$BENCH/sites"
DATA="${DATA_DIR:-/data}"            # Railway volume mount path
log() { echo "[entrypoint] $*"; }
bench_() { (cd "$BENCH" && runuser -u frappe -- bench "$@"); }

# ---------- 0. Required variables ----------
: "${SITE_NAME:?SITE_NAME is required}"
: "${DB_HOST:?DB_HOST is required}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required}"
: "${REDIS_CACHE:?REDIS_CACHE is required}"
: "${REDIS_QUEUE:?REDIS_QUEUE is required}"
export DB_PORT="${DB_PORT:-3306}"
export PORT="${PORT:-8080}"
export INSTALL_APPS="${INSTALL_APPS:-erpnext,hrms}"
export GUNICORN_WORKERS="${GUNICORN_WORKERS:-2}"
export GUNICORN_THREADS="${GUNICORN_THREADS:-4}"

if [ "$(id -u)" != "0" ]; then
  log "Container must start as root to fix volume ownership. Set RAILWAY_RUN_UID=0."; exit 1
fi

# Some images (e.g. a custom frappe_docker build) have user "frappe" but no group named "frappe".
# Create an alias group on the same gid so a group literally named "frappe" exists (nginx needs one).
if ! getent group frappe >/dev/null 2>&1; then
  log "No 'frappe' group found: creating an alias on gid $(id -g frappe)"
  groupadd -o -g "$(id -g frappe)" frappe
fi
# Make sure bench and the venv tools are found whatever the image's PATH is.
export PATH="/home/frappe/.local/bin:/home/frappe/frappe-bench/env/bin:$PATH"

# Always chown by numeric uid:gid, whatever the image calls the frappe user's group.
FOWN="$(id -u frappe):$(id -g frappe)"
FGRP="$(id -gn frappe)"
log "frappe user: uid:gid=$FOWN group=$FGRP"

# ---------- 1. Volume layout ----------
# Only the site folder lives on the volume. assets/ and apps.txt stay in the image,
# so they are always in sync with the code (no re-sync needed).
mkdir -p "$DATA/sites"
find "$DATA" ! -user frappe -exec chown "$FOWN" {} +

# ---------- 2. common_site_config.json (regenerated every boot from env) ----------
"$BENCH/env/bin/python" - <<'PY'
import json, os
path = "/home/frappe/frappe-bench/sites/common_site_config.json"
try:
    cfg = json.load(open(path))
except Exception:
    cfg = {}
cfg.update({
    "db_host": os.environ["DB_HOST"],
    "db_port": int(os.environ["DB_PORT"]),
    "redis_cache": os.environ["REDIS_CACHE"],
    "redis_queue": os.environ["REDIS_QUEUE"],
    "redis_socketio": os.environ["REDIS_QUEUE"],
    "socketio_port": 9000,
    "webserver_port": 8000,
    "default_site": os.environ["SITE_NAME"],
    "serve_default_site": True,
})
json.dump(cfg, open(path, "w"), indent=1)
PY
echo "$SITE_NAME" > "$SITES/currentsite.txt"
chown "$FOWN" "$SITES/common_site_config.json" "$SITES/currentsite.txt"

# ---------- 3. Wait for MariaDB and Redis (private network, may be IPv6) ----------
wait_for() {
  local host=$1 port=$2 name=$3
  for _ in $(seq 1 60); do
    if timeout 2 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then log "$name reachable"; return 0; fi
    sleep 3
  done
  log "$name not reachable at $host:$port"; exit 1
}
hostport() { local r=${1#redis://}; r=${r%%/*}; echo "${r%:*} ${r##*:}"; }
wait_for "$DB_HOST" "$DB_PORT" "MariaDB"
read -r rh rp < <(hostport "$REDIS_CACHE"); wait_for "$rh" "$rp" "redis-cache"
read -r rh rp < <(hostport "$REDIS_QUEUE"); wait_for "$rh" "$rp" "redis-queue"

# ---------- 4. Site: create on first boot, otherwise link + install/migrate ----------
SITE_ON_VOLUME="$DATA/sites/$SITE_NAME"
APPS=(${INSTALL_APPS//,/ })
CURRENT_VERSIONS="$(bench_ version 2>/dev/null | sort || true)"
STAMP="$DATA/.app_versions"

if [ -e "$SITES/$SITE_NAME" ] && [ ! -L "$SITES/$SITE_NAME" ]; then
  log "Unexpected real directory at $SITES/$SITE_NAME; refusing to continue."; exit 1
fi
rm -f "$SITES/$SITE_NAME"

if [ ! -f "$SITE_ON_VOLUME/site_config.json" ]; then
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required for first boot}"
  log "First boot: creating site $SITE_NAME with apps: ${APPS[*]}"
  install_args=(); for app in "${APPS[@]}"; do install_args+=(--install-app "$app"); done
  # No --force: if a previous attempt left a database behind, this fails instead of wiping it.
  bench_ new-site "$SITE_NAME" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username root --db-root-password "$DB_ROOT_PASSWORD" \
    --mariadb-user-host-login-scope='%' \
    --admin-password "$ADMIN_PASSWORD" \
    "${install_args[@]}"
  mkdir -p "$SITE_ON_VOLUME"
  cp -a "$SITES/$SITE_NAME/." "$SITE_ON_VOLUME/"
  rm -rf "$SITES/$SITE_NAME"
  chown -R "$FOWN" "$SITE_ON_VOLUME"
  ln -s "$SITE_ON_VOLUME" "$SITES/$SITE_NAME"
  bench_ --site "$SITE_NAME" set-config host_name "https://$SITE_NAME"
  bench_ --site "$SITE_NAME" enable-scheduler
  echo "$CURRENT_VERSIONS" > "$STAMP"
else
  ln -s "$SITE_ON_VOLUME" "$SITES/$SITE_NAME"
  installed="$(bench_ --site "$SITE_NAME" list-apps 2>/dev/null | awk '{print $1}')"
  for app in "${APPS[@]}"; do
    if ! grep -qx "$app" <<<"$installed"; then
      log "Installing missing app: $app"; bench_ --site "$SITE_NAME" install-app "$app"
    fi
  done
  if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$CURRENT_VERSIONS" ]; then
    log "App versions changed: running bench migrate"
    bench_ --site "$SITE_NAME" migrate
    echo "$CURRENT_VERSIONS" > "$STAMP"
  fi
fi
chown "$FOWN" "$STAMP"

# ---------- 4b. One-time restore from a backup in the transfer bucket ----------
# Runs only when RESTORE_ON_BOOT=1 and the marker file is absent. The marker is written
# only after a fully successful restore, so a failed attempt is retried on the next boot.
# Needs: TRANSFER_S3_* (bucket reference variables) and RESTORE_ENCRYPTION_KEY
# (the old site's encryption_key, set by hand in the Railway dashboard).
RESTORE_MARKER="$DATA/.restore_done"
if [ "${RESTORE_ON_BOOT:-0}" = "1" ] && [ ! -f "$RESTORE_MARKER" ]; then
  : "${RESTORE_ENCRYPTION_KEY:?RESTORE_ENCRYPTION_KEY is required when RESTORE_ON_BOOT=1}"
  : "${TRANSFER_S3_ENDPOINT:?TRANSFER_S3_ENDPOINT is required for restore}"
  : "${TRANSFER_S3_BUCKET:?TRANSFER_S3_BUCKET is required for restore}"
  : "${TRANSFER_S3_KEY:?TRANSFER_S3_KEY is required for restore}"
  : "${TRANSFER_S3_SECRET:?TRANSFER_S3_SECRET is required for restore}"

  RDIR=/tmp/restore
  rm -rf "$RDIR"; mkdir -p "$RDIR"
  log "Restore: downloading backup from bucket prefix '${RESTORE_PREFIX:-restore/}'"
  RDIR="$RDIR" "$BENCH/env/bin/python" - <<'PY'
import os, sys
import boto3
from botocore.config import Config

bucket = os.environ["TRANSFER_S3_BUCKET"]
prefix = os.environ.get("RESTORE_PREFIX", "restore/")
s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["TRANSFER_S3_ENDPOINT"],
    region_name=os.environ.get("TRANSFER_S3_REGION", "auto"),
    aws_access_key_id=os.environ["TRANSFER_S3_KEY"],
    aws_secret_access_key=os.environ["TRANSFER_S3_SECRET"],
    config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
)
resp = s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
keys = [o["Key"] for o in resp.get("Contents", []) if not o["Key"].endswith("/")]
if not keys:
    sys.exit(f"Restore: no objects found under {prefix} in the bucket")
for key in keys:
    dest = os.path.join(os.environ["RDIR"], os.path.basename(key))
    s3.download_file(bucket, key, dest)
    print(f"[entrypoint] Restore: downloaded {os.path.basename(key)}", flush=True)
PY
  chown -R "$FOWN" "$RDIR"

  SQL="$(ls "$RDIR"/*.sql.gz 2>/dev/null | head -1 || true)"
  PUB="$(ls "$RDIR"/*-files.tar 2>/dev/null | grep -v -- '-private-files.tar' | head -1 || true)"
  PRIV="$(ls "$RDIR"/*-private-files.tar 2>/dev/null | head -1 || true)"
  [ -n "$SQL" ] || { log "Restore: no .sql.gz database file found in the bucket"; exit 1; }
  restore_args=()
  [ -n "$PUB" ]  && restore_args+=(--with-public-files "$PUB")
  [ -n "$PRIV" ] && restore_args+=(--with-private-files "$PRIV")

  log "Restore: restoring database and files into $SITE_NAME"
  bench_ --site "$SITE_NAME" restore "$SQL" "${restore_args[@]}" \
    --db-root-username root --db-root-password "$DB_ROOT_PASSWORD" --force

  # Saved passwords and API secrets in the restored data are encrypted with the OLD site's key.
  bench_ --site "$SITE_NAME" set-config encryption_key "$RESTORE_ENCRYPTION_KEY"
  bench_ --site "$SITE_NAME" set-config host_name "https://$SITE_NAME"
  log "Restore: running bench migrate"
  bench_ --site "$SITE_NAME" migrate
  bench_ --site "$SITE_NAME" clear-cache
  bench_ --site "$SITE_NAME" enable-scheduler

  touch "$RESTORE_MARKER"; chown "$FOWN" "$RESTORE_MARKER"
  rm -rf "$RDIR"
  log "Restore: finished. Administrator now uses the password from the restored backup."
fi

# ---------- 5. MCP Agent role, user and API key ----------
if [ -n "${MCP_AGENT_API_KEY:-}" ] && [ -n "${MCP_AGENT_API_SECRET:-}" ]; then
  (cd "$SITES" && runuser -u frappe -- "$BENCH/env/bin/python" /opt/railway/provision_mcp_agent.py)
else
  log "MCP_AGENT_API_KEY/SECRET not set: skipping MCP Agent provisioning"
fi

# ---------- 6. nginx config, then hand over to supervisord ----------
sed -e "s|__PORT__|$PORT|g" -e "s|__SITE__|$SITE_NAME|g" -e "s|^user frappe;|user frappe ${FGRP};|" \
  /opt/railway/nginx.conf.template > /etc/nginx/frappe-railway.conf

log "Starting supervisord (nginx :$PORT, gunicorn, socketio, scheduler, worker)"
exec /usr/bin/supervisord -c /etc/supervisor/frappe-supervisord.conf
