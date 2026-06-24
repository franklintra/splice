# Sideloader

*The missing open-source iOS sideloader.*

> **Note:** This is a maintained fork, originally forked from [Dadoum/Sideloader](https://github.com/Dadoum/Sideloader).
> It aims to keep the project up to date and improve it. All original work and credit go to [Dadoum](https://github.com/Dadoum) and the upstream contributors.

Sideloader is an application made to install third-party applications on iOS devices.

You can see it as an open-source replacement of _Cydia Impactor_.

<center>Leave a star and a small tip if you feel like it! — more information at the end!</center>

## Current state

Currently, there is a cross-platform CLI, with most features working.

And there is a Linux frontend based on GTK 4. It was the priority since no real alternative existed 
before.

A Qt frontend is being made for Linux, Windows and macOS.

A SwiftUI macOS GUI could be made (I got no Mac to work on that, but all the scaffolding code is here,
if someone wants to work on that).

I tried to make the code as readable as possible, if you struggle to understand anything
I am here to help! I don't want this to finish unmaintained!

## Usage

### GTK

![](screenshots/screenshot-gtk-2023-11-28.png)

### CLI

```sh
$ sideloader -h
Usage: sideloader [-d] [--thread-count THREADCOUNT] [-h] <command> [<args>]

Available commands:
  app-id         Manage App IDs.
  cert           Manage certificates.
  device         Manage registered devices.
  install        Install an application on the device (renames the app, register
                 the identifier, sign and install automatically).
  sign           Sign an application bundle.
  trollsign      Bypass Core-Trust with TrollStore 2's method (CVE-2023-41991).
  trollstore     TrollStore / CoreTrust permanent-install helpers (status).
  team           Manage teams.
  tool           Run Sideloader's tools.
  tweak          Inject tweaks (.dylib or .deb) into an IPA before signing.
  version        Print the version.

Optional arguments:
  -d, --debug    Enable debug logging
  --thread-count THREADCOUNT
                 Numbers of threads to be used for signing the application
                 bundle
  -h, --help     Show this help message and exit                                                                                                                                                                      
```

Table of Contents
=================

  * [How to install](#how-to-install)
  * [How to use the CLI to install](#how-to-use-the-CLI-to-install)
  * [Tweak injection](#tweak-injection)
  * [How do I build it myself?](#how-do-i-build-it-myself)
    * [OpenSUSE Tumbleweed](#opensuse-tumbleweed)
    * [Other distributions](#other-distributions)
  * [How it works?](#how-it-works)
  * [Features](#features)
  * [Notes on platform support](#notes-on-platform-support)
    * [Linux](#linux)
    * [Windows](#windows)
    * [MacOS](#macos)
  * [Acknowledgements and references](#acknowledgements-and-references)
  * [If you like my software, consider starring or even better: sponsoring me :)](#if-you-like-my-software-consider-starring-or-even-better-sponsoring-me-)

## How to install

Currently, the only builds available can be downloaded through GitHub Actions.

CLI builds include builds for every supported operating system, and GTK+ builds have a GUI
for Linux-based OSes.

When it will get a first release, there will probably be an easier download (not requiring an
account) in the Release tab of this repo, and hopefully it will be packaged as a Flatpak (even if
I currently don't see how to make it).

**Dependencies (at runtime):** libimobiledevice, libplist-2.X (I attempted to support both 2.2
and 2.3). OpenSSL is currently also needed, but I plan to remove that dependency as soon
as possible (only networking is requiring it).

*Note:* On Windows, MSVC builds of those libraries are needed as sideloader is built with MSVC.
It also implies you have to install Microsoft Visual C++ redistributable to run it, but you probably
already have those installed. Put them then in the same folder as Sideloader and you'll be able to
run it. (For libimobiledevice and libplist, take a look at libimobiledevice-win32, and for OpenSSL
see [this link](https://slproweb.com/products/Win32OpenSSL.html))

## How to use the CLI to install

1. Go to https://sidestore.io/ on your computer and download the SideStore.ipa file.
2. Download the most recent version of Sideloader from https://github.com/Dadoum/Sideloader/actions.
3. Use the following command to sideload the SideStore.ipa file (if there are errors, try running the command again):
	`sideloader install SideStore.ipa -i`
4. Enable Developer Mode on your iPhone if it's not already enabled.
5. Use the following command to generate the pairing file and send it to your phone:
	`sideloader tool run 0`
6. Download and install the Wireguard VPN app from the iOS App Store.
7. Visit https://sidestore.io/ on your phone and download the Wireguard Config file, then share it to the Wireguard app.
8. Enable the Wireguard VPN on your phone.
9. Open the SideStore app and sign in with the same Apple ID that you used to install SideStore in step 3.
10. Go to the Apps tab and refresh the SideStore app by tapping on the green day counter or selecting Refresh All. You must do this whenever you install SideStore, otherwise you may encounter errors like SideStore expiring earlier than it should.

## Wireless install/refresh over Wi-Fi

Once a device has been paired over USB at least once (and "Sync over Wi-Fi" is
enabled — the same SideStore-style trust that lets Finder/iTunes see the device
without a cable), Sideloader can install, refresh and run its daemon over Wi-Fi
on the same network — no cable required.

* `sideloader install App.ipa`, `sideloader refresh`, `sideloader uninstall …`
  and `sideloader tool …` automatically discover devices that are reachable over
  Wi-Fi as well as USB. A device that is reachable both ways is treated as a
  single device (so the daemon never refreshes it twice), and each command logs
  the transport it is using (e.g. `Connecting to <udid> over Wi-Fi`).
* When a device is reachable over **both** USB and Wi-Fi, Sideloader prefers the
  cabled connection (it is more reliable). Pass `--wifi` (alias
  `--prefer-network`) to `install`, `refresh` or `daemon` to force the Wi-Fi
  transport instead.
* A device that is **only** reachable over Wi-Fi is selected automatically; you
  do not need `--wifi` for it.
* The background daemon (`sideloader daemon`) enumerates and refreshes both USB
  and Wi-Fi devices, so apps keep getting re-signed while your phone is just on
  the same Wi-Fi network, with no cable plugged in.

To enable Wi-Fi sync, connect the device once over USB, trust the computer, then
turn on "Show this iPhone when on Wi-Fi" (Finder on macOS) / "Sync with this
iPhone over Wi-Fi" (iTunes on Windows). After that first pairing, the cable is
no longer needed for the commands above.

## Tweak injection

`sideloader tweak` patches an IPA so it loads one or more tweaks (extra dylibs)
on launch, *before* the app is signed — so the injected dylibs get signed
together with the rest of the bundle.

```sh
# Write a patched IPA (defaults to ./<name>-tweaked.ipa)
sideloader tweak App.ipa --inject MyTweak.dylib
sideloader tweak App.ipa --inject MyTweak.dylib --output Patched.ipa

# Inject several tweaks at once (.dylib and/or .deb), repeating --inject
sideloader tweak App.ipa --inject A.dylib --inject some-tweak.deb

# Sign the tweaked app and install it straight onto a connected device
sideloader tweak App.ipa --inject MyTweak.dylib --install
```

How it works:

* For a **`.dylib`**, the file is copied into `<App>.app/Frameworks/` and an
  `LC_LOAD_DYLIB` load command pointing at
  `@executable_path/Frameworks/<name>.dylib` is inserted into the app's main
  executable (resolved from `CFBundleExecutable`). Every architecture slice of a
  fat executable is patched.
* For a **`.deb`** (a Cydia/Procursus-style package — an `ar` archive containing
  `control.tar.*`/`data.tar.*`), the package is extracted with the system `ar`
  and `tar`, every `.dylib` found inside `data.tar` (e.g. under
  `/Library/MobileSubstrate/DynamicLibraries/`) is bundled into `Frameworks/`
  and injected just like a standalone dylib.
* With `--output` the tweaked bundle is repackaged into a new IPA. With
  `--install` it is signed and installed like `sideloader install` (honours
  `--team`, `--udid`, `--wifi`, `--singlethread`). If neither is given, a
  `./<name>-tweaked.ipa` is written.

Notes / limitations:

* The injection requires free space in the executable's Mach-O header (the
  padding between the load commands and the first section). Most app binaries
  have ample padding; if a binary does not, the command fails loudly instead of
  producing a corrupt executable.
* Many `.deb` tweaks are *substrate-based*: they expect a hooking runtime
  (CydiaSubstrate / ElleKit) to be present at runtime. Sideloader does **not**
  vendor a substrate runtime — when an injected dylib links against one that is
  not bundled, it logs a warning. Getting such a tweak to actually load at
  runtime requires that runtime to be available on the device; plain dylibs that
  do not depend on a substrate load without extra setup.

## How do I build it myself?

> [!IMPORTANT]
> **Supported toolchain: LDC 1.41.0.** The CLI and core library are built and
> tested against LDC 1.41.0, which is what CI pins (see `.github/workflows/`).
> LDC 1.42.x currently triggers an internal compiler error (ICE — the codegen
> backend segfaults, exit code -11) while compiling this project, so do not use
> it. If you installed LDC from Homebrew and it is 1.42.x, fetch 1.41.0 from the
> [LDC releases page](https://github.com/ldc-developers/ldc/releases/tag/v1.41.0)
> and pass it explicitly, e.g.
> `dub build :cli-frontend --compiler=/path/to/ldc2-1.41.0/bin/ldc2`.
> GDC won't compile this code (the cryptography library uses SIMD instructions
> GDC can't emit yet).

### OpenSUSE Tumbleweed:

1. Install the dependencies:
   `sudo zypper in gcc dmd dub libharfbuzz-gobject0 libadwaita libphobos2-0_* libimobiledevice-1_0-6 git`
2. Clone this repository:
   `git clone https://github.com/Dadoum/Sideloader`
3. Enter its directory:
   `cd Sideloader`
4. Build Sideloader:
   `dub build`
5. Enter the bin directory:
   `cd bin`
6. Allow Sideloader to run as a program:
   `chmod +x sideloader`
7. Run Sideloader:
   `./sideloader`

### Other distributions:

Install LDC 1.41.0 (an installation script is available on
[dlang.org](https://dlang.org/), or grab it from the
[LDC releases page](https://github.com/ldc-developers/ldc/releases/tag/v1.41.0)).
This is the pinned, supported compiler — see the note above; LDC 1.42.x currently
ICEs on this project. GNU D compiler won't compile that code either (the
cryptography library makes use of SIMD instructions that cannot be compiled by
GDC yet).

## How it works?

It works by fetching an iOS development certificate as Xcode would do if you were
developing your own iOS application[^1] and use it to deploy a third party application.

It does not require any Mac or Windows computer, nor any Apple software to be
installed to work. It is just requiring `libimobiledevice` and `libplist`.

It is still requiring you to have an Apple account (which will play the role of the
app developer to Apple), you can use any account for that, don't need to use your actual
Apple ID used with your phone (I recommend making a burner Apple account, see SideStore 
wiki to have easy ways to do that, or on Linux, I'd recommend installing Apple Music on 
Waydroid).

**Your credentials are only ever sent to Apple servers, and you can easily verify this!**\
In general, never trust anyone to handle your credentials, even more if it is in a
closed-source obfuscated application (as-if there were something to hide there ^^).

[^1]: You may wonder if that would allow full iOS application development on Linux, and
the answer is yes! You can compile a native iOS app on Linux with
[theos](https://theos.dev), and then package it into an ipa with `PACKAGE_FORMAT = ipa` to
eventually install it with Sideloader on a real device (or maybe even an emulated one
in the future!) and debug it (with `idevicedebug` or remote `lldb`). _(TODO: add an option
to add the entitlement for debugging)_

## Remote anisette servers

To talk to Apple's GrandSlam servers, Sideloader has to attach a set of
device/identity ("anisette") headers to every request. By default it produces
them **locally**, by emulating Apple's provisioning with native libraries it
scrapes from the Apple Music APK. That works without any external service, but
requires downloading those Android libraries and provisioning a machine.

Alternatively, you can point Sideloader at a **remote anisette server** with:

```sh
sideloader --anisette-server https://your-anisette-server.example/ <command>
```

The URL is **persisted** as the new default, so subsequent runs reuse it without
the flag. When a remote server is configured, Sideloader skips the local Android
library download and ADI provisioning entirely. Pass an empty value or edit
`state.json` to go back to local emulation.

This is compatible with both **anisette-v1** and **anisette-v3** servers (the
`GET /` headers endpoint they both expose), for example
[Dadoum/anisette-v3-server](https://github.com/Dadoum/anisette-v3-server), which
you can self-host. Without `--anisette-server`, Sideloader falls back to local
emulation by scraping the Apple Music APK as described above.

## Set-it-and-forget-it auto-refresh

Free-developer-account apps stop launching once their ~7-day provisioning profile
expires, so they have to be re-signed regularly. Instead of keeping a terminal
open, you can register a background service that periodically runs the refresh
daemon (`sideloader daemon --once`) for you and shows a native desktop
notification when it re-signs an app (or when an app is about to expire but no
device is connected).

```sh
# Log in once so the daemon has stored credentials, then install the service.
sideloader login
sideloader service install                 # default: refresh every 6 hours
sideloader service install --interval 10800 # or pick your own interval (seconds)

sideloader service status                  # is it installed / loaded?
sideloader service uninstall               # disable and remove it (idempotent)
```

The service is per-user and uses the native scheduler of your platform:

- **macOS** — a launchd LaunchAgent at `~/Library/LaunchAgents/dev.dadoum.sideloader.plist`.
- **Linux** — a systemd *user* service + timer (`sideloader-refresh.{service,timer}`) under `~/.config/systemd/user`.
- **Windows** — a Task Scheduler task `Sideloader\Refresh`.

Pass `--dry-run`-style overrides for testing via `--unit-dir` (or the
`SIDELOADER_LAUNCH_AGENTS_DIR` / `SIDELOADER_SYSTEMD_USER_DIR` environment
variables). Use `service install --no-notify` to suppress desktop notifications.
Logs from the scheduled daemon are written under the Sideloader config directory
(`logs/`).

## SideStore companion

[SideStore](https://sidestore.io) refreshes your apps *on-device* (no computer
needed after set-up), but it first needs a pairing file placed inside its app
container. The `sidestore` command is a first-class companion for that:

```sh
# Check whether SideStore is installed on the connected device (and its version).
sideloader sidestore status

# Pair the device and push the pairing file into SideStore in one step.
sideloader sidestore pair                 # `sidestore setup` is an alias
sideloader sidestore pair --udid <UDID>   # if several devices are connected
```

SideStore must already be installed on the device (install it from
<https://sidestore.io> first) — `sidestore status` / `pair` only detect it and
hand it the pairing file; they do not install SideStore. Keep the device unlocked
and trust the computer when prompted; the command waits for you. With no device
connected it prints a clear message and exits non-zero (it never crashes). Once
paired, SideStore can re-sign and refresh your apps on-device.

Anisette: SideStore reads its anisette server from its own in-app settings, so it
cannot be configured from the command line. If you pass `--anisette-server`
(or have a persisted default), `sidestore pair` prints the URL and reminds you to
set the same one in SideStore → Settings.

This functionality is also available through the generic tool runner
(`sideloader tool list` / `tool run <index>`), which the first-class command
reuses under the hood.

## JIT enablement

Some apps (emulators, interpreters, JS engines) need *just-in-time* compilation,
which iOS only allows for a process the kernel has flagged `CS_DEBUGGED`.
Attaching a debugger to a running app sets that flag; `sideloader jit` does this
the same way SideJITServer / StikDebug / Jitterbug do — it connects to the
on-device `com.apple.debugserver`, attaches to the already-running app, then
immediately detaches, leaving the app running with JIT enabled.

```sh
# Enable JIT for an app that is ALREADY RUNNING on the connected device.
sideloader jit com.example.app
sideloader jit com.example.app --udid <UDID>   # if several devices are connected
sideloader jit com.example.app --wifi          # prefer Wi-Fi when both are available
```

Prerequisites (the command reports a clear, actionable error if they are not
met):

* **Developer Mode** must be enabled on the device
  (Settings → Privacy & Security → Developer Mode), and a **Developer Disk
  Image** must be mounted — the `com.apple.debugserver` service only exists then.
  The easiest way to mount it is to connect the device to Xcode once.
* The target **app must already be running** in the foreground — JIT is enabled
  for a *running* process; the command attaches to it, it does not launch it.

You pass the *original* bundle id (or the on-device id); Sideloader resolves the
app's executable name and accepts the mangled `<bundleId>.<teamId>` form it
installs apps under. The command supports the global `--json` flag
(`{"status":"ok","bundleId":…}` on success, `{"error":…}` on failure). With no
device connected it prints a clear message and exits non-zero (it never crashes).

> Note: JIT enablement is currently CLI-only. It is not yet exposed in the GTK
> "Additional tools" menu, because that generic tool runner only hands a tool the
> device — it has no way to ask the user *which* app to target — whereas JIT needs
> a bundle id. Use the `jit` command above.

## Permanent (TrollStore-style) install

A normal install signs the app with a free **developer certificate**, so the app
stops working after ~7 days unless Sideloader re-signs it (see *auto-refresh*
above). On a *vulnerable* iOS version, Sideloader can instead do a **permanent**
install using the CoreTrust signature-validation bug (**CVE-2023-41991**) — the
same exploit TrollStore 2 uses. A permanently-installed app:

* survives past the 7-day expiry,
* needs **no Apple ID** and is never re-signed/refreshed,
* is left alone by the background refresh daemon.

First check whether the connected device supports it:

```sh
sideloader trollstore status
sideloader trollstore status --udid <UDID>   # if several devices are connected
sideloader trollstore status --wifi          # prefer Wi-Fi when both are available
sideloader --json trollstore status          # machine-readable
```

It reports the device's iOS version and whether a permanent install is available,
e.g. `{"iosVersion":"16.6.1","deviceName":"…","bypassable":true,"permanentInstallAvailable":true}`.
With no device connected it prints a clear message and exits non-zero.

If it is available, opt in at install time:

```sh
sideloader install --permanent App.ipa   # alias: --troll
```

`--permanent` runs the normal signing flow and then re-stamps the bundle's
Mach-O binaries with the CoreTrust bypass, and records the app in the registry as
non-expiring (empty expiry + a `permanent` flag) so the refresh daemon never
tries to renew it.

> **Trade-offs / limitations — read before using this:**
> * It only works on **iOS/iPadOS 14.0 – 16.6.1**. The bug is **PATCHED on 16.7
>   and later** (all 17.x / 18.x and the 16.7.x point releases). On a patched or
>   too-old device, `--permanent` is **refused** with a clear error; install
>   normally instead.
> * It relies on a **now-patched exploit**. Updating iOS to 16.7+ removes the
>   vulnerability; you will no longer be able to install *new* permanent apps
>   (already-installed ones generally keep working).
> * A permanent app is **your responsibility** — it is not managed or renewed by
>   Sideloader. Only install software you understand and trust.
> * The version check is a proper dotted-version comparison (`14.0` ≤ v ≤
>   `16.6.1`); the 16.7 RC build (20H18) is treated as patched.

## Sources (AltStore-style catalogs)

`sideloader source` lets you subscribe to AltStore / SideStore *sources* (JSON
catalogs of apps) and install apps from them without manually downloading an
IPA. Subscribed source URLs are persisted in the config directory's `state.json`.

```sh
# Subscribe to a source (validates that it parses; prints its name + app count).
sideloader source add https://apps.altstore.io

# List subscribed sources (add --names to also fetch each source's name).
sideloader source list
sideloader source list --names

# Browse the apps available in your subscribed sources.
sideloader source browse
sideloader source browse --search delta            # filter by name / bundle id
sideloader source browse --source com.example.repo # limit to one source (id/name/URL)

# Install an app by bundle id: downloads its latest IPA, then signs and installs
# it like `sideloader install` (honours --team / --udid / --wifi).
sideloader source install com.rileytestut.Delta
sideloader source install com.example.app --source https://example.com/repo.json

# Unsubscribe (idempotent).
sideloader source remove https://apps.altstore.io
```

Both the legacy single-version source format (top-level `version` /
`downloadURL`) and the newer `versions` array (newest first) are supported; the
"latest" version is the first `versions` entry, or the synthesized legacy one.
`browse` and `list --names` are network-dependent and skip unreachable sources
with a warning. All sub-commands support the global `--json` flag for scripting.

If a bundle id is offered by several subscribed sources, `source install` uses
the first match and warns you; pass `--source` to disambiguate.

## Features

- Sideload
- Sign IPAs
- Set-up SideStore's pairing file
- Enable JIT for a running app (`sideloader jit <bundle-id>`)
- Permanent (TrollStore-style) install on vulnerable iOS (`sideloader trollstore status`, `sideloader install --permanent`)
- Manage App IDs and certificates for free developer accounts.
- iOS version range is unknown. 32-bit support is untested. Please report any issue here!!

## Acknowledgements and references

- [People on this thread](https://github.com/horrorho/InflatableDonkey/issues/87): first
cues on the authentication systems for both machines and accounts.
- All the people in the SideStore team: testing, help on the machine authentication.
- All the people in the AltStore team: help on the account auth, and 2FA (especially 
kabiroberai's code).
- zhlynn: for its code in zsign.
- indygreg: for its code in rcodesign.
- teryx: [their article about code signature](https://medium.com/csit-tech-blog/demystifying-ios-code-signature-309d52c2ff1d).
- Apple Music for Android libraries: giving the opportunity to make all of this work 
neatly!
- Apple's AuthKit and AuthKitWin: giving me the skeleton of the authentication requests 
directly.
- Probably a lot of people I missed!

## If you like my software, consider starring or even better: sponsoring me :)

In late 2019, Cydia Impactor stopped working, and the underlying reason also affected
some of my personal projects at the time. At this time, I decided to start the development
of an alternative. I had no experience in reverse-engineering, or even just making complex
request for authentication on a server. Making this project made me a better developer,
but this was not easy to do. 

While most Cydia Impactor alternatives benefited of some Apple software available on
macOS or Windows, (and thus were able to hijack their libraries and reproduce their
behaviour), Apple never released anything targeting the end-user on Linux.

I took 2 years to find a way to overcome the problem that encountered Cydia Impactor
without resorting to reimplementing the full Windows API. I dedicated a lot of work
on this software (alongside my studies). 

That is why I am asking you - if you enjoyed my software and if you can afford it, to 
give me a small tip via [GitHub Sponsors](https://github.com/sponsors/Dadoum).
