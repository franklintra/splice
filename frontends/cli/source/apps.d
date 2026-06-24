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
import std.array : array, join;
import std.conv : to;
import std.datetime : Clock, DateTime, dur, Duration, SysTime;
import std.format : format;
import std.json : JSONValue;
import std.stdio;

import slf4d;

import argparse;
import progress;

import imobiledevice;

import app.persistence;
import app.session : SideloaderSession;
import app.timeutil : formatExpiryCountdown, parseExpiry;

import sideload.refresh;

import cli_frontend;
import jsonout;
import ui;

// ---------------------------------------------------------------------------
// JSON shapes (issue #15)
// ---------------------------------------------------------------------------

/**
 * Builds the `--json` object for one installed app (pure; unittested below).
 *
 * Shape: `{bundleId, appName, teamId, expiryDate, enabled, expiresIn}` where
 * `expiresIn` is the same human countdown string the text view shows. `now` is
 * threaded in so the rendering is deterministic and testable.
 */
JSONValue installedAppToJSON(InstalledApp app, SysTime now)
{
    return JSONValue([
        "bundleId":   JSONValue(app.bundleId),
        "appName":    JSONValue(app.appName.length ? app.appName : app.bundleId),
        "teamId":     JSONValue(app.teamId),
        "expiryDate": JSONValue(app.expiryDate),
        "enabled":    JSONValue(app.enabled),
        "expiresIn":  JSONValue(formatExpiryCountdown(parseExpiry(app.expiryDate), now)),
    ]);
}

// Expiry countdown formatting now lives in the core (`app.timeutil`) so the GTK
// app-management UI (#14) can share the exact same rendering. It is imported
// above; this frontend just consumes `formatExpiryCountdown` / `parseExpiry`.

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
            if (g_jsonOutput) {
                printJson(JSONValue([
                    "status":    JSONValue("ok"),
                    "refreshed": JSONValue(0),
                    "failed":    JSONValue(0),
                    "skipped":   JSONValue(0),
                ]));
            } else {
                note("No apps are due for refresh.");
            }
            return 0;
        }

        size_t refreshed, failed, skipped;
        foreach (ref app; targets) {
            // In --json mode suppress the human progress bar (it writes to
            // stdout); the structured summary is printed once at the end.
            Bar progressBar = g_jsonOutput ? null : new Bar();
            string message;
            if (progressBar !is null)
                progressBar.message = () => message;
            scope(exit) if (progressBar !is null) progressBar.finish();

            auto result = refreshApp(configurationPath, session, device, app, (progress, action) {
                message = action;
                if (progressBar !is null) {
                    progressBar.index = cast(int)(progress * 100);
                    progressBar.update();
                }
            });

            final switch (result) {
                case RefreshResult.refreshed: refreshed++; break;
                case RefreshResult.failed:    failed++;    break;
                case RefreshResult.skipped:   skipped++;   break;
            }
        }

        if (g_jsonOutput) {
            printJson(JSONValue([
                "status":    JSONValue(failed > 0 ? "error" : "ok"),
                "refreshed": JSONValue(refreshed),
                "failed":    JSONValue(failed),
                "skipped":   JSONValue(skipped),
            ]));
        } else {
            writeln();
            string[] parts = [dot(refreshed.to!string ~ " refreshed", Theme.ok)];
            if (failed)  parts ~= dot(failed.to!string ~ " failed", Theme.danger);
            if (skipped) parts ~= dot(skipped.to!string ~ " skipped", Theme.muted);
            writeln("  " ~ parts.join("   "));
        }
        return failed > 0 ? 1 : 0;
    }
}

// ---------------------------------------------------------------------------
// `list`
// ---------------------------------------------------------------------------

@(Command("list").Description("List installed apps recorded by Splice, with an expiry countdown."))
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

        // Optional, non-fatal device cross-check.
        bool[string] onDevice;
        bool haveDeviceInfo = false;
        if (verify) {
            haveDeviceInfo = collectOnDeviceBundleIds(onDevice);
        }

        auto now = Clock.currTime();

        // --json: emit `{"apps":[...]}` (empty array when the registry is empty),
        // so scripts always get a stable, parseable document.
        if (g_jsonOutput) {
            JSONValue[] apps;
            foreach (app; registry.apps) {
                auto obj = installedAppToJSON(app, now);
                if (verify && haveDeviceInfo) {
                    bool present = (app.bundleId in onDevice) !is null
                        || ((app.bundleId ~ "." ~ app.teamId) in onDevice) !is null;
                    obj["onDevice"] = JSONValue(present);
                }
                apps ~= obj;
            }
            printJson(JSONValue(["apps": JSONValue(apps)]));
            return 0;
        }

        if (registry.apps.length == 0) {
            note("No apps are installed (the registry is empty).");
            return 0;
        }

        header("Installed apps");
        writefln("  %s recorded in the registry\n",
                 paint(registry.apps.length.to!string, Theme.bold));

        auto table = Table([
            Column("APP"),
            Column("BUNDLE ID"),
            Column("TEAM"),
            Column("STATUS"),
        ]);

        size_t healthy, expiring, expired, disabled;
        foreach (app; registry.apps) {
            auto expiry = parseExpiry(app.expiryDate);
            string countdown = formatExpiryCountdown(expiry, now);
            string name = app.appName.length ? app.appName : app.bundleId;

            // Severity is computed from the real durations (not the rendered
            // string) so the colour and the summary buckets stay in sync.
            Theme sev;
            if (expiry == SysTime.init)            sev = Theme.muted;
            else if (expiry <= now)                sev = Theme.danger;
            else if (expiry - now < dur!"hours"(48)) sev = Theme.warn;
            else                                   sev = Theme.ok;

            string statusCell = dot(countdown, sev);

            if (!app.enabled) {
                statusCell ~= paint("  disabled", Theme.danger);
                disabled++;
            } else if (expiry == SysTime.init) {
                // unknown expiry — leave it out of the health buckets.
            } else if (expiry <= now)                  expired++;
            else if (expiry - now < dur!"hours"(48))   expiring++;
            else                                       healthy++;

            if (verify && haveDeviceInfo) {
                // On-device id is mangled as <bundleId>.<teamId>; accept either.
                bool present = (app.bundleId in onDevice) !is null
                    || ((app.bundleId ~ "." ~ app.teamId) in onDevice) !is null;
                statusCell ~= present ? paint("  ✓ on device", Theme.muted)
                                      : paint("  · not on device", Theme.dim);
            }

            table.add(
                paint(name, Theme.accent, Theme.bold),
                paint(app.bundleId, Theme.muted),
                app.teamId.length ? app.teamId : "?",
                statusCell,
            );
        }
        table.render();

        // Compact health summary — only the non-zero buckets.
        string[] summary;
        if (healthy)  summary ~= dot(healthy.to!string ~ " healthy", Theme.ok);
        if (expiring) summary ~= dot(expiring.to!string ~ " expiring", Theme.warn);
        if (expired)  summary ~= dot(expired.to!string ~ " expired", Theme.danger);
        if (disabled) summary ~= dot(disabled.to!string ~ " disabled", Theme.danger);
        if (summary.length) {
            writeln();
            writeln("  " ~ summary.join("   "));
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

            log.debugF!"Uninstalling `%s` from the device..."(onDeviceId);
            client.uninstall(onDeviceId);
            log.debugF!"Uninstalled `%s`."(onDeviceId);
        } catch (Exception e) {
            log.errorF!"Failed to uninstall `%s`: %s"(onDeviceId, e.msg);
            return 1;
        }

        if (keepRegistry) {
            success("Uninstalled from the device (registry record kept).");
            return 0;
        }

        if (known) {
            registry.remove(bundleId);
            saveInstalledRegistry(configurationPath, registry);
            // Clean up the cached source IPA we kept around for refreshes (only
            // ones under our `source-ipas` cache; never user-supplied IPAs).
            if (record.sourceIpaPath.length) {
                import std.algorithm.searching : canFind;
                import std.file : exists, remove;
                if (record.sourceIpaPath.canFind("source-ipas")) {
                    try { if (exists(record.sourceIpaPath)) remove(record.sourceIpaPath); }
                    catch (Exception) {}
                }
            }
            success(format!"Uninstalled `%s` and removed it from the registry."(bundleId));
        } else {
            success(format!"Uninstalled `%s` (was not in the registry)."(bundleId));
        }
        return 0;
    }
}

// The pure expiry-countdown unittest moved with the helper into
// `source/app/timeutil.d`.

unittest
{
    // installedAppToJSON builds the documented shape, falls back to the bundle id
    // for a missing app name, and renders a deterministic countdown.
    auto now = SysTime(DateTime(2026, 1, 1, 0, 0, 0));

    InstalledApp app;
    app.bundleId = "com.example.app";
    app.teamId = "ABCDE12345";
    app.appName = "Example";
    app.expiryDate = (now + dur!"days"(3) + dur!"hours"(4)).toISOExtString();
    app.enabled = false;

    auto j = installedAppToJSON(app, now);
    assert(j["bundleId"].str == "com.example.app");
    assert(j["appName"].str == "Example");
    assert(j["teamId"].str == "ABCDE12345");
    assert(j["enabled"].boolean == false);
    assert(j["expiresIn"].str == "expires in 3d 4h");

    // Missing app name falls back to the bundle id.
    InstalledApp noName;
    noName.bundleId = "com.example.noname";
    noName.appName = "";
    auto j2 = installedAppToJSON(noName, now);
    assert(j2["appName"].str == "com.example.noname");
}
