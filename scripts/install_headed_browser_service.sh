#!/usr/bin/env bash
set -euo pipefail

WORKDIR="/home/gc/.openclaw/workspace"
SERVICE_NAME="${1:-openclaw-headed-browser.service}"
SERVICE_DIR="${HOME}/.config/systemd/user"
SERVICE_PATH="${SERVICE_DIR}/${SERVICE_NAME}"
LOG_PATH="${WORKDIR}/memory/backlink-runs/chrome.log"

CHROME_BIN="${CHROME_BIN:-}"
if [[ -z "${CHROME_BIN}" ]]; then
  CHROME_BIN="$(command -v google-chrome || command -v google-chrome-stable || true)"
fi

if [[ -z "${CHROME_BIN}" ]]; then
  echo "ERROR: google-chrome binary not found. Set CHROME_BIN manually." >&2
  exit 1
fi

mkdir -p "${SERVICE_DIR}" "${WORKDIR}/memory/backlink-runs"

cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=OpenClaw headed Chrome CDP (9222)
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
Environment=DISPLAY=:0
Environment=XAUTHORITY=%h/.Xauthority
ExecStartPre=-/usr/bin/pkill -f 'google-chrome.*remote-debugging-port=9222'
ExecStart=${CHROME_BIN} --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 --user-data-dir=${WORKDIR}/chrome_rdp_live --no-first-run --no-default-browser-check --disable-dev-shm-usage
Restart=always
RestartSec=3
StandardOutput=append:${LOG_PATH}
StandardError=append:${LOG_PATH}

[Install]
WantedBy=default.target
EOF

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

systemctl --user daemon-reload
systemctl --user enable --now "${SERVICE_NAME}"

echo "installed_and_started=${SERVICE_NAME}"
systemctl --user --no-pager --full status "${SERVICE_NAME}" | sed -n '1,20p'
