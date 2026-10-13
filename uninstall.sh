#!/bin/sh
# Reverts everything install.sh did. Usage: sudo ./uninstall.sh
# (The watchdog is removed separately: ./watchdog/install-watchdog.sh --uninstall)
set -u
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0"; exit 1; }
launchctl bootout system/local.tailscale-pf 2>/dev/null
rm -f /Library/LaunchDaemons/local.tailscale-pf.plist
pfctl -a com.apple/tailscale -F all 2>&1 | grep -v ALTQ
if [ -f /etc/pf.anchors/tailscale.domain ]; then
  f="/etc/resolver/$(cat /etc/pf.anchors/tailscale.domain)"
  grep -q 'managed by tailscale-mullvad-macos' "$f" 2>/dev/null && rm -f "$f"
fi
rm -f /etc/pf.anchors/tailscale /etc/pf.anchors/tailscale.domain
rmdir /etc/resolver 2>/dev/null
echo "Reverted."
