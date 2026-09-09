#!/usr/bin/env bash
# Removes jabra-teams-bridge from the current user account.
# Leaves the udev rule and the teams-for-linux patch alone: both are shared
# system state that other things may rely on. Remove them by hand if wanted.
set -euo pipefail

systemctl --user disable --now jabra-teams-bridge.service 2>/dev/null || true
rm -f "${HOME}/.config/systemd/user/jabra-teams-bridge.service"
rm -f "${HOME}/.local/bin/jabra-teams-bridge"
rm -f "${HOME}/.local/bin/tfl-patch-call-actions"
systemctl --user daemon-reload

echo "Removed. Left in place on purpose:"
echo "  /etc/udev/rules.d/70-jabra.rules"
echo "  the teams-for-linux patch (restore a backup in"
echo "  /opt/teams-for-linux/resources/app.asar.orig-* to revert)"
