# Tailscale + Mullvad VPN on macOS

Run [Tailscale](https://tailscale.com) and the [Mullvad VPN](https://mullvad.net) app at the same time on a Mac. Your internet traffic stays inside Mullvad, and your tailnet keeps working.

Out of the box the two apps get in each other's way. This repo fixes three separate problems:

| Symptom | Cause | Fix |
|---|---|---|
| With Mullvad connected, tailnet peers time out (`ping 100.x.y.z` fails, SSH hangs) | Mullvad's kill switch (pf firewall) drops every packet that doesn't go through its tunnel, including Tailscale's | A pf anchor that allows only Tailscale's address ranges, evaluated before Mullvad's rules |
| MagicDNS names (`machine.tailXXXX.ts.net`) don't resolve while Mullvad is on | Mullvad takes over the system DNS configuration | A `/etc/resolver` entry that sends your tailnet domain to Tailscale's resolver (`100.100.100.100`) |
| **After every reboot**, Tailscale shows *"You are logged out"* / stays in `NoState`, with `fetch control key … no route to host`, until you quit and reopen it | A boot race (details below) | A small watchdog LaunchAgent that detects the stuck state and relaunches Tailscale once Mullvad is connected |

## The reboot problem, explained

At login, Tailscale's network extension starts a second or two **before** Mullvad has brought its tunnel up. At that moment the only route to the internet is the physical interface, so Tailscale picks it as its default route:

```
12:46:55 link state: interfaces.State{defaultRoute=en1 ifs={en1:[192.168.1.x/24]} v4=true v6=false}
12:46:55 control: doLogin(regen=false, hasUrl=false)
12:46:56 (mullvad-daemon) New tunnel state: Connected { ... tunnel_interface: Some("utun5") ... }
12:47:06 Received error: fetch control key: Get "https://controlplane.tailscale.com/key?v=148":
         dial tcp [2606:b740:49::111]:443: connect: no route to host
```

Then Mullvad connects. Its kill switch blocks everything that leaves outside the tunnel, and Tailscale is still sending through `en1`. Tailscale never re-evaluates its default route: in the logs this was observed for 12 hours, with hundreds of failed login attempts and every link-change event still reporting `defaultRoute=en1`. It does not recover on its own.

Quitting and reopening the Tailscale app *after* Mullvad is connected fixes it immediately. The new extension process sees `defaultRoute=utun5` (Mullvad's tunnel) and logs in within seconds. The watchdog automates exactly that.

## Install

```sh
git clone https://github.com/RKursatV/tailscale-mullvad-macos.git ~/tailscale-mullvad-macos
cd ~/tailscale-mullvad-macos

# 1) pf rules + MagicDNS resolver + a LaunchDaemon that reloads the rules (needs sudo).
#    Your tailnet domain is detected from `tailscale status`; you can also pass it: sudo ./install.sh tail1234.ts.net
sudo ./install.sh

# 2) The reboot watchdog (per-user LaunchAgent, no sudo).
./watchdog/install-watchdog.sh

# 3) Check: run once with Mullvad connected and once disconnected.
./check.sh <name-of-another-machine-in-your-tailnet>
```

The LaunchAgent runs the script from the folder you cloned into, so keep that folder where it is (or reinstall after moving it).

Expected `check.sh` output with Mullvad connected:

```
Mullvad:   Connected
Tailscale: Running
ping my-server (100.x.y.z): OK
MagicDNS @100.100.100.100 (my-server.tail1234.ts.net): OK (100.x.y.z)
System resolver (my-server.tail1234.ts.net): OK (100.x.y.z)
Internet DNS (example.com): OK (...)
tailscale ping:
  pong from my-server (100.x.y.z) ...
```

## How the watchdog works

`watchdog/ts-watchdog.sh` runs every 30 seconds (and at login):

1. If Mullvad isn't `Connected` yet, it does nothing. Relaunching before the tunnel is up would just reproduce the race.
2. It reads `tailscale status --json` and treats Tailscale as **stuck** if:
   - the state is `NoState` or `Starting`, or
   - the state is `Running` or `NeedsLogin` *and* the health messages show it can't reach the coordination server (`no route to host`, `fetch control key`, `Unable to connect to the Tailscale coordination server`).
3. After **two consecutive** stuck checks it quits the Tailscale app, reopens it and runs `tailscale up` if the app came back as `Stopped`. It waits at least 5 minutes between relaunches.

It never touches Tailscale if you turned it off yourself (`Stopped`) or if you are actually logged out (`NeedsLogin` with no connection error).

```sh
./watchdog/ts-watchdog.sh --check   # show current state and verdict, change nothing
./watchdog/ts-watchdog.sh --force   # relaunch Tailscale now
cat ~/Library/Logs/tailscale-watchdog.log   # every relaunch is logged here
```

A relaunch is logged like this (from a `--force` test run under launchd). Tailscale was back in 7 seconds with a fresh network-extension process:

```
2026-10-14 00:48:35 relaunching Tailscale (reason: manual --force) ext_pid=24912
2026-10-14 00:48:42 state after relaunch: Running ext_pid=29334
```

## What exactly gets changed

| Path | What | Installed by |
|---|---|---|
| `/etc/pf.anchors/tailscale` | pf rules: pass traffic to/from `100.64.0.0/10` and `fd7a:115c:a1e0::/48` (stateless) | `install.sh` |
| `com.apple/tailscale` pf anchor | where the rules are loaded. The stock `/etc/pf.conf` evaluates `com.apple/*` before Mullvad's anchor | `install.sh` |
| `/etc/resolver/<tailnet>.ts.net` | `nameserver 100.100.100.100` | `install.sh` |
| `/Library/LaunchDaemons/local.tailscale-pf.plist` | reloads the pf anchor at boot and every 5 minutes | `install.sh` |
| `~/Library/LaunchAgents/local.tailscale-watchdog.plist` | runs the watchdog every 30 s | `install-watchdog.sh` |

`/etc/pf.conf` is not modified. Only Tailscale's own address ranges bypass Mullvad's firewall; all other traffic, including Tailscale's connections to its coordination and DERP servers, still goes through Mullvad.

## Uninstall

```sh
./watchdog/install-watchdog.sh --uninstall
sudo ./uninstall.sh
```

## Notes and caveats

- **Tested with** macOS 26.6.2, Tailscale 1.104.1 (the standalone build from tailscale.com, with the system extension) and Mullvad VPN 2026.5. The App Store build of Tailscale uses the same CLI path and will probably work, but it hasn't been tested.
- A watchdog relaunch interrupts Tailscale for roughly 5–15 seconds. In practice it only happens right after login.
- The watchdog quits the app with AppleScript (`quit app "Tailscale"`). If macOS ever asks whether `osascript` may control Tailscale, allow it. If the AppleScript quit fails, the script falls back to `pkill`.
- Because Tailscale's underlay traffic runs inside Mullvad's tunnel, NAT traversal is harder and peers may connect through DERP relays instead of directly. That's usually fine, but expect somewhat higher latency.
- If you only need Mullvad as a privacy exit and not as a separate app, Tailscale's [Mullvad exit nodes](https://tailscale.com/docs/features/exit-nodes/mullvad-exit-nodes) add-on avoids running two VPN clients altogether.

This is an unofficial workaround and is not affiliated with Tailscale or Mullvad.

## License

[MIT](LICENSE)
