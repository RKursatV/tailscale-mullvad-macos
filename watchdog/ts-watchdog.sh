#!/bin/zsh
# Tailscale + Mullvad boot-race watchdog. Runs every 30 s as a per-user LaunchAgent.
#
# Problem: at login, Tailscale's network extension starts before Mullvad has
# brought its tunnel up and picks the physical interface (e.g. en1) as its
# default route. Once Mullvad connects, its kill switch blocks everything that
# leaves outside the tunnel, and Tailscale never re-evaluates its default
# route. It sits in NoState ("You are logged out ... fetch control key ...
# no route to host") indefinitely. Relaunching the Tailscale app after Mullvad
# is connected fixes it: the new extension process picks Mullvad's utun as the
# default route.
#
# What this does: while Mullvad is Connected, if Tailscale looks stuck on two
# consecutive checks, quit and reopen the Tailscale app and bring it back up.
# It leaves Tailscale alone if you turned it off yourself (Stopped) or if you
# are genuinely logged out (NeedsLogin without a connection error).
#
# Manual use: ts-watchdog.sh --check   (print state and verdict, change nothing)
#             ts-watchdog.sh --force   (relaunch now, regardless of state)

TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
MV=/usr/local/bin/mullvad
[[ -x $MV ]] || MV="/Applications/Mullvad VPN.app/Contents/Resources/mullvad"
STATE_DIR="$HOME/Library/Application Support/tailscale-watchdog"
LOG="$HOME/Library/Logs/tailscale-watchdog.log"
COOLDOWN=300   # at least 5 minutes between relaunches

mkdir -p "$STATE_DIR"
# macOS has no timeout(1); use perl's alarm instead.
to() { local t=$1; shift; /usr/bin/perl -e 'alarm shift; exec @ARGV' "$t" "$@"; }
log() { print -r -- "$(date '+%F %T') $*" >> "$LOG"; }
ext_pid() { /usr/bin/pgrep -f 'io\.tailscale\.ipn\..*network-extension' | /usr/bin/head -1; }

ts_json() { to 10 "$TS" status --json 2>/dev/null; }
ts_field() {  # $1 = BackendState | stuck ; reads `tailscale status --json` on stdin
  /usr/bin/python3 -I -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print("unknown"); sys.exit()
st = d.get("BackendState") or "unknown"
if sys.argv[1] == "BackendState": print(st); sys.exit()
health = " ".join(d.get("Health") or [])
cut = ("no route to host" in health or "Unable to connect to the Tailscale coordination server" in health
       or "fetch control key" in health)
# stuck: NoState/Starting always; NeedsLogin only together with a connection error;
# Running but unable to reach the coordination server.
stuck = st in ("NoState", "Starting") or (st in ("NeedsLogin", "Running") and cut)
print("stuck" if stuck else "ok")
' "$1"
}
mullvad_connected() { "$MV" status 2>/dev/null | /usr/bin/head -1 | /usr/bin/grep -qE '^(Tunnel status: )?Connected'; }

relaunch() {
  log "relaunching Tailscale (reason: $1) ext_pid=$(ext_pid)"
  to 20 /usr/bin/osascript -e 'quit app "Tailscale"' >/dev/null 2>&1 || log "osascript quit failed (rc=$?)"
  for i in {1..15}; do /usr/bin/pgrep -xq Tailscale || break; sleep 1; done
  /usr/bin/pgrep -xq Tailscale && { /usr/bin/pkill -x Tailscale; sleep 2; }
  /usr/bin/open -a Tailscale
  local st=unknown
  for i in {1..30}; do
    sleep 2
    st=$(ts_json | ts_field BackendState)
    [[ $st == (Stopped|Running|NeedsLogin) ]] && break
  done
  if [[ $st == Stopped ]]; then   # quitting the app can leave WantRunning=false
    to 45 "$TS" up >/dev/null 2>&1
    sleep 3
    st=$(ts_json | ts_field BackendState)
  fi
  date +%s > "$STATE_DIR/last_relaunch"
  log "state after relaunch: $st ext_pid=$(ext_pid)"
}

case $1 in
  --force)    relaunch "manual --force"; exit 0 ;;
  --classify) ts_field stuck; exit 0 ;;   # classify a status JSON given on stdin (for testing)
  --check)
    j=$(ts_json)
    print -r -- "tailscale=$(print -r -- "$j" | ts_field BackendState) verdict=$(print -r -- "$j" | ts_field stuck) mullvad=$("$MV" status 2>/dev/null | /usr/bin/head -1)"
    exit 0 ;;
esac

# Relaunching is pointless until Mullvad's tunnel is up; wait for it.
mullvad_connected || { rm -f "$STATE_DIR/strikes"; exit 0; }

verdict=$(ts_json | ts_field stuck)
if [[ $verdict != stuck ]]; then rm -f "$STATE_DIR/strikes"; exit 0; fi

strikes=$(( $(cat "$STATE_DIR/strikes" 2>/dev/null || echo 0) + 1 ))
echo $strikes > "$STATE_DIR/strikes"
(( strikes < 2 )) && exit 0

last=$(cat "$STATE_DIR/last_relaunch" 2>/dev/null || echo 0)
(( $(date +%s) - last < COOLDOWN )) && exit 0

relaunch "Mullvad connected, Tailscale stuck ($(ts_json | ts_field BackendState))"
rm -f "$STATE_DIR/strikes"
