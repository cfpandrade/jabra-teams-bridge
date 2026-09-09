#!/usr/bin/env bash
# Installs jabra-teams-bridge and everything it depends on.
#
# Every step that touches the system asks first. Pass --yes to accept all of
# them, for unattended installs.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
UNIT_DIR="${HOME}/.config/systemd/user"
UDEV_RULE="/etc/udev/rules.d/70-jabra.rules"
TFL_CONFIG="${HOME}/.config/teams-for-linux/config.json"
UNIT="jabra-teams-bridge.service"

ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }

ask() {
    # ask "question" -> 0 if accepted
    [ "$ASSUME_YES" = 1 ] && { echo "$1 -> yes (--yes)"; return 0; }
    local reply
    read -r -p "$1 [y/N] " reply </dev/tty || return 1
    [[ "$reply" =~ ^[YySs] ]]
}

# ---------------------------------------------------------------- dependencies
say "1. Dependencies"
missing=()
command -v python3        >/dev/null || missing+=(python3)
command -v mosquitto_pub  >/dev/null || missing+=(mosquitto-clients)
command -v mosquitto      >/dev/null || missing+=(mosquitto)
command -v npx            >/dev/null || missing+=(npm)

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing: ${missing[*]}"
    if command -v apt >/dev/null && ask "Install them with apt?"; then
        sudo apt update && sudo apt install -y "${missing[@]}"
    else
        echo "Install them yourself and run this again."
        exit 1
    fi
else
    echo "All present."
fi

# npx is only needed by the teams-for-linux patcher, which fetches
# @electron/asar on first use. Warn rather than fail if there is no network.
command -v npx >/dev/null || warn "npx missing: tfl-patch-call-actions will not work."

# -------------------------------------------------------------------- broker
say "2. MQTT broker"
if systemctl is-active --quiet mosquitto; then
    echo "mosquitto is running."
elif ask "Enable and start the mosquitto broker?"; then
    sudo systemctl enable --now mosquitto
else
    warn "Without a broker on localhost:1883 nothing will work."
fi

# ---------------------------------------------------------------------- files
say "3. Files"
mkdir -p "$BIN_DIR" "$UNIT_DIR"
install -m 755 "$SRC/jabra-teams-bridge"            "$BIN_DIR/jabra-teams-bridge"
install -m 755 "$SRC/tools/tfl-patch-call-actions"  "$BIN_DIR/tfl-patch-call-actions"
install -m 644 "$SRC/systemd/$UNIT"                 "$UNIT_DIR/$UNIT"
echo "Installed into $BIN_DIR and $UNIT_DIR."

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH." ;;
esac

# ----------------------------------------------------------------------- udev
say "4. Device access"
# The daemon reads raw HID reports, so it needs access to the Jabra hidraw
# node. uaccess grants it to the active session by ACL, which is why the rule
# does not use MODE="0666": that would expose the headset to every local
# process, microphone stream included.
if [ -f "$UDEV_RULE" ]; then
    echo "Kept the existing rule at $UDEV_RULE."
elif ask "Install the udev rule for Jabra hidraw access (needs sudo)?"; then
    sudo install -m 644 "$SRC/udev/70-jabra.rules" "$UDEV_RULE"
    sudo udevadm control --reload
    sudo udevadm trigger --subsystem-match=hidraw
    echo "Installed. Replug the dongle if it was already connected."
else
    warn "Without it the daemon cannot open the headset."
fi

# --------------------------------------------------------- teams-for-linux cfg
say "5. teams-for-linux MQTT"
if [ ! -d "$(dirname "$TFL_CONFIG")" ]; then
    warn "teams-for-linux config directory not found; is it installed?"
elif python3 - "$TFL_CONFIG" <<'PY' 2>/dev/null
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
c = json.loads(p.read_text()) if p.exists() else {}
sys.exit(0 if c.get("mqtt", {}).get("enabled") else 1)
PY
then
    echo "MQTT already enabled."
elif ask "Enable MQTT in $TFL_CONFIG?"; then
    python3 - "$TFL_CONFIG" <<'PY'
import json, pathlib, shutil, sys
p = pathlib.Path(sys.argv[1])
cfg = {}
if p.exists():
    shutil.copy2(p, str(p) + ".bak")
    try:
        cfg = json.loads(p.read_text())
    except json.JSONDecodeError:
        print("  existing config is not valid JSON; kept a .bak and starting fresh")
mqtt = cfg.setdefault("mqtt", {})
mqtt.setdefault("brokerUrl", "mqtt://localhost:1883")
mqtt.setdefault("clientId", "teams-for-linux")
mqtt.setdefault("topicPrefix", "teams")
mqtt["enabled"] = True
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(cfg, indent=2) + "\n")
print(f"  wrote {p}")
PY
fi

# ------------------------------------------------------------- teams-for-linux
say "6. Patch teams-for-linux"
# Two patches, both required: the MQTT action whitelist has no way to hang up a
# call, and sendInputEvent does not grant focus, so commands are ignored unless
# the window is in the foreground.
if [ ! -f /opt/teams-for-linux/resources/app.asar ]; then
    warn "teams-for-linux not found at /opt; skipping. Run tfl-patch-call-actions later."
elif grep -aq 'TFL_PATCH_FOCUS' /opt/teams-for-linux/resources/app.asar; then
    echo "Already patched."
elif ask "Patch it now (needs sudo, keeps a timestamped backup)?"; then
    "$BIN_DIR/tfl-patch-call-actions"
    NEEDS_TEAMS_RESTART=1
else
    warn "Without the patch the call button cannot work and mute only works"
    warn "while the Teams window has focus."
fi

# ----------------------------------------------------------- restart the app
if [ "${NEEDS_TEAMS_RESTART:-0}" = 1 ]; then
    say "7. Restart teams-for-linux"
    TEAMS_PID=$(pgrep -f '/opt/teams-for-linux/teams-for-linux --' | head -1 || true)
    if [ -z "$TEAMS_PID" ]; then
        echo "Not running; it will pick up the patch on next start."
    else
        # Relaunch with the exact same argv, so custom flags survive.
        mapfile -d '' TEAMS_ARGV < "/proc/$TEAMS_PID/cmdline"
        echo "Running as: ${TEAMS_ARGV[*]}"
        warn "Restarting drops any call you are in."
        if ask "Restart it now?"; then
            pkill -f '/opt/teams-for-linux/teams-for-linux' || true
            sleep 3
            setsid "${TEAMS_ARGV[@]}" >/dev/null 2>&1 </dev/null &
            echo "Relaunched."
        else
            echo "Restart it yourself so the patch takes effect."
        fi
    fi
fi

# -------------------------------------------------------------------- service
say "8. Service"
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT"
sleep 1
systemctl --user --no-pager --lines=0 status "$UNIT" || true

say "Done"
cat <<'TXT'
Check it is seeing the headset:
  journalctl --user -u jabra-teams-bridge -f

Then join a call and move the boom arm. Teams takes 1-3 seconds to apply a
mute, so do not judge it sooner than that.

If mute ends up inverted (arm up shows unmuted), click Teams' own microphone
button once without touching the arm. Moving the arm cannot fix it: each pulse
flips the arm and Teams together.

Reapply the patch after every teams-for-linux upgrade:
  tfl-patch-call-actions
TXT
