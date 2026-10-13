#!/bin/sh
# Connectivity check. No sudo needed. Run it once with Mullvad connected and once with it disconnected.
# Usage: ./check.sh <peer-name>     (a machine name from `tailscale status`)
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
MV=/usr/local/bin/mullvad; [ -x "$MV" ] || MV="/Applications/Mullvad VPN.app/Contents/Resources/mullvad"
PEER="${1:?usage: $0 <peer-name>}"
DOMAIN="$("$TS" status --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("MagicDNSSuffix") or "")' 2>/dev/null)"
NAME="$PEER.$DOMAIN"

echo "Mullvad:   $("$MV" status 2>/dev/null | head -1)"
echo "Tailscale: $("$TS" status --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState"))' 2>/dev/null)"
IP="$("$TS" ip -4 "$PEER" 2>/dev/null)"
printf 'ping %s (%s): ' "$PEER" "$IP"
ping -c 2 -t 4 "$IP" >/dev/null 2>&1 && echo OK || echo FAIL
printf 'MagicDNS @100.100.100.100 (%s): ' "$NAME"
r="$(dig +short +time=2 +tries=1 "$NAME" @100.100.100.100 2>/dev/null | grep -E '^[0-9.]+$' | head -1)"; [ -n "$r" ] && echo "OK ($r)" || echo FAIL
printf 'System resolver (%s): ' "$NAME"
r="$(dscacheutil -q host -a name "$NAME" 2>/dev/null | awk '/ip_address/{print $2; exit}')"; [ -n "$r" ] && echo "OK ($r)" || echo FAIL
printf 'Internet DNS (example.com): '
r="$(dig +short +time=3 +tries=1 example.com 2>/dev/null | grep -E '^[0-9.]+$' | head -1)"; [ -n "$r" ] && echo "OK ($r)" || echo FAIL
echo "tailscale ping:"; "$TS" ping -c 2 --timeout 5s "$PEER" 2>&1 | sed 's/^/  /'
