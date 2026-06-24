module apps;

/**
 * Installed-app management CLI commands (issue #10):
 *   - `refresh`   : re-sign apps in the registry before their profile expires;
 *   - `list`      : show the installed-apps registry with an expiry countdown;
 *   - `uninstall` : remove an app from the device and (by default) the registry.
 *
 * `list` (the registry view) and `uninstall`'s registry removal do NOT need an
 * Apple login — they operate on local state / the device only. `refresh` DOES
 * need a login, because it re-registers and re-signs the app.
 */

import std.algorithm : filter, map;
import std.array : array;
import std.datetime : Clock, dur, Duration, SysTime;
import std.format : format;
import std.stdio;

import slf4d;

import argparse;
import progress;

import imobiledevice;

import app.persistence;
import app.session : SideloaderSession;

import sideload.refresh;

import cli_frontend;

// ---------------------------------------------------------------------------
// Expiry countdown formatting (PURE, unit-tested).
// ---------------------------------------------------------------------------

/**
 * Formats a human-readable expiry countdown for an app, relative to `now`.
 *
 * Examples (for the largest two non-zero units):
 *   - future:  "expires in 3d 4h"
 *   - soon:    "expires in 45m"
 *   - expired: "EXPIRED 2d ago"
 *
 * `SysTime.init` (an unknown/unparseable expiry) yields "unknown". Pure and
 * offline so it can be unit-tested without a clock or device.
 */
string formatExpiryCountdown(SysTime expiry, SysTime now)
{
    if (expiry == SysTime.init)
        return "unknown";

    if (expiry <= now)
        return "EXPIRED " ~ humanizeDuration(now - expiry) ~ " ago";

    return "expires in " ~ humanizeDuration(expiry - now);
}

/**
 * Renders a positive duration as up to two coarse units (e.g. "3d 4h", "5h 12m",
 * "45m", "30s"). Collapses to "0s" for a non-positive duration. Pure.
 */
private string humanizeDuration(Duration d)
{
    if (d <= Duration.zero)
        return "0s";

    long totalSeconds = d.total!"seconds";
    long days = totalSeconds / 86_400;
    long hours = (totalSeconds % 86_400) / 3_600;
    long minutes = (totalSeconds % 3_600) / 60;
    long seconds = totalSeconds % 60;

    string[] parts;
    if (days > 0) parts ~= format!"%dd"(days);
    if (hours > 0) parts ~= format!"%dh"(hours);
    if (days == 0 && minutes > 0) parts ~= format!"%dm"(minutes);
    if (days == 0 && hours == 0 && seconds > 0) parts ~= format!"%ds"(seconds);

    // Keep at most the two largest units; never return an empty string.
    if (parts.length == 0)
        return "0s";
    if (parts.length > 2)
        parts = parts[0 .. 2];

    string result;
    foreach (i, p; parts) {
        if (i) result ~= " ";
        result ~= p;
    }
    return result;
}

/// Parses an ISO-8601 expiry into a `SysTime`, returning `SysTime.init` when the
/// string is empty or unparseable (callers treat that as "unknown").
private SysTime parseExpiry(string iso)
{
    if (iso.length == 0)
        return SysTime.init;
    try {
        return SysTime.fromISOExtString(iso);
    } catch (Exception) {
        return SysTime.init;
    }
}

// ---------------------------------------------------------------------------
// `refresh`
// ---------------------------------------------------------------------------

@(Command("refresh").Description("Re-sign installed apps before their provisioning profile expires."))
struct RefreshCommand
{
    mixin LoginCommand;

    @(NamedArgument("all").Description("Refresh all enabled apps that are due (default). With --force, refresh every enabled app."))
    bool all = false;

    @(NamedArgument("bundle").Description("Refresh only this bundle identifier (must be in the registry)."))
    string bundle = null;

    @(NamedArgument("force").Description("Ignore expiry and refresh regardless of how far away it is."))
    bool force = false;

    @(NamedArgument("threshold").Description("With --all, refresh an app when its expiry is within this many hours (default 48)."))
    uint threshold = 48;

    @(NamedArgument("udid").Description("UDID of the device (if multiple are available)."))
    string udid = null;

    @(NamedArgument("wifi", "prefer-network").Description("Prefer connecting over Wi-Fi when the device is reachable both over USB and Wi-Fi (requires a prior USB pairing with Wi-Fi sync enabled)."))
    bool wifi = false;

    int opCall()
    {
        auto log = getLogger();

        if (bundle.length && all) {
            log.error("Choose either --bundle or --all, not both.");
            return 1;
        }

        // Refresh re-signs, so an Apple login is required.
        auto session = makeSession();
        if (!session)
            return 1;
        string configurationPath = session.configurationPath;

        string chosenUdid, transportLabel;
        auto device = selectConnectedDevice(udid, wifi, chosenUdid, transportLabel);
        if (!device)
            return 1;

        auto registry = loadInstalledRegistry(configurationPath);
        auto now = Clock.currTime();

        InstalledApp[] targets;
        if (bundle.length) {
            InstalledApp found;
            if (!registry.query(bundle, found)) {
                log.errorF!"No installed app with bundle id `%s` is recorded in the registry."(bundle);
                return 1;
            }
            targets = [found];
        } else if (force) {
            // --force (with or without --all): refresh every ENABLED app regardless of expiry.
            targets = registry.apps.filter!(a => a.enabled).array();
        } else {
            // Default and plain --all: only the enabled apps that are due.
            targets = appsDueForRefresh(registry.apps, now, dur!"hours"(threshold));
        }

        if (targets.length == 0) {
            writeln("No apps are due for refresh.");
            return 0;
        }

        size_t refreshed, failed, skipped;
        foreach (ref app; targets) {
            Bar progressBar = new Bar();
            string message;
            progressBar.message = () => message;
            scope(exit) progressBar.finish();

            auto result = refreshApp(configurationPath, session, device, app, (progress, action) {
                message = action;
                progressBar.index = cast(int)(progress * 100);
                progressBar.update();
            });

            final switch (result) {
                case RefreshResult.refreshed: refreshed++; break;
                case RefreshResult.failed:    failed++;    break;
                case RefreshResult.skipped:   skipped++;   break;
            }
        }

        writefln!"Refresh summary: %d refreshed, %d failed, %d skipped."(refreshed, failed, skipped);
        return failed > 0 ? 1 : 0;
    }
}

// ---------------------------------------------------------------------------
// `list`
// ---------------------------------------------------------------------------

@(Command("list").Description("List installed apps recorded by Sideloader, with an expiry countdown."))
struct ListCommand
{
    @(NamedArgument("installed").Description("List installed apps (the default and only view today)."))
    bool installed = false;

    @(NamedArgument("verify").Description("Best-effort: cross-check the registry against the apps actually present on a connected device."))
    bool verify = false;

    @(NamedArgument("udid").Description("UDID of the device to verify against (if multiple are available)."))
    string udid = null;

    int opCall()
    {
        auto log = getLogger();

        // The registry view is purely local: no login, no device needed.
        string configurationPath = systemConfigurationPath();
        auto registry = loadInstalledRegistry(configurationPath);

        if (registry.apps.length == 0) {
            writeln("No apps are installed (the registry is empty).");
            return 0;
        }

        // Optional, non-fatal device cross-check.
        bool[string] onDevice;
        bool haveDeviceInfo = false;
        if (verify) {
            haveDeviceInfo = collectOnDeviceBundleIds(onDevice);
        }

        auto now = Clock.currTime();
        writefln!"%d installed app(s):"(registry.apps.length);
        foreach (app; registry.apps) {
            string countdown = formatExpiryCountdown(parseExpiry(app.expiryDate), now);
            string name = app.appName.length ? app.appName : app.bundleId;

            string suffix;
            if (!app.enabled)
                suffix ~= " [disabled]";
            if (verify && haveDeviceInfo) {
                // On-device id is mangled as <bundleId>.<teamId>; accept either.
                bool present = (app.bundleId in onDevice) !is null
                    || ((app.bundleId ~ "." ~ app.teamId) in onDevice) !is null;
                suffix ~= present ? " [on device]" : " [not on device]";
            }

            writefln!"  %s (%s)\n      team: %s | %s%s"(
                name, app.bundleId, app.teamId.length ? app.teamId : "?", countdown, suffix);
        }

        return 0;
    }

    /**
     * Best-effort device browse: fills `onDevice` with the bundle identifiers of
     * the user apps present on the selected device. Returns false (and logs a
     * warning) when no device is reachable or the browse fails — the registry
     * view must still work without a device.
     */
    private bool collectOnDeviceBundleIds(out bool[string] onDevice)
    {
        import plist;

        auto log = getLogger();
        try {
            string chosenUdid, transportLabel;
            auto device = selectConnectedDevice(udid, false, chosenUdid, transportLabel);
            if (!device) {
                log.warn("Skipping device verification: no device selected.");
                return false;
            }

            scope lockdown = new LockdowndClient(device, "sideloader.list");
            scope service = lockdown.startService("com.apple.mobile.installation_proxy");
            scope client = new InstallationProxyClient(device, service);

            auto options = dict("ApplicationType", "User");
            auto result = client.browse(options);

            foreach (entry; result.array()) {
                auto appDict = entry.dict();
                if (auto idEntry = "CFBundleIdentifier" in appDict) {
                    onDevice[idEntry.str().native()] = true;
                }
            }
            return true;
        } catch (Exception e) {
            log.warnF!"Could not browse apps on the device: %s"(e.msg);
            return false;
        }
    }
}

// ---------------------------------------------------------------------------
// `uninstall`
// ---------------------------------------------------------------------------

@(Command("uninstall").Description("Uninstall an app from the device and remove it from the registry."))
struct UninstallCommand
{
    @(PositionalArgument(0, "bundle id").Description("The (original) bundle identifier of the app to uninstall."))
    string bundleId;

    @(NamedArgument("udid").Description("UDID of the device (if multiple are available)."))
    string udid = null;

    @(NamedArgument("keep-registry").Description("Uninstall from the device but keep the registry record."))
    bool keepRegistry = false;

    int opCall()
    {
        auto log = getLogger();

        // No Apple login required: uninstall talks to the device only, and the
        // registry edit is local.
        string configurationPath = systemConfigurationPath();
        auto registry = loadInstalledRegistry(configurationPath);

        // The registry stores the ORIGINAL bundle id; the on-device id is mangled
        // as <bundleId>.<teamId> (see sideloadFull's `mainAppIdStr`). If we know
        // the team from the registry, target the mangled id; otherwise fall back
        // to the id the user typed (which may already be the mangled form).
        InstalledApp record;
        bool known = registry.query(bundleId, record);
        string onDeviceId = (known && record.teamId.length)
            ? bundleId ~ "." ~ record.teamId
            : bundleId;

        string chosenUdid, transportLabel;
        auto device = selectConnectedDevice(udid, false, chosenUdid, transportLabel);
        if (!device)
            return 1;

        try {
            scope lockdown = new LockdowndClient(device, "sideloader.uninstall");
            scope service = lockdown.startService("com.apple.mobile.installation_proxy");
            scope client = new InstallationProxyClient(device, service);

            log.infoF!"Uninstalling `%s` from the device..."(onDeviceId);
            client.uninstall(onDeviceId);
            log.infoF!"Uninstalled `%s`."(onDeviceId);
        } catch (Exception e) {
            log.errorF!"Failed to uninstall `%s`: %s"(onDeviceId, e.msg);
            return 1;
        }

        if (keepRegistry) {
            writeln("App uninstalled from the device (registry record kept).");
            return 0;
        }

        if (known) {
            registry.remove(bundleId);
            saveInstalledRegistry(configurationPath, registry);
            writefln!"App `%s` uninstalled and removed from the registry."(bundleId);
        } else {
            writefln!"App `%s` uninstalled (was not present in the registry)."(bundleId);
        }
        return 0;
    }
}

// ---------------------------------------------------------------------------
// unittests: pure expiry-countdown formatting
// ---------------------------------------------------------------------------

unittest {
    auto now = SysTime.fromISOExtString("2026-06-24T12:00:00Z");

    // Unknown expiry.
    assert(formatExpiryCountdown(SysTime.init, now) == "unknown");

    // Future: days + hours (two largest units).
    auto inThreeDays = now + dur!"days"(3) + dur!"hours"(4) + dur!"minutes"(30);
    assert(formatExpiryCountdown(inThreeDays, now) == "expires in 3d 4h");

    // Soon: minutes only.
    auto in45min = now + dur!"minutes"(45);
    assert(formatExpiryCountdown(in45min, now) == "expires in 45m");

    // Soon: hours + minutes.
    auto in5h12m = now + dur!"hours"(5) + dur!"minutes"(12);
    assert(formatExpiryCountdown(in5h12m, now) == "expires in 5h 12m");

    // Expired in the past.
    auto twoDaysAgo = now - dur!"days"(2) - dur!"hours"(6);
    assert(formatExpiryCountdown(twoDaysAgo, now) == "EXPIRED 2d 6h ago");

    // Exactly now counts as expired.
    assert(formatExpiryCountdown(now, now) == "EXPIRED 0s ago");

    // Seconds-only future.
    auto in30s = now + dur!"seconds"(30);
    assert(formatExpiryCountdown(in30s, now) == "expires in 30s");
}
