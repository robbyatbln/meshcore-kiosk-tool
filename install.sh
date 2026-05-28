#!/usr/bin/env bash
set -euo pipefail

TOOL_VERSION="0.2.0"
MESHCORE_REPO_URL="${MESHCORE_REPO_URL:-https://codeberg.org/mEDI/meshcore_chat.git}"
APP_NAME="meshcore-chat"
TIMER_NAME="meshcore-nightly-update"
STATE_DIR="/var/lib/meshcore-kiosk"
CONFIG_DIR="/etc/meshcore-kiosk"
PUSHOVER_ENV="$CONFIG_DIR/pushover.env"
BOOT_NOTIFY_SERVICE="meshcore-kiosk-boot-notify.service"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
ok() { printf '  OK: %s\n' "$*"; }
warn() { printf '  WARN: %s\n' "$*" >&2; }
fail() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "Run with sudo: sudo ./install.sh"
  fi
}

detect_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    APP_USER="$SUDO_USER"
  else
    APP_USER="${MESHCORE_USER:-$(logname 2>/dev/null || echo "${USER:-pi}")}"
  fi
  APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
  [ -n "$APP_HOME" ] || fail "Home directory for user '$APP_USER' not found"

  APP_DIR="${MESHCORE_APP_DIR:-$APP_HOME/meshcore_chat}"
  START_SCRIPT="$APP_HOME/start_meshcore_chat.sh"
  AUTOSTART_DIR="$APP_HOME/.config/autostart"
  DESKTOP_FILE="$AUTOSTART_DIR/$APP_NAME.desktop"
  LOG_FILE="$APP_HOME/meshcore_nightly_update.log"
}

run_as_user() {
  runuser -u "$APP_USER" -- bash -lc "$1"
}

install_packages() {
  log "Installing system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl python3 python3-venv python3-pip python3-serial
  ok "System packages installed"
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$CONFIG_DIR"
  chmod 755 "$STATE_DIR"
  chmod 700 "$CONFIG_DIR"
}

ensure_dialout() {
  log "Checking serial permissions"
  if id -nG "$APP_USER" | tr ' ' '\n' | grep -qx dialout; then
    ok "User '$APP_USER' is already in group dialout"
  else
    usermod -aG dialout "$APP_USER"
    warn "Added '$APP_USER' to dialout. A reboot is needed before the new group is fully active."
  fi
}

detect_meshcore_port() {
  log "Detecting MeshCore-capable serial device"

  if [ -n "${MESHCORE_AUTO_PORT:-}" ]; then
    AUTO_PORT="$MESHCORE_AUTO_PORT"
    AUTO_BAUD="${MESHCORE_AUTO_BAUD:-115200}"
    ok "Using configured port: $AUTO_PORT @ $AUTO_BAUD"
    return
  fi

  local detector
  detector="$(mktemp)"
  cat > "$detector" <<'PY'
import glob
import os
import sys

try:
    from serial.tools import list_ports
except Exception:
    list_ports = None

preferred_vidpids = {
    ("10c4", "ea60"),  # CP210x USB to UART Bridge
    ("1a86", "7523"),  # CH340
    ("0403", "6001"),  # FT232
    ("2e8a", "000a"),  # Raspberry Pi Pico CDC style
}
keywords = ("meshcore", "cp210", "ch340", "uart", "serial", "usb")

candidates = []
if list_ports:
    for port in list_ports.comports():
        device = port.device or ""
        if not device:
            continue
        vid = f"{port.vid:04x}" if port.vid is not None else ""
        pid = f"{port.pid:04x}" if port.pid is not None else ""
        desc = (port.description or "").lower()
        hwid = (port.hwid or "").lower()
        score = 0
        if device.startswith("/dev/ttyUSB"):
            score += 50
        if device.startswith("/dev/ttyACM"):
            score += 40
        if (vid, pid) in preferred_vidpids:
            score += 80
        if any(k in desc or k in hwid for k in keywords):
            score += 25
        if "bluetooth" in desc or "bluetooth" in hwid:
            score -= 100
        if score > 0:
            candidates.append((score, device, desc or hwid or "serial device", vid, pid))

if not candidates:
    for pattern in ("/dev/serial/by-id/*", "/dev/ttyUSB*", "/dev/ttyACM*"):
        for device in glob.glob(pattern):
            resolved = os.path.realpath(device)
            candidates.append((10, resolved, device, "", ""))

seen = set()
unique = []
for item in sorted(candidates, reverse=True):
    if item[1] not in seen:
        seen.add(item[1])
        unique.append(item)

if not unique:
    sys.exit(2)

score, device, desc, vid, pid = unique[0]
print(device)
print("115200")
print(f"{desc} VID={vid} PID={pid} score={score}", file=sys.stderr)
PY

  local output
  if output="$(python3 "$detector" 2>/tmp/meshcore-port-detect.log)"; then
    AUTO_PORT="$(printf '%s\n' "$output" | sed -n '1p')"
    AUTO_BAUD="$(printf '%s\n' "$output" | sed -n '2p')"
    ok "Detected: $AUTO_PORT @ $AUTO_BAUD"
    if [ -s /tmp/meshcore-port-detect.log ]; then
      sed 's/^/  Info: /' /tmp/meshcore-port-detect.log
    fi
  else
    warn "No matching serial device found. Falling back to /dev/ttyUSB0 @ 115200"
    warn "Override with: sudo MESHCORE_AUTO_PORT=/dev/ttyACM0 ./install.sh"
    AUTO_PORT="/dev/ttyUSB0"
    AUTO_BAUD="115200"
  fi
  rm -f "$detector"
}

install_or_update_app() {
  log "Installing/updating meshcore_chat"
  if [ -d "$APP_DIR/.git" ]; then
    run_as_user "cd '$APP_DIR' && git pull || true"
    ok "Repository updated or local changes preserved"
  elif [ -d "$APP_DIR" ]; then
    warn "$APP_DIR exists but is not a Git repository. Skipping clone."
  else
    run_as_user "cd '$APP_HOME' && git clone '$MESHCORE_REPO_URL' meshcore_chat"
    ok "Repository cloned"
  fi

  run_as_user "cd '$APP_DIR' && python3 -m venv .venv"
  if [ -f "$APP_DIR/requirements.txt" ]; then
    run_as_user "cd '$APP_DIR' && .venv/bin/python -m pip install --upgrade pip"
    run_as_user "cd '$APP_DIR' && .venv/bin/python -m pip install -r requirements.txt"
  else
    warn "requirements.txt not found"
  fi
}

write_patch_helper() {
  log "Installing patch helper"
  cat > /usr/local/bin/meshcore-kiosk-apply-patches <<'PY'
#!/usr/bin/env python3
from pathlib import Path
import os

app_dir = Path(os.environ.get("MESHCORE_APP_DIR", "/home/pi/meshcore_chat"))
main_path = app_dir / "main.py"
selector_path = app_dir / "meshcore_chat" / "device_selector.py"

def patch_main():
    if not main_path.exists():
        print(f"WARN: {main_path} missing")
        return
    text = main_path.read_text()
    if "showFullScreen()" in text:
        print("OK: fullscreen already active")
    elif ".show()" in text:
        main_path.write_text(text.replace(".show()", ".showFullScreen()", 1))
        print("OK: main.py changed to showFullScreen()")
    else:
        print("WARN: no .show() line found in main.py")

def ensure_once(text, old, new):
    if new in text:
        return text
    return text.replace(old, new)

def patch_selector():
    if not selector_path.exists():
        print(f"WARN: {selector_path} missing")
        return
    text = selector_path.read_text()
    if "MESHCORE_AUTO_PORT" in text and "def _maybe_auto_connect_serial" in text:
        print("OK: auto USB already active")
        return

    backup = selector_path.with_suffix(selector_path.suffix + ".kiosk-backup")
    if not backup.exists():
        backup.write_text(text)

    text = ensure_once(
        text,
        "import asyncio\nimport logging\nimport threading\n",
        "import asyncio\nimport logging\nimport os\nimport threading\n",
    )
    text = ensure_once(
        text,
        "from PyQt6.QtCore import Qt, pyqtSignal\n",
        "from PyQt6.QtCore import Qt, pyqtSignal, QTimer\n",
    )
    text = ensure_once(
        text,
        "        self._ble_devices = {}  # address -> BLEDevice\n"
        "        self._ble_scanning = False\n",
        "        self._ble_devices = {}  # address -> BLEDevice\n"
        "        self._ble_scanning = False\n"
        "        self.auto_serial_port = os.environ.get(\"MESHCORE_AUTO_PORT\", \"/dev/ttyUSB0\")\n"
        "        self.auto_baudrate = int(os.environ.get(\"MESHCORE_AUTO_BAUD\", \"115200\"))\n",
    )
    text = ensure_once(
        text,
        "        # BLE scan (asynchronous)\n"
        "        if BLEAK_AVAILABLE:\n",
        "        if self._maybe_auto_connect_serial():\n"
        "            return\n\n"
        "        # BLE scan (asynchronous)\n"
        "        if BLEAK_AVAILABLE:\n",
    )

    method = '''    def _maybe_auto_connect_serial(self):
        """Automatically select the configured serial port for kiosk startup."""
        if not self.auto_serial_port:
            return False

        for row in range(self.table.rowCount()):
            port_item = self.table.item(row, 0)
            type_item = self.table.item(row, 3)
            if (
                port_item
                and type_item
                and port_item.text() == self.auto_serial_port
                and type_item.text() == "Serial"
            ):
                self.table.selectRow(row)
                self.baud_combo.setCurrentText(str(self.auto_baudrate))
                self.selected_type = "serial"
                self.selected_port = self.auto_serial_port
                self.selected_baudrate = self.auto_baudrate
                self.selected_ble_address = None
                self.selected_ble_device = None
                self.connect_btn.setEnabled(True)
                logger.info(
                    "Auto-selecting serial device %s @ %s",
                    self.auto_serial_port,
                    self.auto_baudrate,
                )
                QTimer.singleShot(250, self.accept)
                return True

        logger.warning("Auto serial port %s not found", self.auto_serial_port)
        return False

'''
    if "def _maybe_auto_connect_serial" not in text:
        marker = "    def _scan_ble_thread(self):\n"
        if marker in text:
            text = text.replace(marker, method + marker)
        else:
            print("WARN: auto USB insertion point not found")

    selector_path.write_text(text)
    print("OK: auto USB patch applied")

patch_main()
patch_selector()
PY
  chmod +x /usr/local/bin/meshcore-kiosk-apply-patches
  ok "Patch helper installed"
}

apply_patches() {
  log "Applying kiosk patches"
  run_as_user "cd '$APP_DIR' && MESHCORE_APP_DIR='$APP_DIR' /usr/local/bin/meshcore-kiosk-apply-patches"
}

write_start_script() {
  log "Configuring GUI autostart"
  cat > "$START_SCRIPT" <<EOF
#!/usr/bin/env bash
cd "$APP_DIR" || exit 1

LOCK_DIR="/tmp/meshcore-chat.lock"
if ! mkdir "\$LOCK_DIR" 2>/dev/null; then
  echo "Meshcore Chat is already running or a stale lock exists: \$LOCK_DIR"
  exit 0
fi
trap 'rmdir "\$LOCK_DIR" 2>/dev/null || true' EXIT

export MESHCORE_AUTO_PORT="$AUTO_PORT"
export MESHCORE_AUTO_BAUD="$AUTO_BAUD"
"$APP_DIR/.venv/bin/python" "$APP_DIR/main.py"
EOF
  chmod +x "$START_SCRIPT"
  chown "$APP_USER:$APP_USER" "$START_SCRIPT"

  run_as_user "mkdir -p '$AUTOSTART_DIR'"
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Meshcore Chat
Exec=$START_SCRIPT
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
  chown "$APP_USER:$APP_USER" "$DESKTOP_FILE"
  ok "GUI autostart installed"
}

cleanup_duplicate_launchers() {
  log "Checking for duplicate launchers"

  run_as_user "systemctl --user disable --now meshcore-chat.service >/dev/null 2>&1 || true"

  if [ -d "$AUTOSTART_DIR" ]; then
    while IFS= read -r file; do
      [ "$file" = "$DESKTOP_FILE" ] && continue
      if grep -Eiq "meshcore_chat/main.py|start_meshcore_chat.sh|meshcore-chat|Meshcore Chat" "$file"; then
        local disabled
        disabled="$file.disabled-by-meshcore-kiosk"
        if [ ! -e "$disabled" ]; then
          mv "$file" "$disabled"
          chown "$APP_USER:$APP_USER" "$disabled"
          ok "Disabled duplicate autostart: $file"
        else
          rm -f "$file"
          ok "Removed duplicate autostart already disabled before: $file"
        fi
      fi
    done < <(find "$AUTOSTART_DIR" -maxdepth 1 -type f -name "*.desktop")
  fi

  ok "Duplicate launcher check complete"
}

write_pushover_config() {
  log "Configuring optional Pushover"
  if [ -n "${PUSHOVER_APP_TOKEN:-}" ] && [ -n "${PUSHOVER_USER_KEY:-}" ]; then
    cat > "$PUSHOVER_ENV" <<EOF
PUSHOVER_APP_TOKEN="$PUSHOVER_APP_TOKEN"
PUSHOVER_USER_KEY="$PUSHOVER_USER_KEY"
PUSHOVER_DEVICE="${PUSHOVER_DEVICE:-}"
EOF
    chmod 600 "$PUSHOVER_ENV"
    ok "Pushover configured"
  elif [ -f "$PUSHOVER_ENV" ]; then
    ok "Existing Pushover config kept"
  else
    warn "Pushover not configured. Install with PUSHOVER_APP_TOKEN=... PUSHOVER_USER_KEY=... to enable it."
  fi
}

write_pushover_tools() {
  log "Installing Pushover boot notification tools"

  cat > /usr/local/bin/meshcore-kiosk-send-pushover <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG="/etc/meshcore-kiosk/pushover.env"
[ -f "$CONFIG" ] || exit 0
# shellcheck disable=SC1090
. "$CONFIG"

[ -n "${PUSHOVER_APP_TOKEN:-}" ] || exit 0
[ -n "${PUSHOVER_USER_KEY:-}" ] || exit 0

TITLE="${1:-Meshcore Kiosk}"
MESSAGE="${2:-Meshcore kiosk notification}"
DEVICE_ARGS=()
if [ -n "${PUSHOVER_DEVICE:-}" ]; then
  DEVICE_ARGS=(-F "device=$PUSHOVER_DEVICE")
fi

curl -fsS \
  -F "token=$PUSHOVER_APP_TOKEN" \
  -F "user=$PUSHOVER_USER_KEY" \
  -F "title=$TITLE" \
  -F "message=$MESSAGE" \
  "${DEVICE_ARGS[@]}" \
  https://api.pushover.net/1/messages.json >/dev/null
EOF
  chmod +x /usr/local/bin/meshcore-kiosk-send-pushover

  cat > /usr/local/bin/meshcore-kiosk-boot-notify <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/meshcore-kiosk/pending-reboot-notify"
[ -f "$MARKER" ] || exit 0

HOST="$(hostname)"
DETAIL="$(cat "$MARKER" 2>/dev/null || true)"
MESSAGE="Meshcore kiosk on $HOST rebooted successfully after nightly update."
if [ -n "$DETAIL" ]; then
  MESSAGE="$MESSAGE $DETAIL"
fi

if /usr/local/bin/meshcore-kiosk-send-pushover "Meshcore update OK" "$MESSAGE"; then
  rm -f "$MARKER"
fi
EOF
  chmod +x /usr/local/bin/meshcore-kiosk-boot-notify

  cat > "/etc/systemd/system/$BOOT_NOTIFY_SERVICE" <<EOF
[Unit]
Description=Send Meshcore kiosk update notification after successful boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/meshcore-kiosk-boot-notify

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable "$BOOT_NOTIFY_SERVICE"
  ok "Boot notification installed"
}

write_nightly_update() {
  log "Configuring nightly update timer"
  cat > /usr/local/bin/meshcore-kiosk-nightly-update <<EOF
#!/usr/bin/env bash
set -euo pipefail

APP_USER="$APP_USER"
APP_DIR="$APP_DIR"
LOG_FILE="$LOG_FILE"
STATE_DIR="$STATE_DIR"

exec >> "\$LOG_FILE" 2>&1

echo
echo "========================================"
echo "Meshcore Nightly Update: \$(date)"
echo "========================================"

run_as_user() {
  runuser -u "\$APP_USER" -- bash -lc "\$1"
}

echo "[1/7] Stop running Meshcore..."
pkill -f "\$APP_DIR/main.py" || true
sleep 3

echo "[2/7] Stash local kiosk files..."
run_as_user "cd '\$APP_DIR' && git stash push -m 'auto kiosk changes before nightly update' main.py meshcore_chat/device_selector.py || true"

echo "[3/7] git pull..."
run_as_user "cd '\$APP_DIR' && git pull"

echo "[4/7] Update requirements..."
if [ -f "\$APP_DIR/requirements.txt" ]; then
  run_as_user "cd '\$APP_DIR' && .venv/bin/python -m pip install -r requirements.txt"
fi

echo "[5/7] Re-apply kiosk patches..."
run_as_user "cd '\$APP_DIR' && MESHCORE_APP_DIR='\$APP_DIR' /usr/local/bin/meshcore-kiosk-apply-patches"

echo "[6/7] Prepare reboot success notification..."
mkdir -p "\$STATE_DIR"
printf 'Updated at %s. Commit: ' "\$(date -Is)" > "\$STATE_DIR/pending-reboot-notify"
run_as_user "cd '\$APP_DIR' && git rev-parse --short HEAD" >> "\$STATE_DIR/pending-reboot-notify" || true

echo "[7/7] Reboot..."
sync
sleep 10
systemctl reboot
EOF
  chmod +x /usr/local/bin/meshcore-kiosk-nightly-update

  cat > "/etc/systemd/system/$TIMER_NAME.service" <<EOF
[Unit]
Description=Meshcore nightly git update and reboot

[Service]
Type=oneshot
ExecStart=/usr/local/bin/meshcore-kiosk-nightly-update
EOF

  cat > "/etc/systemd/system/$TIMER_NAME.timer" <<EOF
[Unit]
Description=Run Meshcore nightly update every day at midnight

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true
Unit=$TIMER_NAME.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable "$TIMER_NAME.timer"
  systemctl start "$TIMER_NAME.timer"
  ok "Nightly timer enabled"
}

send_install_success_notification() {
  log "Sending optional install confirmation"
  if [ ! -f "$PUSHOVER_ENV" ]; then
    warn "Pushover not configured; skipping install confirmation"
    return
  fi

  local host timer_state message
  host="$(hostname)"
  timer_state="$(systemctl is-enabled "$TIMER_NAME.timer" 2>/dev/null || echo unknown)"
  message="Meshcore kiosk installation completed on $host. User: $APP_USER. App: $APP_DIR. Port: $AUTO_PORT @ $AUTO_BAUD. Nightly timer: $timer_state."

  if /usr/local/bin/meshcore-kiosk-send-pushover "Meshcore install OK" "$message"; then
    ok "Install confirmation sent via Pushover"
  else
    warn "Pushover install confirmation failed"
  fi
}

print_summary() {
  log "Done"
  cat <<EOF
Version:       $TOOL_VERSION
User:          $APP_USER
App dir:       $APP_DIR
USB port:      $AUTO_PORT
Baudrate:      $AUTO_BAUD
Start script:  $START_SCRIPT
Autostart:     $DESKTOP_FILE
Nightly log:   $LOG_FILE
Pushover:      $([ -f "$PUSHOVER_ENV" ] && echo "enabled" || echo "disabled")

Test now:
  $START_SCRIPT

Check timer:
  systemctl list-timers | grep meshcore

Read update log:
  cat $LOG_FILE

Manual nightly test, including reboot:
  sudo systemctl start $TIMER_NAME.service

Then reboot:
  sudo reboot

Autologin still needs to be enabled in the desktop login settings:
  Raspberry Pi OS: sudo raspi-config
  Linux Mint: Login Window / Anmeldefenster
EOF
}

main() {
  require_root
  detect_user
  log "Meshcore Kiosk Installer $TOOL_VERSION"
  ok "Target user: $APP_USER"
  ensure_dirs
  install_packages
  ensure_dialout
  detect_meshcore_port
  install_or_update_app
  write_patch_helper
  apply_patches
  write_start_script
  cleanup_duplicate_launchers
  write_pushover_config
  write_pushover_tools
  write_nightly_update
  send_install_success_notification
  print_summary
}

main "$@"
