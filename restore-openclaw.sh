#!/usr/bin/env bash
set -Eeuo pipefail

SERVER_IP="${SERVER_IP:-10.28.100.107}"
BACKUP_DIR="${1:-${BACKUP_DIR:-}}"
TS="$(date +%F-%H%M%S)"
PREBK="/var/backups/openclaw-prerestore-${TS}"

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*"; }
die(){ echo "[-] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Please run as root: sudo bash $0 [backup_dir]"

if [[ -z "${BACKUP_DIR}" ]]; then
  BACKUP_DIR="$(ls -1dt /var/backups/openclaw-freeze-* 2>/dev/null | head -n1 || true)"
fi

[[ -n "${BACKUP_DIR}" ]] || die "No backup found under /var/backups/openclaw-freeze-*"
[[ -d "${BACKUP_DIR}" ]] || die "Backup directory does not exist: ${BACKUP_DIR}"

log "Using backup: ${BACKUP_DIR}"
mkdir -p "${PREBK}"

# 1) Snapshot current state before restore
log "Creating pre-restore snapshot: ${PREBK}"
cp -a /etc/systemd/system/openclaw.service "${PREBK}/" 2>/dev/null || true
cp -a /usr/local/bin/openclaw-gateway-start "${PREBK}/" 2>/dev/null || true
cp -a /etc/caddy/Caddyfile "${PREBK}/" 2>/dev/null || true
cp -a /home/openclaw/.openclaw "${PREBK}/openclaw-home" 2>/dev/null || true
cp -a /var/lib/caddy/.local/share/caddy/pki "${PREBK}/caddy-pki" 2>/dev/null || true

# 2) Stop services before file replacement
log "Stopping services"
systemctl stop openclaw caddy || true

# 3) Restore files
if [[ -f "${BACKUP_DIR}/openclaw.service" ]]; then
  cp -a "${BACKUP_DIR}/openclaw.service" /etc/systemd/system/openclaw.service
else
  warn "Missing ${BACKUP_DIR}/openclaw.service"
fi

if [[ -f "${BACKUP_DIR}/openclaw-gateway-start" ]]; then
  cp -a "${BACKUP_DIR}/openclaw-gateway-start" /usr/local/bin/openclaw-gateway-start
  chmod +x /usr/local/bin/openclaw-gateway-start
else
  warn "Missing ${BACKUP_DIR}/openclaw-gateway-start"
fi

if [[ -f "${BACKUP_DIR}/Caddyfile" ]]; then
  cp -a "${BACKUP_DIR}/Caddyfile" /etc/caddy/Caddyfile
else
  warn "Missing ${BACKUP_DIR}/Caddyfile"
fi

if [[ -d "${BACKUP_DIR}/openclaw-home" ]]; then
  rm -rf /home/openclaw/.openclaw
  cp -a "${BACKUP_DIR}/openclaw-home" /home/openclaw/.openclaw
  chown -R openclaw:openclaw /home/openclaw/.openclaw || true
else
  warn "Missing ${BACKUP_DIR}/openclaw-home"
fi

if [[ -d "${BACKUP_DIR}/caddy-pki" ]]; then
  rm -rf /var/lib/caddy/.local/share/caddy/pki
  mkdir -p /var/lib/caddy/.local/share/caddy
  cp -a "${BACKUP_DIR}/caddy-pki" /var/lib/caddy/.local/share/caddy/pki
  chown -R caddy:caddy /var/lib/caddy/.local/share/caddy/pki || true
else
  warn "Missing ${BACKUP_DIR}/caddy-pki"
fi

# 4) Bring services back
log "Reloading systemd and starting services"
systemctl daemon-reload
systemctl enable openclaw caddy
systemctl restart openclaw caddy

# 5) Verification
log "Health checks"
systemctl --no-pager --full status openclaw caddy | sed -n '1,24p'
ss -lntp | egrep ':443|:80|:18789' || true
curl -kI "https://${SERVER_IP}" || true

echo
echo "Restore done."
echo "Used backup: ${BACKUP_DIR}"
echo "Pre-restore snapshot: ${PREBK}"
