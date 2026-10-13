#!/bin/sh
# Installs the pf rules + MagicDNS resolver that let Tailscale work while Mullvad is connected.
#
# Usage: sudo ./install.sh [tailnet-domain]
#   tailnet-domain  e.g. tail1234.ts.net. Detected automatically from `tailscale status` if omitted.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0 $*"; exit 1; }

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
  DOMAIN="$("$TS" status --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("MagicDNSSuffix") or "")' 2>/dev/null || true)"
fi
case "$DOMAIN" in
  *.ts.net) ;;
  *) echo "Could not detect your tailnet domain (is Tailscale logged in?)."
     echo "Pass it explicitly, e.g.: sudo $0 tail1234.ts.net"
     exit 1 ;;
esac

# 1) pf rules
install -m 644 -o root -g wheel "$DIR/pf/tailscale.pf.conf" /etc/pf.anchors/tailscale
pfctl -a com.apple/tailscale -nf /etc/pf.anchors/tailscale 2>&1 | grep -v ALTQ || true
pfctl -a com.apple/tailscale -f /etc/pf.anchors/tailscale 2>&1 | grep -v ALTQ || true

# 2) MagicDNS: Mullvad takes over system DNS, so send *.<tailnet>.ts.net to Tailscale's resolver directly
mkdir -p /etc/resolver
printf '# managed by tailscale-mullvad-macos\nnameserver 100.100.100.100\n' > "/etc/resolver/$DOMAIN"
printf '%s\n' "$DOMAIN" > /etc/pf.anchors/tailscale.domain

# 3) Reload the rules at boot and every 5 minutes (safety net in case anything flushes the anchor)
install -m 644 -o root -g wheel "$DIR/pf/local.tailscale-pf.plist" /Library/LaunchDaemons/local.tailscale-pf.plist
launchctl bootout system/local.tailscale-pf 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.tailscale-pf.plist

echo
echo "== Anchor order in the main ruleset (com.apple/* must come BEFORE mullvad) =="
pfctl -sr 2>/dev/null | grep '^anchor' || true
echo
echo "== Rules in com.apple/tailscale =="
pfctl -a com.apple/tailscale -sr 2>/dev/null
echo
order="$(pfctl -sr 2>/dev/null | grep '^anchor' | grep -nE 'com\.apple|mullvad' | tr '\n' ' ')"
case "$order" in
  *mullvad*com.apple*) echo "WARNING: the mullvad anchor is evaluated before com.apple, the rules may have no effect: $order" ;;
  *) echo "Done (tailnet domain: $DOMAIN). Next: ./watchdog/install-watchdog.sh, then ./check.sh <peer-name>" ;;
esac
