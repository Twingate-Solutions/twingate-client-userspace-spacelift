#!/usr/bin/env bash
set -euo pipefail

TWINGATE_PROXY_PORT="${TWINGATE_PROXY_PORT:-9999}"

# twingated reads TWINGATE_SERVICE_KEY from the environment natively — no file needed.
twingated --http-proxy "127.0.0.1:${TWINGATE_PROXY_PORT}" --tun off > /tmp/twingate.log 2>&1 &
sleep 12

# Verify the proxy is listening
if (echo > /dev/tcp/127.0.0.1/${TWINGATE_PROXY_PORT}) 2>/dev/null; then
  echo "twingate proxy online at 127.0.0.1:${TWINGATE_PROXY_PORT}"
else
  echo "ERROR: twingate proxy failed to start" >&2
  cat /tmp/twingate.log >&2
  exit 1
fi

# If TUNNEL_DEST is set, create a TCP tunnel through the proxy via proxytunnel.
if [[ -n "${TUNNEL_DEST:-}" ]]; then
  if [[ -z "${TUNNEL_LOCAL_PORT:-}" ]]; then
    echo "ERROR: TUNNEL_LOCAL_PORT is required when TUNNEL_DEST is set" >&2
    exit 1
  fi
  proxytunnel \
    --standalone="${TUNNEL_LOCAL_PORT}" \
    --proxy="127.0.0.1:${TWINGATE_PROXY_PORT}" \
    --dest="${TUNNEL_DEST}" \
    > /tmp/proxytunnel.log 2>&1 &
  sleep 3
  echo "tunnel: 0.0.0.0:${TUNNEL_LOCAL_PORT} -> ${TUNNEL_DEST}"
fi
