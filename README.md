# Zapret2 Windows / Linux system controller

[Russian version](README.ru.md) · [Security audit](SECURITY.md) · [License](LICENSE)

Controller for `bol-van/zapret2` (release v1.0.6): system-wide DPI desync for
all applications, DoH-based DNS bypass, domain auto-learning and complete
removal from the system.

Two implementations with the same feature set:

| Platform | File | Interception engine |
|---|---|---|
| Windows | [`Zapret2Windows.ps1`](Zapret2Windows.ps1) | `winws2` + WinDivert |
| Linux | [`zapret2-linux.py`](zapret2-linux.py) | `nfqws2` + nftables/iptables |

**Both console UIs are in Russian.**

## Linux version

```bash
sudo python3 zapret2-linux.py            # interactive menu
sudo python3 zapret2-linux.py -a install # install runtime
python3 zapret2-linux.py -a check        # check requirements
python3 zapret2-linux.py --help
```

The menu is the same as on Windows (10 items, with start/autostart toggles).

### Linux requirements

| Requirement | Value | Why |
|---|---|---|
| **OS** | Linux, kernel with NFQUEUE | interception goes through `nfqws2` |
| **Architecture** | x86_64, aarch64, armv7, mips, riscv64 | prebuilt zapret2 binary is used |
| **Python** | 3.8+ | script is Python, no third-party packages |
| **Privileges** | root (via `sudo`) | firewall rules, `/opt`, `/etc/hosts`, systemd |
| **Firewall** | `nftables` (preferred) or `iptables` | redirect to NFQUEUE |
| **Kernel module** | `nfnetlink_queue` | loaded automatically |
| **systemd** | for autostart (optional) | `zapret2win` service |
| **Internet** | first install only | zapret2 release (~9.5 MB) from GitHub |

Check everything at once: `python3 zapret2-linux.py -a check` or item **[5]**.

### Differences from the Windows version

| | Windows | Linux |
|---|---|---|
| Interception | WinDivert (kernel driver) | NFQUEUE (`nfqws2` + nftables) |
| Engine | `winws2` directly | zapret2 init script (`/opt/zapret2/init.d/sysv/zapret2`) |
| Location | `System32\Zapret2Windows` | `/opt/zapret2` (root-owned) |
| Autostart | scheduled task (SYSTEM) | systemd service |
| Domain lists | `lists\*.txt` | `/opt/zapret2/ipset/zapret-hosts-*.txt` |
| DNS flush | `ipconfig /flushdns` | `resolvectl flush-caches` / `nscd -i hosts` |

Strategy logic, profiles (HTTP, TLS, QUIC, Discord voice), DoH with working-IP
verification, script self-update and uninstall are identical to Windows.

### Archive permissions caveat

Python's `zipfile` does **not** restore Unix permissions from the archive, so
the installer explicitly marks all `*.sh`, `nfqws2`, `mdig`, `ip2net` and
`init.d/sysv/zapret2` as executable. Without that the init script will not run.

### Testing status of the Linux version

Development happened on Windows, so, honestly:

**Verified locally (Python 3.12):**
- syntax (`py_compile`) — clean;
- version comparison and `VERSION` marker extraction;
- DoH resolution across all providers plus working-IP verification
  (`www.instagram.com` → `57.145.12.34`, dead `31.13.72.174` rejected);
- removal of the marked `hosts` block (ours and the older project's);
- `config` and systemd unit generation;
- correct refusal to run on non-Linux.

**Not verified (requires a Linux run):**
- actual `nfqws2` start through the init script;
- nftables/iptables rule creation and absence of routing loops;
- systemd service registration and operation;
- package installation via `apt`/`dnf`/`pacman`;
- real DPI bypass against a specific ISP.

On the target machine start with item **[5]** (requirements), then **[1]**
(install), then **[2]** (start) and **[4]** (diagnose). If `nfqws2` does not
start, check `systemctl status zapret2win` and `dmesg`.

## Requirements

On the **first run** the script checks dependencies itself and offers to
install the missing ones. Manually: menu **[11]** (check) and **[12]** (install),
or `-Action Check` / `-Action Deps`.

### Installed automatically

| Dependency | Method |
|---|---|
| **.NET Framework 4.x** | winget → chocolatey → direct download of the official 4.8 installer (`/q /norestart`) |
| **TLS 1.2 for .NET** | registry keys `SchUseStrongCrypto` + `SCHANNEL\Protocols\TLS 1.2` |
| **zapret2 release** | downloaded from GitHub (~9.5 MB) |
| **Node.js** *(optional)* | winget / chocolatey; needed only for `tools/` |

Before downloading the release the script **enables TLS 1.2** when it is off —
otherwise the GitHub download fails on a clean system.

### Cannot be installed automatically

| Dependency | Why |
|---|---|
| **Windows PowerShell 5.1** | the script runs on it (chicken-and-egg); WMF 5.1 is retired from Microsoft's site — manual step |
| **Administrator rights** | granted by the user via UAC |
| **64-bit Windows** | OS reinstall |

### Required

| Requirement | Value | Why |
|---|---|---|
| **OS** | Windows 10/11, **x64** | WinDivert is a signed kernel driver; modern signatures are x64-only |
| **PowerShell** | **Windows PowerShell 5.1** (built into Win10/11) | `.cmd` invokes `powershell.exe`; PowerShell 7 alone is not enough |
| **.NET Framework** | 4.x | required by PowerShell and the WinDivert glue |
| **Privileges** | **administrator** | kernel driver, `System32`, `hosts`, scheduled task |
| **Internet** | for the first install | zapret2 release (~9.5 MB) is downloaded from GitHub; needs TLS 1.2 |
| **Disk space** | ~100 MB | release, runtime, logs |
| **Encoding of `Zapret2Windows.ps1`** | **UTF-8 with BOM** | without BOM PowerShell 5.1 reads it as ANSI and the script dies before starting |

### Also important

- **Antivirus / EDR.** WinDivert is often flagged as a hacktool. Add the project
  folder and `winws2.exe` to exclusions, otherwise the driver fails with
  `windivert: error opening filter: Access is denied`.
- **Conflicting software.** Documented conflicts between WinDivert and Hyper-V,
  WSL2, VirtualBox, third-party VPN clients and firewalls — up to BSOD.
- **Avoid Cyrillic in the path** — recommended; some external tools break on it.
- **Do not run two instances.** WinDivert refuses a second filter with the same
  expression.

### Optional

- **Node.js** — only for the diagnostics in `tools/`.
- **git** — only to clone; a ZIP download works too.

## If the script closes instantly

| Symptom | Cause | Fix |
|---|---|---|
| Window flashes and closes | `.ps1` has no **BOM** | save as "UTF-8 with BOM" or re-download |
| Window flashes and closes | PowerShell older than 5.1 | install Windows Management Framework 5.1 |
| Window flashes and closes | `.ps1` is not next to `.cmd` | keep both files in one folder |
| `[ERROR] Script exited with code 1` | read the message above it | the window now **stays** open |
| `windivert: error opening filter: Access is denied` | no admin rights or AV block | run as administrator, add an exclusion |
| `Не найден исходный релиз zapret2` | no release and no internet | download the release into `zapret2-v1.0.6/` |

The launcher validates the file encoding before starting and **keeps the window
open** on any error — silent closes are gone.

## Quick start

1. Clone the repository (or unpack the ZIP).
2. Run `Zapret2Windows.cmd` **as Administrator**.
3. Choose **[5]** to verify requirements.
4. Choose **[1]** to install. The zapret2 release is downloaded from GitHub
   automatically if it is not present next to the script.
5. Choose **[2]** to start the system-wide bypass.

Menu items:

| Item | Action |
|---|---|
| [1] | Install or update zapret2 runtime |
| [2] | Start / stop bypass *(toggle)* |
| [3] | Autostart at logon: enable / disable *(toggle)* |
| [4] | Diagnose resources |
| [5] | Check requirements |
| [6] | Install missing dependencies |
| [7] | Refresh DNS via DoH |
| [8] | Learned domains and logs |
| [9] | Update the script |
| [10] | Uninstall from system |
| [0] | Exit |

Labels of **[2]** and **[3]** follow the actual state: when the bypass is
running the item offers "Stop", otherwise "Start". Same for autostart. There is
no separate "disable" item — one action covers both states.

## Script update (item [9])

Update source:

```
https://github.com/HikariRisser/Zapret2WinScrpt
```

The script downloads `Zapret2Windows.ps1` from the `main` branch (falling back
to `master`), compares versions and offers an update.

The version lives inside the script:

```powershell
$script:ScriptVersion='1.1.0'
```

Flow:

1. the remote copy is downloaded and its version is extracted;
2. content is compared with the local file (line endings and BOM normalised);
3. if identical — "already up to date";
4. if the remote version is newer — the update is offered;
5. if it is **older** or carries **no version marker** — a rollback warning is
   printed and explicit confirmation is required;
6. a backup `Zapret2Windows.ps1.<timestamp>.bak` is created before writing;
7. the new file is parsed by PowerShell; on a syntax error the backup is
   restored automatically;
8. after a successful replacement a restart is offered.

Command line:

```powershell
.\Zapret2Windows.ps1 -Action Update          # with confirmations
.\Zapret2Windows.ps1 -Action Update -Force   # no prompts
```

**Note:** only the script itself is updated. The zapret2 runtime, domain lists
and the autostart task are untouched — use item **[1]** for those.

If the repository holds a copy without the `ScriptVersion` marker, the script
treats it as potentially outdated and requires explicit confirmation. This
prevents rolling back a working version to an old copy.

Installation copies the architecture-matched official `winws2`, WinDivert
driver/DLL, Cygwin runtime, Lua libraries, hostlists, and official WinDivert
filter fragments into `runtime\winws2` and the protected directory
`C:\Windows\System32\Zapret2Windows`.

Start enables system-wide WinDivert interception. This is not a browser proxy:
TCP/UDP traffic from all applications is eligible for interception.

Command-line equivalents:

```powershell
powershell -ExecutionPolicy Bypass -File .\Zapret2Windows.ps1 -Action Install
powershell -ExecutionPolicy Bypass -File .\Zapret2Windows.ps1 -Action Start
powershell -ExecutionPolicy Bypass -File .\Zapret2Windows.ps1 -Action Status
powershell -ExecutionPolicy Bypass -File .\Zapret2Windows.ps1 -Action Diagnose
powershell -ExecutionPolicy Bypass -File .\Zapret2Windows.ps1 -Action DohHosts
powershell -ExecutionPolicy Bypass -File .\Zapret2Windows.ps1 -Action Stop
powershell -ExecutionPolicy Bypass -File .\Zapret2Windows.ps1 -Action Uninstall
```

## What is implemented

- official x64/x86 release selection based on Windows architecture;
- WinDivert full-port interception for TCP 80/443 and UDP 443, both directions;
- official `zapret-lib.lua` and `zapret-antidpi.lua` from the same release;
- HTTP strategy: fake + multisplit;
- TLS strategy: fake + multidisorder with ClientHello reassembly enabled;
- QUIC strategy: fake on `quic_initial`;
- **Discord voice/media profile**: fake on `discord_ip_discovery`, `stun`,
  `wireguard_initiation`, `wireguard_cookie` (official zapret2 scheme from
  `init.d/custom.d.examples.*/50-discord-media`, `50-stun4all`, `50-wg4all`);
- official Discord media, STUN, and WireGuard raw filter fragments;
- static hostlist plus zapret2 autohostlist feedback;
- **DNS over DoH** for DNS-level blocks (marked block in `hosts`, removed by
  `Uninstall`);
- **full uninstall** (process, task, kernel service, runtime directory, hosts);
- logs, PID tracking, safe stop, status, diagnostics, and autostart;
- no TLS MITM, no root certificate, no browser-specific configuration.

The runtime starts with a conservative seed list. zapret2's autohostlist
learns domains when its failure detector sees retransmissions/RST/insufficient
responses. The learned list is stored in:

```text
runtime\winws2\lists\autohostlist.txt
```

## Discord voice

Voice uses a different transport than the web client: a UDP media path plus a
WebSocket gateway for signaling. The controller therefore has a dedicated 4th
profile that desyncs `discord_ip_discovery`, `stun`, and WireGuard payloads, and
the WinDivert capture includes the official media/UDP fragments.

Verified on this host:

| check | result |
|---|---|
| HTTPS API (`/api/v9/gateway`) | 200 |
| HTTPS API (`/api/v9/voice/regions`) | 401 (reachable; login required) |
| WSS voice gateway `gateway.discord.gg` | Hello `op=10`, heartbeat present |
| UDP STUN binding (Google / Cloudflare) | `0x0101` success, mapped address returned |
| Profile on `discord_ip_discovery` (debug) | `profile 4 matches` → `fake_4_1 desync` |
| Profile on `stun` (debug) | `fake_4_1 : payload_type 'stun' satisfy filter` |

Debug trace for a synthetic 74-byte IP-discovery packet on port 50000:

```text
UDP: len=74 : 00 01 00 46 ...
packet contains discord_ip_discovery payload
discovered l7 protocol
desync profile 4 (noname) matches
* lua 'fake_4_1' : payload_type 'discord_ip_discovery' satisfy filter
* lua 'fake_4_1' : desync
```

**Limitation:** a full voice session (joining a channel with two-way audio)
cannot be verified without a logged-in Discord client, because the real voice
endpoint is only issued after authentication. All measurable transports were
checked: signaling (WSS), the API, and the UDP media path, plus proof that the
voice profile actually fires.

## Security

Live resources (Lua, lists, filters and the kernel driver) are placed in
`C:\Windows\System32\Zapret2Windows`, where ordinary users have read-only
access. This is deliberate: the project working folder may be writable by other
users, while `winws2` executes Lua inside a process running with
administrator/SYSTEM rights and kernel-driver access. See
[SECURITY.md](SECURITY.md) for the full threat review, what was fixed, and what
remains.

Before enabling autostart, move `Zapret2Windows.ps1` itself into a directory
that ordinary users cannot write to; otherwise the SYSTEM task stays a
privilege-escalation vector.

## Uninstall

Menu item **[9]** (or `-Action Uninstall`) removes the project from the system
in five steps:

| Step | Removed |
|---|---|
| 1/5 | `winws2` process |
| 2/5 | `Zapret2Windows` scheduled task (autostart) |
| 3/5 | `WinDivert` kernel service |
| 4/5 | `C:\Windows\System32\Zapret2Windows` protected directory |
| 5/5 | marked block in `hosts` (ours and the one from the older project) |

It then prints a leftover check for every component. The command is
idempotent. A `hosts.zapret-backup` copy is created before editing `hosts`.

Variants:

```powershell
.\Zapret2Windows.ps1 -Action Purge -IncludeProject   # also remove project runtime
.\Zapret2Windows.ps1 -Action Uninstall -KeepLogs     # keep a copy of logs
.\Zapret2Windows.ps1 -Action Uninstall -Force        # no confirmation prompt
```

**Not touched:** certificate store, other files in `System32`, unrelated `hosts`
entries, the project folder (unless `-IncludeProject`).

## DNS over DoH

DPI desync cannot help when the ISP returns no IP at all (DNS block):
`youtube.com` and `rutracker.org` simply do not resolve. The controller
therefore resolves names over DoH (Cloudflare, Google, Quad9) and writes the
result into `hosts` as a marked block:

```
# --- Zapret2Windows DoH begin ---
172.67.182.196	rutracker.org
...
# --- Zapret2Windows DoH end ---
```

Runs automatically on `Install`; manually via menu **[10]** or
`-Action DohHosts`. Note that `hosts` matches exact names, so `www` variants
are resolved separately. Removed completely by `Uninstall`.

### Working-IP verification (important)

DoH often returns a **dead edge address** — typical for Meta/Instagram:
`31.13.72.174` does not answer while `57.145.12.34` works. Pinning the first
returned address in `hosts` **breaks** the site even if it worked before.
The address is therefore verified before writing:

1. A records are collected from **all DoH providers** (Cloudflare, Google,
   Quad9) — different CDN nodes return different addresses, some of them alive;
2. CNAME targets are added (`www.instagram.com` →
   `z-p42-instagram.c10r.instagram.com`);
3. for `www.X` the parent `X` addresses are added;
4. every candidate is checked with a **real TCP connection to port 443**;
5. only a confirmed working address is written to `hosts`.

If no address works, the domain is **not pinned** and stays with system DNS.
That is better than hardcoding a dead IP.

Such domains are reported as "no working IP" (e.g. `ytimg.com`, `twimg.com`,
`githubassets.com` — they are usually served via CNAME and work without a
separate entry).

## Important limits

This is a system-wide DPI desync controller, not a VPN. It can handle traffic
that is reachable at the IP/TCP level but interfered with by DPI. It cannot
restore a route when every destination IP is filtered, and it cannot turn a
local SOCKS proxy into a transparent system tunnel. Full IP/routing blocks and
arbitrary UDP services require an external system route such as WireGuard,
Wintun/TUN, or another VPN endpoint.

HTTP/2 is deliberately not rewritten. The release supports TLS ClientHello
reassembly for desync, but stock `tls_mod` has no ALPN modification. Unsafe
Lua packet replacement can invalidate TCP sequence/reassembly and break TLS.

The script therefore does not promise that every site or protocol will work:
its diagnostic output separates TCP reachability, HTTP result, and WinDivert
startup errors. A `200` from one HTTP request is not proof that every native
application, WebSocket, QUIC, or UDP media flow works.

## Project structure

```
zapret2-windows/
├── Zapret2Windows.ps1   — controller (install, start, diagnose, uninstall)
├── Zapret2Windows.cmd   — launcher that requests administrator rights
├── README.md            — documentation (English)
├── README.ru.md         — documentation (Russian)
├── SECURITY.md          — security audit: threats and what was fixed
├── LICENSE              — MIT
├── .gitignore
├── tools/               — optional diagnostics
│   ├── probe-h2.js      — HTTP/2 versus HTTP/1.1
│   └── probe-voice.js   — Discord voice transport
├── runtime/             — created on install (not in git)
└── zapret2-v1.0.6/      — upstream release, downloaded on install (not in git)
```

## Diagnostics (tools/)

Optional Node.js scripts that help locate the failing layer:

```bash
node tools/probe-h2.js discord.com rutracker.org www.youtube.com
node tools/probe-voice.js
```

`probe-h2.js` compares HTTP/2 and HTTP/1.1 — it shows whether HTTP/2
specifically breaks. `probe-voice.js` checks Discord voice signaling (HTTPS
API, WSS gateway) and the UDP media path (STUN).

## Source and release

Upstream repository: <https://github.com/bol-van/zapret2>

The zapret2 build is **not stored in the repository** — it is downloaded from
the official release during installation (or placed manually into
`zapret2-v1.0.6/`). Keep `winws2.exe`, WinDivert files, and Lua libraries from
the same release together; mismatched versions break compatibility
(`NFQWS2_COMPAT_VER`).

## Publishing to GitHub

The repository is ready: `.gitignore`, `LICENSE`, documentation, and a clean
split between code and generated files. The zapret2 build and `runtime/` are
**not** committed — they are downloaded/created during installation.

```bash
git init
git add .
git commit -m "Zapret2 Windows: system-wide DPI desync controller"
git branch -M main
git remote add origin https://github.com/<user>/<repo>.git
git push -u origin main
```

Tracked: `.gitignore`, `LICENSE`, `README.md`, `README.ru.md`, `SECURITY.md`,
`Zapret2Windows.cmd`, `Zapret2Windows.ps1`, `tools/probe-h2.js`,
`tools/probe-voice.js`.
Ignored: `runtime/`, `zapret2-v1.0.6/`, `*.log`, `*.zapret-backup`.

## License

MIT — see [LICENSE](LICENSE). zapret2 is distributed under the MIT License,
Copyright (c) 2016-2026 bol-van.
