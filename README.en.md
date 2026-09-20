[中文](README.md) | [English](README.en.md)

# FanGlass

A Liquid-Glass fan controller for macOS, written in plain SwiftUI with zero third-party dependencies.

![macOS](https://img.shields.io/badge/macOS-15%2B-blue) ![arch](https://img.shields.io/badge/arch-Apple%20Silicon-green) ![license](https://img.shields.io/badge/license-MIT-lightgrey)

**Apple Silicon only (M1 and later).** Intel Macs are not supported — see [Supported Macs](#supported-macs).

<p align="center">
  <img src="docs/menubar.png" width="330" alt="FanGlass menu-bar panel">
</p>

<p align="center"><sub>The menu-bar panel: hottest sensor, fan RPM, per-group temperatures and quick modes. The screenshot shows the Chinese UI.</sub></p>

## Features

- **Lives in the menu bar.** The status item shows the hottest sensor temperature; the panel behind it shows every sensor group, the current fan RPM, and a row of quick modes (Auto / Quiet / Balanced / Performance / Max) that apply to all fans at once — **the active one is highlighted**.
- **Per-fan configuration.** Auto, fixed speed, or curve — set independently on multi-fan Macs.
- **Fan curve editor.** 2–8 draggable control points with monotone cubic (PCHIP) interpolation, so the curve never doubles back. Double-click empty space to add a point, right-click to delete. Temperature on X, fan percentage on Y (labelled in real RPM too), with the current operating point marked live.
- **Curve presets.** Quiet / Balanced / Performance / Max, with the selected one highlighted; drag any point and it is marked as a custom curve.
- **Sensor dashboard.** Every SMC temperature key is scanned at launch and grouped into CPU / GPU / Memory / Power / System / Ambient / Other, with live values and history charts.
- **Overheat alerts.** A system notification when any sensor (except ambient) crosses the threshold; adjustable, and switchable off.
- **RPM hysteresis.** 0–400 RPM, so the speed does not oscillate around a boundary value.
- **The status never lies.** A missing or outdated helper, an SMC write the hardware rejected, a failed sensor read — each one is stated plainly in the UI instead of being papered over.
- **Bilingual UI.** English and Simplified Chinese, following the system language by default and overridable on its own under **Settings → General → Language**; the change takes effect on the next launch.
- **Persistence.** Settings live in `~/Library/Application Support/FanGlass/settings.json`.

## Installation

**Requirements:** an Apple Silicon Mac running macOS 15 or later. (The Liquid Glass top bar needs macOS 26; on older systems it falls back to a standard system material.)

### 1. Download

1. Download `FanGlass.app.zip` from [Releases](../../releases) and unzip it.
2. Drag `FanGlass.app` into your Applications folder.
3. Open it. FanGlass is signed ad-hoc rather than with an Apple Developer ID, so Gatekeeper blocks the first launch. Either:
   - open **System Settings → Privacy & Security**, scroll to the **Security** section at the bottom, find the blocked FanGlass entry, click **Open Anyway**, then confirm with **Open**; or
   - remove the quarantine flag from a terminal:

     ```bash
     xattr -dr com.apple.quarantine /Applications/FanGlass.app
     ```

   > Right-click → Open no longer bypasses Gatekeeper on macOS 15 and later, so use one of the two methods above. An app you build yourself carries no quarantine flag and skips this step entirely.

4. On first launch FanGlass asks for administrator authorization once:

   > **FanGlass needs one administrator authorization**
   > Writing fan speeds requires root privileges, so FanGlass needs one administrator authorization to install the background helper that does the writing.
   >
   > Upgrading or uninstalling the helper asks once more; the helper stays resident in the background and can be removed at any time under Settings → Privileged Helper.

   Click **Install Helper** and enter your login password. The status pill in the window turns to "Helper connected" and you can start driving the fans.

Chose **Later**? Nothing is lost. The next time you pick a fixed speed, a curve preset, or a quick mode from the menu bar, FanGlass offers to install the helper right there — no hunting through Settings. The menu-bar panel carries an install button, the fan page keeps a persistent banner while the helper is missing or outdated, and the status pill itself is clickable ("Helper not installed · Install" / "Helper outdated · Update").

### 2. Build from source

You need the Xcode Command Line Tools (`xcode-select --install`) — **not** full Xcode. There is no Xcode project; everything is compiled directly with `swiftc` in about 15 seconds:

```bash
git clone https://github.com/sganggs/FanGlass.git
cd FanGlass
./scripts/build.sh      # builds the app + helper into build/FanGlass.app (ad-hoc signed)
open build/FanGlass.app # or ./scripts/run.sh, which builds and launches
```

You can also install the helper without touching the UI: `./scripts/install.sh` (same single authorization prompt).

## Usage

- **Menu bar.** The status item shows the hottest sensor. The panel below it lists the sensor groups and the fan speed, and the quick-mode row at the bottom **applies to every fan**. The active mode is highlighted; when fans disagree, or a fan is on a custom curve or a fixed speed, a caption line says so.
- **Dashboard.** Sensor group cards plus a history chart, with the number of probes found on this Mac next to the heading.
- **Fan control.** One card per fan, showing live RPM, the hardware RPM range, and a "Manual control" badge.
  - **Auto** hands the fan back to macOS and needs no helper.
  - **Fixed** maps the slider percentage onto the fan's own `F{i}Mn..F{i}Mx` range and applies the final value when you let go.
  - **Curve** starts from a preset and is then edited directly on the graph: drag points, double-click empty space to add, right-click to delete (2 minimum, 8 maximum). Which temperature the curve follows is chosen in Settings (CPU by default, or the hottest sensor).
- **Settings.** UI language (System / 简体中文 / English), sampling interval (0.5–3 s), launch at login, whether to restore automatic control immediately on quit, the curve's temperature source, RPM hysteresis, the overheat threshold, and installing / reinstalling / uninstalling the privileged helper.

## Supported Macs

Exactly one machine has been verified on real hardware: **Mac16,10 (M4, single fan) on macOS 27.0 (26A428)**. The key tables for the other generations come from published sources and are implemented in the code, but **have never been run on the actual hardware**. The table says which is which.

| Model | Sensors | Fan control | Notes |
|---|---|---|---|
| M1 / M1 Pro / Max / Ultra | expected | expected | CPU via `Tp*`, GPU via `Tg*`; untested |
| M2 family | expected | expected | same key families; untested |
| M3 family | expected | expected | this generation reports CPU as `Tf0*`/`Tf4*` and GPU as `Tf1*`/`Tf2*`; handled separately, untested |
| M4 family | ✅ tested | ✅ tested | developed and verified on Mac16,10 |
| M5 and later | expected | expected | grouping is by SMC key prefix; if the family changes again, unrecognised sensors land in "Other" — please send a `probe` dump |
| Fanless Macs (MacBook Air, …) | expected | — | sensors only; the UI says so explicitly |
| Multi-fan Macs (14/16″ MBP, Mac Studio, Mac Pro) | expected | expected | each fan configured independently, menu bar shows the fastest fan and the fan count; untested |
| Intel Macs | ❌ | ❌ | see below |

**On Intel Macs:** the released build is a single arm64 slice and will not run. The code does contain what Intel needs (big-endian `sp78`/`fpe2` fixed-point decoding, `TC0*`/`TCA*`/`TG0*` grouping, and the legacy `FS!` force bitmask for models without `F{i}Md`), and `FANGLASS_ARCHS="arm64 x86_64" ./scripts/build.sh` does produce a universal binary — but that path **has never been exercised on real Intel hardware**, so it is not a supported configuration. PRs and issues from anyone with an Intel Mac are very welcome.

**If sensors are grouped wrongly on your Mac,** `tools/probe.swift` dumps every SMC key, its type and its decoded value. Pasting that into an issue is what lets a new generation's key table be filled in:

```bash
swiftc -O -o build/probe tools/probe.swift Sources/Shared/SMC.swift -framework IOKit
./build/probe          # everything; ./build/probe T for temperature keys only
```

It only reads, never writes, and needs no privileges.

## How it works & safety

```
FanGlass.app (SwiftUI menu-bar agent, ordinary user privileges)
   │  SMC reads: temperatures / RPM / fan hardware range (IOKit AppleSMC, no privileges)
   │  JSON-lines over /var/run/fanglass.sock (5 s heartbeat command,
   │  plus a status query every ~10 s; queries do not feed the watchdog)
   ▼
fanglass-helper (launchd root daemon, protocol v6)
   │  SMC writes: F{i}Md manual mode + F{i}Tg target RPM (legacy FS! bitmask where needed)
   │  re-asserted every second (macOS periodically takes fan control back)
   ▼
AppleSMC
```

Reading temperatures needs no privileges at all. **Writing the fan registers is root-only** — a non-root write to `F0Md` / `F0Tg` is rejected by the kernel with `kIOReturnNotPrivileged`. That is the only reason a helper exists, and why exactly one administrator authorization is unavoidable.

**The helper is a root daemon reachable over a Unix socket.** A public repo shipping one should say where its boundaries are:

- **Who may command it.** Every connection's peer uid is checked with `LOCAL_PEERCRED`; only root and the user currently at the console are accepted, everything else is refused (with rate-limited logging, so the root-owned log cannot be spammed).
- **What it may do.** Fan-related SMC writes, and nothing else. Targets are always clamped to the range the fan itself reports (`F{i}Mn..F{i}Mx`), so it cannot overspeed a fan.
- **App silent for 20 s** → the watchdog hands every fan back to macOS. (The clock jump across sleep does not count as silence; `kill -9` has been verified to recover.) Only real control commands (`hold` / `auto`) refresh that deadline — `ping` and `status` are pure queries, so a forced speed nobody is tracking any more cannot be kept alive by the app's routine status polling.
- **Adopting forgotten holds at startup** → on launch the app asks the daemon which fans it is currently holding. Fans this build will keep driving are adopted, so they can be handed back normally; fans it will never touch (no fan control on this model, or an index not in the current fan list) are returned to macOS immediately. A speed left behind by a force-quit process is never left unowned.
- **SIGTERM / SIGINT** (uninstall, reboot, `launchctl bootout`) → restore automatic control, then exit.
- **~10 s of failing writes** → reopen the IOKit connection, and if it still fails, hand the fans back rather than keep hammering hardware that is not listening.
- **Sensor reads failing** → a failed read is never treated as 0 °C (which would drive a curve to minimum RPM); the fan goes back to macOS and the UI says why.
- **Quitting the app** (⌘Q / Quit in the menu bar) → automatic control is restored immediately. Turning that off in Settings only defers it: the helper's watchdog still takes over ~20 s later. There is no "keep my fans where I left them after quitting".
- **The installer.** The privileged script is never written to disk — it is passed to `osascript` as an argument — and the staged files' sha256 digests are re-checked as root after authorization, closing the window between staging and the privileged copy. The helper logs to `/var/log/fanglass-helper.log` with a `newsyslog` rotation rule, both removed on uninstall.

**Why not SMAppService / SMJobBless?** Both require the app to carry a stable Apple Developer signing identity; an ad-hoc build is rejected outright. On top of that, a daemon registered through `SMAppService.daemon` must additionally be allowed by hand in **System Settings → Login Items & Extensions**, and it refers to a path inside the app bundle, so moving the app breaks it. The current approach instead copies the helper to `/Library/PrivilegedHelperTools` after one authorization: from then on, where the app lives — and whether it is updated or deleted — does not matter.

## Uninstalling

1. FanGlass → **Settings → Privileged Helper → Uninstall Helper…** (one more authorization), or run `./scripts/uninstall.sh`.
2. Move `FanGlass.app` to the Trash.
3. To drop the settings too: `rm -rf ~/Library/Application\ Support/FanGlass`.

Uninstalling removes `/Library/LaunchDaemons/com.fanglass.helper.plist`, `/Library/PrivilegedHelperTools/fanglass-helper`, the socket, the log and its rotation rule. The helper receives SIGTERM first, so the fans are back under system control before it goes.

## FAQ

**Why is a password required at all?**
macOS only lets root processes write the SMC's fan registers. Every fan-control app on macOS has to cross that line; there is no zero-prompt path. FanGlass asks once at install time and never during normal use — only upgrading the helper (when the protocol version changes) or uninstalling it asks again.

**What if I just delete the app and never uninstall the helper?**
After 20 s without a heartbeat the helper returns every fan to automatic control, so nothing stays stuck at a forced speed. The daemon itself is still installed, though — follow the uninstall steps above to remove it properly.

**Does moving the app to /Applications, or updating it, break the helper?**
No. The helper is a separate file in `/Library/PrivilegedHelperTools` and does not care where the app lives.

**The status says the helper is outdated.**
launchd keeps running whatever daemon is on disk, and an old one may silently ignore commands from a newer app. The status pill reads "Helper outdated · Update" and the fan page carries a persistent banner; click either one (or Settings → Update Helper…) to reinstall. It costs one more authorization.

**The fan page says this model is not supported.**
This Mac's SMC exposes no writable RPM target or manual-mode switch — a fanless model, or one whose fans are read-only. The sensor half of the app still works normally.

**Launch at login does not stick.**
That toggle goes through the system's `SMAppService`, and an ad-hoc signed build can be refused registration. Add FanGlass by hand under System Settings → General → Login Items instead.

**Can the UI be switched to English?**
Yes. The UI follows the system language by default; to pin it, choose System, 简体中文 or English under **Settings → General → Language** and relaunch FanGlass. (That setting writes the same per-app language override System Settings → General → Language & Region → Applications does.)

## Design notes

The design rule is "glass at the edges, not in the background" (in the spirit of macOS Tahoe / visionOS):

- A solid base: cool grey-blue with a ±2% vertical lightness drift, clean without being dead flat, plus one **static** white studio light at the top that every specular highlight answers to.
- Glass cards: translucent white fill, a mirror highlight along the top edge, a 1px gradient hairline border, and two shadow layers (contact + ambient).
- On macOS 26 the top bar uses the system Liquid Glass material, so cards visibly refract as they scroll underneath; older systems fall back to a standard material.
- A 3px ambient strip at the very top is the only element that changes color with temperature (blue → green → orange → red) — decoration and status indicator in one.
- Motion: spring scale on press, brighter borders on hover, a sliding glass pill in segmented controls, and a top-bar fan glyph that spins at the real RPM.
- Selection is drawn as an accent border plus a faint tint — "accent the edges" rather than a filled block — which keeps it clearly distinct from a prominent primary button.
- Temperature numbers change color by band (<50 blue / <70 green / <85 orange / above that red).

## Contributing

What the project needs most is **coverage on real hardware**: nothing but the M4 has actually been tested. If you have a different Mac, running the read-only SMC probe and pasting the output into an issue is the single most useful contribution:

```bash
swiftc -O -o build/probe tools/probe.swift Sources/Shared/SMC.swift -framework IOKit
./build/probe
sysctl -n hw.model
```

`tools/probe.swift` only reads the SMC, never writes to it, and needs no root.

Conventions:

- UI strings in the code are **English source strings, and those strings are the localization keys**; the Chinese lives in `Resources/zh-Hans.lproj/Localizable.strings`. Every new string needs an entry in BOTH `Resources/en.lproj` and `Resources/zh-Hans.lproj` (`build.sh` runs `plutil -lint` on both and fails the build on a bad one). Nothing under `Sources/` may contain a CJK character — comments included.
- Anything that reaches the screen through a Swift `String` (enum titles, `String(format:)`, `NSAlert`, notification content) has to go through `String(localized:)` itself; SwiftUI initialisers that take a `LocalizedStringKey` (`Text`, `Button`, `Toggle`, …) localize on their own.
- The menu-bar quick-mode row uses the `AdaptivePillRow` layout: one row of equal-width pills while the labels fit (Chinese does), wrapping onto further rows at natural widths when they do not (English does), so a long label never truncates to "…".
- Layout: `Sources/FanGlass` (the app), `Sources/HelperTool` (the root daemon), `Sources/Shared` (SMC access and the wire protocol, compiled into both).
- There is no Xcode project — `scripts/build.sh` calls `swiftc` directly. Run it after a change and you are done.
- `build.sh` runs `xattr -cr` before signing: with the source tree on the Desktop or in an iCloud-synced folder the bundle picks up `com.apple.FinderInfo`, `codesign` then fails with "resource fork, Finder information, or similar detritus not allowed", and an unsigned bundle is reported to whoever downloads it as damaged.
- If you change the helper's wire protocol — or its behaviour, even when the message format is untouched — bump `version` in `Sources/Shared/HelperProtocol.swift`. launchd runs whatever daemon is on disk, and the "helper outdated" prompt is the only thing that ever replaces it; without the bump you have only changed the code in the repo.
- The root-side of `scripts/install.sh` is assembled inside `$(cat <<EOF … EOF)`, and the bash 3.2 that macOS ships keeps looking for the closing paren inside that heredoc — a single apostrophe in an English comment there breaks the whole file with a misleading `unexpected EOF` somewhere else. That script pings the helper with `nc` rather than `python3` to confirm the install: on a Mac without the Command Line Tools, `/usr/bin/python3` is a stub that pops an installer dialog instead of running.

## License

[MIT](LICENSE) © 2026 Ausevay
