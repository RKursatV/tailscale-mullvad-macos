#!/bin/zsh
# Installs the Tailscale watchdog as a LaunchAgent for the current user (no sudo needed).
# Usage: ./watchdog/install-watchdog.sh              install / reinstall
#        ./watchdog/install-watchdog.sh --uninstall  remove
set -e
D=${0:A:h}
L=local.tailscale-watchdog
P="$HOME/Library/LaunchAgents/$L.plist"

launchctl bootout gui/$(id -u)/$L 2>/dev/null || true
if [[ $1 == --uninstall ]]; then
  rm -f "$P"
  rm -rf "$HOME/Library/Application Support/tailscale-watchdog"
  echo "Watchdog removed. (Log kept at ~/Library/Logs/tailscale-watchdog.log)"
  exit 0
fi

chmod +x "$D/ts-watchdog.sh"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__DIR__|$D|" "$D/$L.plist" > "$P"
launchctl bootstrap gui/$(id -u) "$P"
echo "Watchdog installed: $P"
echo "It runs the script from $D, so keep this folder where it is."
zsh "$D/ts-watchdog.sh" --check
