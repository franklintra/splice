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
  team           Manage teams.
  tool           Run Sideloader's tools.
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

## Features

- Sideload
- Sign IPAs
- Set-up SideStore's pairing file
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
