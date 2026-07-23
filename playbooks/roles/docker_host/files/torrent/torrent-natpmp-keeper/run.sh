#!/bin/sh
set -eu

GATEWAY="${GATEWAY:?set GATEWAY env}"
QBT_HOST="${QBT_HOST:-http://127.0.0.1:8080}"
QBT_USER="${QBT_USER:?set QBT_USER env}"
QBT_PASS="${QBT_PASS:?set QBT_PASS env}"

LIFETIME=60     # provider requires renew every ~60s
INTERVAL=45     # renew a bit before expiry
COOKIE="/tmp/qbt.cookies"
last_port=""

cleanup() { rm -f "$COOKIE" 2>/dev/null || true; }
trap cleanup INT TERM

login() {
  echo "[natpmp] Logging into qBittorrent @ ${QBT_HOST}"
  curl -sk -c "$COOKIE" \
    --data "username=${QBT_USER}&password=${QBT_PASS}" \
    "${QBT_HOST}/api/v2/auth/login" | grep -q "Ok."
}

set_listen_port() {
  port="$1"
  login || { sleep 2; login; }
  echo "[natpmp] Setting qBittorrent listen port -> ${port}"
  curl -sk -b "$COOKIE" \
    --data-urlencode "json={\"listen_port\":${port}}" \
    "${QBT_HOST}/api/v2/app/setPreferences" >/dev/null
}

while :; do
  date +%s > /tmp/natpmp-keeper.heartbeat
  echo "[natpmp] Renewing NAT-PMP mappings (lifetime=${LIFETIME}s) via gateway ${GATEWAY}"

  # Renew UDP mapping
  udp_out="$(natpmpc -g "$GATEWAY" -a 1 0 udp "$LIFETIME" 2>&1 || true)"
  [ "${DEBUG:-false}" = "true" ] && echo "$udp_out"
  echo "$udp_out" | grep -q "Mapped public port" || \
    echo "[natpmp] WARN: UDP renew failed" >&2

  # Renew TCP mapping
  tcp_out="$(natpmpc -g "$GATEWAY" -a 1 0 tcp "$LIFETIME" 2>&1 || true)"
  [ "${DEBUG:-false}" = "true" ] && echo "$tcp_out"

  # Extract mapped port
  port="$(printf '%s\n' "$tcp_out" | awk '/Mapped public port [0-9]+ protocol TCP/ {print $4; exit}')"

  if [ -z "${port:-}" ]; then
    echo "[natpmp] WARN: No TCP port parsed (gateway may not support NAT-PMP yet)" >&2
  elif [ "$port" != "$last_port" ]; then
    echo "[natpmp] Detected new mapped TCP port: ${port} (prev: ${last_port:-none})"
    set_listen_port "$port" && last_port="$port" || \
      echo "[natpmp] ERROR: Failed to update qBittorrent listen_port" >&2
  else
    echo "[natpmp] TCP port unchanged: ${port}"
  fi

  sleep "$INTERVAL"
done
