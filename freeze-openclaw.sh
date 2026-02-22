#!/usr/bin/env bash
set -Eeuo pipefail

SERVER_IP="${SERVER_IP:-10.28.100.107}"
TS="$(date +%F-%H%M%S)"
BK="/var/backups/openclaw-freeze-${TS}"

mkdir -p "${BK}"

# 1) Ensure services start on boot
systemctl enable openclaw caddy

# 2) Backup critical files (including internal CA root)
cp -a /etc/systemd/system/openclaw.service "${BK}/" 2>/dev/null || true
cp -a /usr/local/bin/openclaw-gateway-start "${BK}/" 2>/dev/null || true
cp -a /etc/caddy/Caddyfile "${BK}/" 2>/dev/null || true
cp -a /home/openclaw/.openclaw "${BK}/openclaw-home" 2>/dev/null || true
cp -a /var/lib/caddy/.local/share/caddy/pki "${BK}/caddy-pki" 2>/dev/null || true

# 3) Record versions and runtime state
{
  echo "== versions =="
  date
  node -v || true
  npm -v || true
  openclaw --version || true
  caddy version || true
  echo
  echo "== systemctl =="
  systemctl is-enabled openclaw caddy || true
  systemctl is-active openclaw caddy || true
} > "${BK}/state.txt"

dpkg -l | egrep 'caddy|nodejs' > "${BK}/dpkg.txt" || true
npm ls -g --depth=0 > "${BK}/npm-global.txt" || true

# 4) Hold key packages to avoid accidental upgrades
apt-mark hold caddy nodejs || true

# 5) Pre-reboot health check
systemctl restart openclaw caddy

# Wait for gateway port to become ready to avoid transient 502 during restart.
MAX_WAIT="${MAX_WAIT:-30}"
ready=0
for i in $(seq 1 "${MAX_WAIT}"); do
  if ss -lnt | grep -Eq '(:18789[[:space:]])'; then
    ready=1
    break
  fi
  sleep 1
done

systemctl --no-pager --full status openclaw caddy | sed -n '1,20p'
ss -lntp | egrep ':443|:80|:18789' || true
if [[ "${ready}" -eq 0 ]]; then
  echo "[!] openclaw port 18789 did not become ready within ${MAX_WAIT}s"
fi

HTTP_CODE="000"
for i in $(seq 1 10); do
  HTTP_CODE="$(curl -k -sS -o /dev/null -w '%{http_code}' "https://${SERVER_IP}" || true)"
  if [[ "${HTTP_CODE}" != "000" && "${HTTP_CODE}" != "502" ]]; then
    break
  fi
  sleep 1
done
echo "HTTPS status: ${HTTP_CODE}"

echo
echo "Freeze done. Backup dir: ${BK}"
