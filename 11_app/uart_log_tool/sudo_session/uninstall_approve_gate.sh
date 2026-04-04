#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

POLKIT_RULE_DIR="/etc/polkit-1/rules.d"
POLKIT_RULE_FILE="${POLKIT_RULE_DIR}/49-tangmega60k-approve-gate.rules"
PKLA_DIR="/etc/polkit-1/localauthority/50-local.d"
PKLA_FILE="${PKLA_DIR}/49-tangmega60k-approve-gate.pkla"

rm -f "${POLKIT_RULE_FILE}" "${PKLA_FILE}"

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart polkit 2>/dev/null || true
fi

echo "approve gate uninstalled"
