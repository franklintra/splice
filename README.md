<div align="center">

# Splice

### Splice apps onto any iPhone - and keep them alive.

**The open-source, cross-platform iOS sideloader with AltServer-style auto-refresh.**
Install apps on your iPhone from **Linux, Windows, or macOS** - no Mac, no cable after the first pairing, and your apps never silently expire.

</div>

> **Splice is a maintained fork of [Dadoum/Sideloader](https://github.com/Dadoum/Sideloader).**
> All of the hard original work - the GrandSlam authentication, the anisette
> emulation, the signing engine, the Linux-native breakthrough - is
> [Dadoum](https://github.com/Dadoum)'s and the upstream contributors'. Splice
> builds on that foundation to turn the one-shot signer into a modern, multi-account
> re-sign/refresh tool. Huge thanks to them - please
> [sponsor Dadoum](https://github.com/sponsors/Dadoum).

---

## What is Splice?

Splice installs third-party `.ipa` apps onto an iPhone or iPad using a free Apple
developer signature - the same thing Xcode does when you run your own app on your
device. Think of it as an open-source, cross-platform replacement for *Cydia
Impactor* and a Linux-first sibling to *AltServer*.

The catch with free-account signing has always been the **7-day expiry**: the
provisioning profile dies after a week and the app stops launching. Splice solves
that the way AltServer does - a **background daemon re-signs your apps before they
expire**, so they just keep working. Unlike AltServer, that daemon runs anywhere,
including headless on a Linux box or a Raspberry Pi.

### Why Splice

| | **Splice** | AltServer | SideStore | Cydia Impactor |
|---|:---:|:---:|:---:|:---:|
| Open source | ✅ | partial | ✅ | ❌ |
| **Linux** | ✅ | ❌ | on-device | ❌ |
| Windows / macOS | ✅ | ✅ | n/a | ✅ |
| **Headless / server auto-refresh** | ✅ | ❌ | ❌ | ❌ |
| Auto re-sign before 7-day expiry | ✅ | ✅ | ✅ | ❌ |
| Multi-account / multi-team + quota | ✅ | ❌ | ❌ | ❌ |
| Remote / self-hosted anisette | ✅ | ❌ | ✅ | ❌ |
| Wireless install & refresh over Wi-Fi | ✅ | ✅ | ✅ | ❌ |
| Tweak injection (dylib / .deb) | ✅ | ❌ | ❌ | ❌ |
| Permanent install (CoreTrust / TrollStore) | ✅ | ❌ | ❌ | ❌ |
| JIT enablement helper | ✅ | ❌ | ❌ | ❌ |
| AltStore-style sources / catalogs | ✅ | ✅ | ✅ | ❌ |
| Scriptable `--json` output | ✅ | ❌ | ❌ | ❌ |

> **The thing nobody else does:** run `splice service install` on a Raspberry Pi or
> a home server and your sideloaded apps get re-signed forever - over Wi-Fi, with no
> Mac in the house and no terminal left open.

**Your Apple credentials are only ever sent to Apple's own servers**, and because
Splice is open source you can verify exactly that. Never trust a closed-source tool
with your Apple ID.

---

## Table of contents

* [Install](#install)
* [Quick start](#quick-start)
* [Commands](#commands)
* [Set-it-and-forget-it auto-refresh](#set-it-and-forget-it-auto-refresh)
* [Wireless install & refresh over Wi-Fi](#wireless-install--refresh-over-wi-fi)
* [Accounts, teams & App ID quota](#accounts-teams--app-id-quota)
* [Remote anisette servers](#remote-anisette-servers)
* [Sources (AltStore-style catalogs)](#sources-altstore-style-catalogs)
* [Tweak injection](#tweak-injection)
* [JIT enablement](#jit-enablement)
* [Permanent (TrollStore-style) install](#permanent-trollstore-style-install)
* [SideStore companion](#sidestore-companion)
* [How it works](#how-it-works)
* [Build it yourself](#build-it-yourself)
* [Platform support](#platform-support)
* [Acknowledgements](#acknowledgements)
* [Support the project](#support-the-project)

---

## Install

There is a cross-platform **CLI** (Linux, Windows, macOS) and a **GTK 4** desktop
frontend for Linux; a Qt frontend for all three desktops is in progress.

### macOS (Homebrew)

On Apple Silicon, install the CLI from the project's Homebrew tap:

```sh
brew install franklintra/tap/splice
```

That pulls in the `libimobiledevice` and `libplist` runtime dependencies for you.
Always use the fully-qualified `franklintra/tap/splice` name: an unrelated `splice`
cask (the audio app) already exists in homebrew-core, so a bare `brew install splice`
would grab the wrong thing. The first install from a third-party tap may ask you to
trust it, or run `brew tap franklintra/tap` first and follow the prompt.

Only an Apple Silicon (arm64) build is published today. On an Intel Mac, use a
release binary or [build it yourself](#build-it-yourself).

### Other platforms

Prebuilt CLI and GTK binaries are attached to each
[release](https://github.com/franklintra/splice/releases/latest) and produced by
GitHub Actions on every push (grab them from the **Actions** tab), or
[build it yourself](#build-it-yourself).

**Runtime dependencies:** `libimobiledevice`, `libplist-2.x` (2.2 and 2.3 both
attempted), and OpenSSL (used for networking; planned for removal).

> On **Windows**, MSVC builds of `libimobiledevice`/`libplist` are required (Splice
> is built with MSVC), plus the Microsoft Visual C++ redistributable. See
> `libimobiledevice-win32` and [Win32 OpenSSL](https://slproweb.com/products/Win32OpenSSL.html);
> place the DLLs next to the `splice` binary.

---

## Quick start

1. Get Splice (Actions artifact, or build it) and an `.ipa` you want to install.
2. Enable **Developer Mode** on the iPhone if it isn't already.
3. Sign in once so Splice can remember your account (handles 2FA):
   ```sh
   splice login
   ```
4. Connect the device and install the app (re-run if you hit a transient error):
   ```sh
   splice install App.ipa
   ```

That's it - the app is signed and installed. To keep it from expiring after ~7 days,
set up [auto-refresh](#set-it-and-forget-it-auto-refresh) so Splice re-signs it for
you automatically.

---

## Commands

```text
$ splice -h
Usage: splice [-d] [--json] [--log-level LEVEL] [--anisette-server URL]
              [--account EMAIL] [--thread-count N] [-h] <command> [<args>]

Available commands:
  login          Log in to an Apple account and persist the session (2FA aware).
  logout         Forget a stored account / session.
  install        Sign and install an app on the device (rename, register App ID,
                 sign and install automatically). --permanent for CoreTrust install.
  refresh        Re-sign installed apps before their 7-day profile expires.
  list           List installed apps and their expiry (use --json for scripting).
  uninstall      Remove an installed app from the device.
  daemon         Run the background refresh loop (use --once for one pass).
  service        Install/uninstall the per-user background refresh service.
  source         Manage AltStore/SideStore sources: add/remove/list/browse/install.
  tweak          Inject tweaks (.dylib or .deb) into an IPA before signing.
  jit            Enable JIT for an already-running app on the device.
  trollstore     CoreTrust permanent-install helpers (status).
  trollsign      Bypass Core-Trust with TrollStore 2's method (CVE-2023-41991).
  sidestore      SideStore companion: detect it and push the pairing file.
  sign           Sign an application bundle.
  app-id         Manage App IDs.
  cert           Manage certificates.
  device         Manage registered devices.
  team           Manage teams.
  tool           Run Splice's tools.
  version        Print the version.

Global options:
  -d, --debug              Enable debug logging
  --json                   Emit machine-readable JSON to stdout (logs go to stderr)
  --log-level LEVEL        trace|debug|info|warn|error (overrides --debug)
  --anisette-server URL    Use a remote anisette server (persisted as default)
  --account EMAIL          Act as a specific stored account (multi-account)
  --thread-count N         Threads used when signing the bundle
  -h, --help               Show this help message and exit
```

Most commands take `--udid <UDID>` to pick a device when several are connected, and
`--wifi` (alias `--prefer-network`) to force the Wi-Fi transport. The global
`--json` flag makes `list`, `install`, `refresh`, `team`, `device`, `app-id`,
`version`, `jit`, `trollstore`, and the `source` sub-commands emit parseable JSON on
stdout (all logging is routed to stderr).

---

## Set-it-and-forget-it auto-refresh

Free-developer-account apps stop launching once their ~7-day provisioning profile
expires. Instead of keeping a terminal open, register a per-user background service
that periodically runs the refresh daemon and shows a native desktop notification
when it re-signs an app (or when an app is about to expire but no device is around).

```sh
# Log in once so the daemon has stored credentials, then install the service.
splice login
splice service install                  # default: refresh every 6 hours
splice service install --interval 10800 # or pick your own interval (seconds)

splice service status                   # is it installed / loaded?
splice service uninstall                # disable and remove it (idempotent)
```

The service is per-user and uses your platform's native scheduler:

- **macOS** - a launchd LaunchAgent (`~/Library/LaunchAgents/dev.dadoum.sideloader.plist`).
- **Linux** - a systemd *user* service + timer (`sideloader-refresh.{service,timer}` under `~/.config/systemd/user`).
- **Windows** - a Task Scheduler task (`Sideloader\Refresh`).

Override the unit location for testing with `--unit-dir` (or the
`SIDELOADER_LAUNCH_AGENTS_DIR` / `SIDELOADER_SYSTEMD_USER_DIR` env vars). Use
`service install --no-notify` to suppress notifications. Scheduled-daemon logs are
written under the config directory's `logs/`.

> Run this on an always-on Linux box or a Raspberry Pi and your apps get re-signed
> forever, over Wi-Fi, with nothing plugged in.

---

## Wireless install & refresh over Wi-Fi

Once a device has been paired over USB at least once (and "Sync over Wi-Fi" is
enabled - the same trust that lets Finder/iTunes see the device without a cable),
Splice can install, refresh, and run its daemon over Wi-Fi on the same network.

* `splice install`, `splice refresh`, `splice uninstall`, and `splice tool …`
  automatically discover devices reachable over Wi-Fi as well as USB. A device
  reachable both ways is treated as a **single** device (so the daemon never
  refreshes it twice), and each command logs the transport it uses.
* When a device is reachable over **both**, Splice prefers the cable (more
  reliable). Pass `--wifi` to `install`, `refresh`, or `daemon` to force Wi-Fi.
* A device reachable **only** over Wi-Fi is selected automatically - no `--wifi`
  needed.
* `splice daemon` enumerates and refreshes both USB and Wi-Fi devices, so apps keep
  getting re-signed while your phone is merely on the same network.

To enable Wi-Fi sync: connect once over USB, trust the computer, then turn on "Show
this iPhone when on Wi-Fi" (Finder/macOS) / "Sync with this iPhone over Wi-Fi"
(iTunes/Windows). After that, the cable is optional.

---

## Accounts, teams & App ID quota

Splice supports **multiple Apple accounts** and **multiple developer teams** per
account. Log in to as many as you like; pick one per command with `--account` and
`--team`.

```sh
splice login                       # add an account (prompts for 2FA)
splice logout --account a@b.com     # forget one
splice team list                    # list teams across the active account
splice --account a@b.com --team <ID> install App.ipa
```

Free developer accounts are capped at **10 App IDs per 7-day window**. Splice tracks
your quota, reuses existing App IDs where it can, and warns before you run out
instead of failing opaquely mid-install (`splice app-id list`).

Credentials are stored in your OS keyring where available (macOS Keychain
implemented; libsecret / Windows credential store planned), never in plaintext
alongside the binary.

---

## Remote anisette servers

To talk to Apple's GrandSlam servers, Splice attaches device/identity ("anisette")
headers to every request. By default it generates them **locally** by emulating
Apple's provisioning with native libraries scraped from the Apple Music APK - no
external service required, but it has to download those libraries and provision the
machine.

Alternatively, point Splice at a **remote anisette server**:

```sh
splice --anisette-server https://your-anisette.example/ <command>
```

The URL is **persisted** as the new default, so later runs reuse it without the
flag. With a remote server configured, Splice skips the Android library download and
ADI provisioning entirely. Pass an empty value (or edit `state.json`) to return to
local emulation.

Compatible with both **anisette-v1** and **anisette-v3** servers (the `GET /`
headers endpoint they both expose), e.g. the self-hostable
[Dadoum/anisette-v3-server](https://github.com/Dadoum/anisette-v3-server).

---

## Sources (AltStore-style catalogs)

`splice source` subscribes to AltStore / SideStore *sources* (JSON app catalogs) and
installs apps from them without manually downloading an IPA. Subscribed URLs are
persisted in `state.json`.

```sh
splice source add https://apps.altstore.io          # subscribe (validates + prints app count)
splice source list                                  # list subscriptions
splice source list --names                          # also fetch each source's name
splice source browse                                # browse available apps
splice source browse --search delta                 # filter by name / bundle id
splice source browse --source com.example.repo      # limit to one source
splice source install com.rileytestut.Delta         # download latest IPA, sign & install
splice source remove https://apps.altstore.io       # unsubscribe (idempotent)
```

Both the legacy single-version format (`version`/`downloadURL`) and the newer
`versions` array (newest first) are supported. `browse` / `list --names` are
network-dependent and skip unreachable sources with a warning. If a bundle id is
offered by several sources, the first match is used (pass `--source` to
disambiguate). All sub-commands honour `--json`.

---

## Tweak injection

`splice tweak` patches an IPA so it loads extra dylibs on launch, *before* signing -
so the injected dylibs get signed together with the rest of the bundle.

```sh
splice tweak App.ipa --inject MyTweak.dylib                       # → ./<name>-tweaked.ipa
splice tweak App.ipa --inject MyTweak.dylib --output Patched.ipa
splice tweak App.ipa --inject A.dylib --inject some-tweak.deb     # several at once
splice tweak App.ipa --inject MyTweak.dylib --install             # sign & install directly
```

* A **`.dylib`** is copied into `<App>.app/Frameworks/` and an `LC_LOAD_DYLIB`
  command pointing at `@executable_path/Frameworks/<name>.dylib` is inserted into the
  main executable (every fat slice is patched).
* A **`.deb`** (Cydia/Procursus `ar` archive) is extracted with the system `ar`/`tar`,
  and every `.dylib` inside `data.tar` is bundled and injected like a standalone dylib.

**Limitations:** injection needs free space in the Mach-O header; if a binary lacks
it, the command fails loudly rather than corrupting the executable. Many `.deb`
tweaks are *substrate-based* and expect a hooking runtime (CydiaSubstrate / ElleKit)
on the device - Splice does not vendor one and warns when an injected dylib links
against a missing substrate. Plain dylibs load without extra setup.

---

## JIT enablement

Some apps (emulators, interpreters, JS engines) need *just-in-time* compilation,
which iOS only allows for a process the kernel flagged `CS_DEBUGGED`. Attaching a
debugger sets that flag; `splice jit` does this the same way
SideJITServer / StikDebug / Jitterbug do - it connects to the on-device
`com.apple.debugserver`, attaches to the already-running app, then detaches, leaving
it running with JIT enabled.

```sh
splice jit com.example.app                 # app must ALREADY be running
splice jit com.example.app --udid <UDID>
splice jit com.example.app --wifi
```

**Prerequisites** (the command reports a clear error if missing): **Developer Mode**
enabled *and* a **Developer Disk Image** mounted (connect to Xcode once is the
easiest way), and the **app already running** in the foreground. Pass the original
bundle id (or the on-device id); Splice resolves the executable and accepts the
mangled `<bundleId>.<teamId>` form. Supports `--json`.

> JIT is currently CLI-only - the generic GTK tool runner can't ask *which* app to
> target, which JIT requires.

---

## Permanent (TrollStore-style) install

A normal install uses a free **developer certificate**, so the app dies after ~7
days unless re-signed. On a *vulnerable* iOS version, Splice can instead do a
**permanent** install using the CoreTrust signature-validation bug
(**CVE-2023-41991**) - the same exploit TrollStore 2 uses. A permanent app survives
past expiry, needs **no Apple ID**, is never re-signed, and is ignored by the
refresh daemon.

```sh
splice trollstore status                 # does this device support it?
splice trollstore status --udid <UDID>
splice --json trollstore status          # machine-readable
splice install --permanent App.ipa       # alias: --troll
```

`status` reports the iOS version and availability, e.g.
`{"iosVersion":"16.6.1","bypassable":true,"permanentInstallAvailable":true}`.

> **Read before using:**
> * Works only on **iOS/iPadOS 14.0 – 16.6.1**. **Patched on 16.7+** (all 17.x/18.x
>   and 16.7.x). On a patched/too-old device, `--permanent` is **refused** with a
>   clear error - install normally instead.
> * It relies on a now-patched exploit. Updating to 16.7+ removes it; existing
>   permanent apps generally keep working, but you can't install new ones.
> * A permanent app is **your responsibility** - not managed or renewed by Splice.
>   Only install software you understand and trust.

---

## SideStore companion

[SideStore](https://sidestore.io) refreshes apps *on-device* (no computer after
setup), but first needs a pairing file inside its app container. `splice sidestore`
is a first-class helper for that:

```sh
splice sidestore status                  # is SideStore installed? which version?
splice sidestore pair                     # pair + push the pairing file in one step
splice sidestore pair --udid <UDID>
```

SideStore must already be installed (from <https://sidestore.io>) - these commands
detect it and hand it the pairing file; they don't install it. Keep the device
unlocked and trust the computer when prompted. With no device connected it prints a
clear message and exits non-zero (never crashes).

> SideStore reads its anisette server from its own in-app settings, so it can't be
> configured from the CLI. If you pass `--anisette-server`, `sidestore pair` prints
> the URL and reminds you to set the same one in SideStore → Settings.

---

## How it works

Splice fetches an iOS development certificate the way Xcode would if you were
developing your own app, and uses it to sign and deploy third-party apps. **No Mac,
Windows machine, or Apple software is required** - just `libimobiledevice` and
`libplist`.

You do need an Apple account to play the role of the "developer" - any account
works, ideally a burner, not the Apple ID on your phone (see the SideStore wiki for
easy ways to make one; on Linux, installing Apple Music on Waydroid is one route).

You can even build and sideload your *own* native iOS apps from Linux: compile with
[theos](https://theos.dev), package with `PACKAGE_FORMAT = ipa`, install with
Splice, and debug with `idevicedebug` / remote `lldb`.

---

## Build it yourself

> [!IMPORTANT]
> **Supported toolchain: LDC 1.41.0.** The CLI and core library are built and tested
> against LDC 1.41.0, which is what CI pins. **LDC 1.42.x currently triggers an
> internal compiler error** (the codegen backend segfaults, exit code -11), so do
> not use it. If Homebrew gave you 1.42.x, fetch 1.41.0 from the
> [LDC releases](https://github.com/ldc-developers/ldc/releases/tag/v1.41.0) and pass
> it explicitly:
> `dub build :cli-frontend --compiler=/path/to/ldc2-1.41.0/bin/ldc2`.
> GDC won't compile this code (the crypto library uses SIMD GDC can't emit yet).

**OpenSUSE Tumbleweed:**

```sh
sudo zypper in gcc dmd dub libharfbuzz-gobject0 libadwaita libphobos2-0_* libimobiledevice-1_0-6 git
git clone https://github.com/franklintra/Sideloader && cd Sideloader
dub build
./bin/splice
```

**Other distributions:** install LDC 1.41.0 (script on [dlang.org](https://dlang.org/)
or the [LDC releases page](https://github.com/ldc-developers/ldc/releases/tag/v1.41.0)),
then `dub build`. See the toolchain note above.

---

## Platform support

* **Linux** - the original priority (no real alternative existed before). CLI + GTK 4.
* **Windows** - CLI; needs MSVC builds of the native deps + the VC++ redistributable.
* **macOS** - CLI works; Apple-Silicon library auto-resolution means no manual
  `DYLD_FALLBACK_LIBRARY_PATH`. A SwiftUI GUI is scaffolded but unbuilt (no Mac to
  develop it - contributions welcome).

iOS version range is broad but not exhaustively mapped; 32-bit support is untested.
Please open an issue with anything that breaks.

---

## Acknowledgements

Splice stands entirely on [Dadoum](https://github.com/Dadoum)'s
[Sideloader](https://github.com/Dadoum/Sideloader) and the upstream community. With
thanks to:

- [Dadoum](https://github.com/Dadoum) and all Sideloader contributors - the engine,
  the auth, and the Linux-native breakthrough this builds on.
- [People on this thread](https://github.com/horrorho/InflatableDonkey/issues/87):
  first cues on machine/account authentication.
- The **SideStore** team - testing and machine-authentication help.
- The **AltStore** team - account auth and 2FA (especially kabiroberai's code).
- **zhlynn** (zsign), **indygreg** (rcodesign), and
  [teryx's article on code signatures](https://medium.com/csit-tech-blog/demystifying-ios-code-signature-309d52c2ff1d).
- Apple Music for Android libraries, and Apple's AuthKit/AuthKitWin for the request
  skeletons.
- Everyone else who helped along the way.

## Support the project

Splice is free and open source. If it's useful to you:

- ⭐ **Star this repo** - it's the cheapest way to help it reach people.
- 💙 **[Sponsor Dadoum](https://github.com/sponsors/Dadoum)** - the upstream author
  whose years of reverse-engineering made all of this possible. When Cydia Impactor
  died in 2019, Apple had released nothing for end users on Linux; it took two years
  of work to solve that without reimplementing the Windows API. That work is the
  reason Splice can exist.
