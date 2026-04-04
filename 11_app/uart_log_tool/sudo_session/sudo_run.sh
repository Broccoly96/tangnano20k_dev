#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]] || [[ "$#" -lt 1 ]]; then
  cat <<'USAGE'
Usage:
  ./11_app/sudo_session/sudo_run.sh <command> [args...]

Behavior:
  - Runs command via `sudo -n` (non-interactive).
  - If no valid sudo session exists, exits 90 immediately.
  - This avoids hanging Codex flow on password prompt.
USAGE
  exit 2
fi

if ! sudo -n true >/dev/null 2>&1; then
  echo "SUDO_SESSION_REQUIRED: run ./11_app/sudo_session/sudo_session_start.sh" >&2
  exit 90
fi

exec sudo -n "$@"
