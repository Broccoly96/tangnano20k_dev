#!/usr/bin/env bash
set -euo pipefail

PID_FILE="/tmp/tangmega60k_sudo_keepalive.pid"

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" || true
    echo "stopped keepalive pid=${pid}"
  fi
  rm -f "${PID_FILE}"
fi

sudo -k || true
echo "sudo credential cache cleared."
