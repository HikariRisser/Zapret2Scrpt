# Zapret2 Windows / Linux system controller

[Русская версия](README.ru.md) · [Security audit](SECURITY.md) · [License](LICENSE)

Controller for [`bol-van/zapret2`](https://github.com/bol-van/zapret2)
(release v1.0.6). It does two things:

1. **DPI bypass** for every application on the system: sites the ISP throttles
   or resets open directly, with no speed loss.
2. **A tunnel** for sites DPI bypass cannot help (the address is blocked
   outright, or the service refuses visitors from Russia): through Proton VPN
   Free or your own server. Only the sites you choose go into the tunnel.

| Platform | What to download | Bypass engine |
|---|---|---|
| Linux | [`zapret2-linux.sh`](zapret2-linux.sh) — a single file | `nfqws2` + nftables/iptables |
| Windows | [`Zapret2Windows.cmd`](Zapret2Windows.cmd) **or** [`Zapret2Windows.ps1`](Zapret2Windows.ps1) — either single file | `winws2` + WinDivert |

Script version: 1.8.0. **The console UI is in Russian.** The
[Russian README](README.ru.md) is the more detailed one.

## Quick start

### Linux

One file is needed, `zapret2-linux.sh`:

```bash
sh zapret2-linux.sh
```

The script finds Python 3.8+ (and offers to install it if missing), asks for
root and opens the menu. Then: **[5]** check requirements → **[1]** install →
**[2]** start the bypass.

The file is both a shell script and a Python program: `sh` runs the head, Python
runs the rest. Running it through `sh` needs no executable bit.

### Windows

One file is needed, either of the two (they are the same script):

- **`Zapret2Windows.cmd`** — double-click it.
- **`Zapret2Windows.ps1`** — right-click → "Run with PowerShell", or
  `powershell -ExecutionPolicy Bypass -File .\Zapret2Windows.ps1`.

The script asks for administrator rights itself. Then: **[5]** check
requirements → **[1]** install → **[2]** start the bypass.

The zapret2 build is downloaded from GitHub during installation.

## Main menu

The same on both systems.

| Item | Action |
|---|---|
| [1] | Install or update the zapret2 runtime |
| [2] | Start / stop the bypass |
| [3] | Autostart at logon: on / off |
| [4] | Resource diagnostics |
| [5] | Check requirements |
| [6] | Install missing dependencies |
| [7] | Refresh DNS over DoH |
| [8] | Learned domains and logs |
| [9] | Update the script |
| [10] | Remove from the system |
| [11] | Tunnel for sites zapret cannot open |
| [0] | Exit |

## How the bypass works

Interception is system-wide. There is no TLS MITM, no root certificate and no
browser setup.

Only the first packets of a connection go to `nfqws2`/`winws2` (Linux: 20
outgoing and 10 incoming TCP packets, 5 and 3 for UDP; Windows: outgoing TCP
80/443 and UDP 443 only). The rest of the traffic, video included, bypasses the
engine, so speed is unaffected.

| Traffic | What is applied |
|---|---|
| HTTP | `fake` + `multisplit` |
| TLS, listed domains | four strategies rotated per domain by the `circular` orchestrator: after two failures the domain moves to the next one |
| TLS, large hosting subnets | fake ClientHello with a whitelisted SNI against the cut-off after ~16 KB |
| QUIC | `fake` on `quic_initial` |
| Discord voice, STUN, WireGuard | `fake` on `discord_ip_discovery`, `stun`, WireGuard handshake |

The seed list has 86 domains; zapret2's autohostlist adds domains on which it
sees retransmissions or resets. Updating the runtime (item [1]) appends new seed
domains and keeps manual edits and learned domains.

## DNS over DoH

Item **[7]** resolves domains through DoH (Cloudflare, Google, Quad9) and writes
them to `hosts` in a marked block, removed on uninstall. Only domains for which
the system DNS returns a non-working address are pinned, and every candidate
address is verified with a connection to port 443 before it is written. Tunnel
domains are never pinned.

## Tunnel

Item **[11]**. A [sing-box](https://github.com/SagerNet/sing-box) tunnel
(v1.14.4, downloaded on first use) to an external server.

### Servers

- **Proton VPN Free**: import the WireGuard `.conf` created at
  account.protonvpn.com (Downloads → WireGuard configuration).
- **Your own server**: a link, a file path or a subscription URL.

| Format | Accepted |
|---|---|
| WireGuard | `.conf` file, `wireguard://` |
| VLESS | `vless://` — TCP, Reality, XTLS Vision, WebSocket, gRPC, HTTP, HTTPUpgrade, XHTTP |
| VMess | `vmess://` (base64 JSON and parameter form) |
| Trojan | `trojan://` |
| Shadowsocks | `ss://` (SIP002, legacy, 2022, obfs and v2ray-plugin) |
| Hysteria | `hysteria2://`, `hy2://`, `hysteria://` |
| TUIC, AnyTLS, SOCKS | `tuic://`, `anytls://`, `socks5://`, `socks4://` |
| Several servers | link list, subscription by `https://…` URL or base64 (first 40 are taken) |
| JSON | sing-box outbound/endpoint or config; Xray outbound or config |

AmneziaWG is not supported.

sing-box handles the TUN, DNS and almost every protocol. XHTTP links and Xray
configs run through [xray-core](https://github.com/XTLS/Xray-core), used as a
local proxy behind sing-box and downloaded only for such profiles. Every profile
is validated by its engine before it is saved.

### Design

- Only the FakeIP range (`10.249.0.0/16`) is routed into the TUN. Everything
  else bypasses sing-box and goes through zapret.
- DNS queries for tunnel-list domains are sent to sing-box (systemd-resolved
  routing domains on Linux, an NRPT rule on Windows) and get FakeIP addresses.
- zapret leaves tunnel-bound traffic and the connection to the server alone.
- TUN addresses, the FakeIP range and the routing table are non-default, so the
  tunnel coexists with other sing-box clients.

### Choosing a profile

- **Automatic** (tunnel menu [5]): every profile is probed for exit country,
  latency and a list of region-restricted sites (claude.ai, chatgpt.com,
  gemini.google.com by default, editable). Order: more sites open → foreign exit
  → lower latency.
- **Manual** (tunnel menu [4]): the chosen profile is pinned and automatic
  selection will not replace it.

### External list of region-restricted sites

Sites that refuse Russian visitors themselves (claude.ai, chatgpt.com, …) cannot
be detected by probing. When the tunnel is enabled, the script downloads the
GeoBlock list of [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains)
(about 500 domains) and routes them through the tunnel. The list is refreshed
every 24 hours (systemd timer `zapret2win-geolist.timer` on Linux, scheduled
task `Zapret2WindowsGeoList` on Windows) and whenever the tunnel starts with a
copy older than a day. It is kept in a separate file; your own tunnel list is
untouched. Tunnel menu [11] updates it now, [12] turns it off.

### Browsers and DNS

The tunnel relies on the system DNS. While it runs, Firefox is told to disable
its default-on DNS over HTTPS (canary domain `use-application-dns.net`); DoH
enabled by hand must be turned off in the browser. Tunnel-list domains stay
under zapret, which acts as a fallback when a request still goes direct.

### Autostart

An enabled tunnel starts in the background right after the bypass and stops
with it. Bypass autostart also starts the tunnel.

## Commands

Linux: `sh zapret2-linux.sh <action>`. Windows:
`powershell -ExecutionPolicy Bypass -File .\Zapret2Windows.ps1 -Action <action>`.

| Action | Linux | Windows |
|---|---|---|
| Install / update runtime | `install` | `Install` |
| Start / stop | `start` / `stop` | `Start` / `Stop` |
| Status | `status` | `Status` |
| Check requirements | `check` | `Check` |
| Install dependencies | `deps` | `Deps` |
| Refresh DoH | `doh` | `DohHosts` |
| Diagnostics | `diagnose` | `Diagnose` |
| Troubleshooting report | `report` | — |
| Update the script | `update` | `Update` |
| Remove | `uninstall` | `Uninstall`, `Purge` |
| Tunnel on / off | `tunnel-on` / `tunnel-off` | `TunnelOn` / `TunnelOff` |
| Add a server | `tunnel-import --config FILE` or `--link LINK` (`--proton`) | `TunnelImport -TunnelConfig FILE` or `-TunnelLink LINK` (`-Proton`) |
| Pick the best profile | `tunnel-select` | `TunnelSelect` |
| Pick a profile by hand | `tunnel-use --profile N\|name\|auto` | `TunnelUse -TunnelProfile N\|name\|auto` |
| Region check | `tunnel-geo` | `TunnelGeo` |
| Update the external list | `tunnel-geolist` | `TunnelGeoList` |
| Move failing sites to the tunnel | `tunnel-routes` | `TunnelRoutes` |
| Test tunnel sites | `tunnel-test` | `TunnelTest` |
| List profiles | `tunnel-list` | `TunnelList` |

## Requirements

**Linux:** a kernel with NFQUEUE; x86_64, aarch64, armv7, mips or riscv64;
Python 3.8+ (standard library only); root; nftables or iptables; systemd for
autostart and the tunnel; systemd-resolved for the tunnel.

**Windows:** Windows 10 or 11 x64; Windows PowerShell 5.1; .NET Framework 4.x
(installed automatically); administrator rights; the `.ps1` must stay UTF-8
with BOM. WinDivert is often flagged by antivirus software and conflicts with
Hyper-V, WSL2, VirtualBox and third-party VPN clients.

## Troubleshooting

- **Linux:** `sh zapret2-linux.sh report` writes a report to `/tmp` (no keys or
  passwords). Tunnel log: `journalctl -u zapret2win-tunnel`.
- **Windows:** the launcher keeps the window open on errors. `windivert: error
  opening filter: Access is denied` means missing rights or an antivirus block.
  Tunnel logs: `logs\sing-box*.log`.
- A tunnel site that does not open in the browser: restart the browser and turn
  off its DNS over HTTPS.

## Update and removal

Item **[9]** downloads the script from the `main` branch, compares versions,
makes a backup and checks the new file's syntax before replacing the old one.

Item **[10]** removes processes, autostart, the WinDivert driver service
(Windows), the runtime directory (`/opt/zapret2`,
`C:\Windows\System32\Zapret2Windows`) and the `hosts` block.

**Linux, upgrading from versions before 1.7.0:** the Linux version used to be
two files. Download the new `zapret2-linux.sh`; the old `zapret2-linux.py` can
be deleted. The `zapret2-linux.py` in this repository is a transitional stub
for the updater of old versions and need not be downloaded.

## Files

| | Linux (`/opt/zapret2/`) | Windows (`C:\Windows\System32\Zapret2Windows\`) |
|---|---|---|
| Bypass domains | `ipset/zapret-hosts-user.txt` | `lists\blocked.txt` |
| Learned domains | `ipset/zapret-hosts-auto.txt` | `lists\autohostlist.txt` |
| Exclusions | `ipset/zapret-hosts-user-exclude.txt` | `lists\exclude.txt` |
| Hosting subnets | `ipset/zapret2win-ip-hosting.txt` | `lists\ipset-hosting.txt` |
| Tunnel sites | `ipset/zapret2win-hosts-tunnel.txt` | `lists\tunnel.txt` |
| Tunnel sites, external list | `ipset/zapret2win-hosts-geoblock.txt` | `lists\tunnel-geoblock.txt` |
| Region-check sites | `ipset/zapret2win-geo-sites.txt` | `lists\tunnel-geo.txt` |
| Tunnel profiles and binaries | `tunnel/` | `tunnel\` |

## Security and limits

Runtime files live in a directory writable only by the administrator, because
the engines run Lua with elevated rights; see [SECURITY.md](SECURITY.md). On
Windows, move `Zapret2Windows.ps1` to a protected directory before enabling
autostart: the scheduled task runs it as SYSTEM.

- DPI bypass is not a VPN; blocked addresses and regional refusals need the
  tunnel.
- Proton VPN is blocked in Russia and may fail to connect; a DPI-resistant
  protocol on your own server (VLESS + Reality) is the fallback.
- Profile keys are stored in `tunnel/profiles.json` (mode 600 on Linux).

## Testing status

- **Linux, on a real machine (Ubuntu 26.10):** the bypass works; the tunnel
  starts with VLESS + Reality profiles; automatic profile selection runs.
- **Linux, in a test environment:** all server formats pass validation by real
  sing-box 1.14.4 and xray-core; the sing-box → xray-core → VLESS + XHTTP chain
  works on localhost; bypass parameters pass `nfqws2 --dry-run`; single-file
  launch through `sh`, `dash` and `bash`.
- **Not tested:** the reworked Windows version (tunnel, single-file launch,
  speed-ups) has never been run or even parsed by PowerShell;
  tunnel autostart at boot on Linux; region detection against real site
  responses; Firefox reacting to the DoH canary.

## Project layout

```
zapret2-linux.sh      Linux controller, single file (sh + Python)
zapret2-linux.py      transitional stub for updating from versions before 1.7.0
Zapret2Windows.ps1    Windows controller
Zapret2Windows.cmd    the same controller for double-click launch (built from the .ps1 by tools/build-cmd.py)
README.md / README.ru.md / SECURITY.md / LICENSE
tools/                optional Node.js diagnostics (probe-h2.js, probe-voice.js)
```

The zapret2 build, sing-box and xray-core are not stored in the repository;
they are downloaded from official releases.

## License

MIT — see [LICENSE](LICENSE). zapret2 is distributed under the MIT License,
Copyright (c) 2016-2026 bol-van.
