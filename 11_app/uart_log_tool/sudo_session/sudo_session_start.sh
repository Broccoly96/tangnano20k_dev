#!/usr/bin/env bash
set -euo pipefail

PID_FILE="/tmp/tangmega60k_sudo_keepalive.pid"
INTERVAL_SEC="${SUDO_KEEPALIVE_INTERVAL_SEC:-60}"

if [[ -f "${PID_FILE}" ]]; then
  old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
    echo "sudo keepalive already running (pid=${old_pid})."
    exit 0
  fi
  rm -f "${PID_FILE}"
fi

echo "sudo authentication is required once to start session."
sudo -v

(
  while true; do
    sudo -n true || exit 0
    sleep "${INTERVAL_SEC}"
  done
) >/dev/null 2>&1 &

keepalive_pid="$!"
echo "${keepalive_pid}" > "${PID_FILE}"
chmod 600 "${PID_FILE}"

echo "sudo session started. keepalive pid=${keepalive_pid}, interval=${INTERVAL_SEC}s"
