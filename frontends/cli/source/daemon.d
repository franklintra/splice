module daemon;

import core.thread : Thread;

import std.datetime : Clock, dur, Duration, SysTime;
import std.stdio;

import slf4d;

import argparse;

import imobiledevice;

import app.session : SideloaderSession;
import app.notifications : notify;

import sideload.refresh;

import cli_frontend;

@(Command("daemon").Description("Watch connected devices and re-sign apps before they expire."))
struct DaemonCommand
{
    mixin LoginCommand;

    @(NamedArgument("once").Description("Do a single refresh pass and exit (used by the service unit, and offline-testable)."))
    bool once = false;

    @(NamedArgument("interval").Description("Poll interval in seconds for the looping mode (default 3600)."))
    uint interval = 3600;

    @(NamedArgument("threshold").Description("Refresh an app when its expiry is within this many hours (default 48)."))
    uint threshold = 48;

    @(NamedArgument("no-notify").Description("Suppress native desktop notifications about refresh outcomes."))
    bool noNotify = false;

    int opCall()
    {
        auto log = getLogger();

        // Non-interactive by design: the daemon relies on credentials saved by a
        // prior `sideloader login` (issue #5/#6). Leaving `interactive` false
        // means makeSession() will NOT prompt on stdin; if nothing is stored it
        // returns null and we tell the user to log in first.
        auto session = makeSession();
        if (!session) {
            log.error("The daemon could not log in. Run `sideloader login` once to store credentials, then start the daemon again.");
            return 1;
        }

        RefreshPolicy policy;
        policy.threshold = dur!"hours"(threshold);
        policy.pollInterval = dur!"seconds"(interval);

        if (once) {
            runOnce(session, policy);
            return 0;
        }

        return runLoop(session, policy);
    }

    /// Enumerates connected devices and performs a single refresh pass, logging
    /// the resulting summary. Returns nothing — a pass with no device is a valid
    /// "nothing to do" outcome, not an error.
    private void runOnce(SideloaderSession session, RefreshPolicy policy)
    {
        auto log = getLogger();

        // USB device discovery is sufficient for #9.
        // TODO(#13): Wi-Fi / usbmuxd-network device discovery would be merged in
        // here (e.g. by also enumerating IDEVICE_LOOKUP_NETWORK devices) so the
        // daemon can refresh devices that are only reachable over the network.
        auto deviceInfos = iDevice.deviceList();

        iDevice[] devices;
        foreach (info; deviceInfos) {
            try {
                devices ~= new iDevice(info.udid);
            } catch (Exception e) {
                log.warnF!"Could not connect to device %s: %s"(info.udid, e.msg);
            }
        }

        if (devices.length == 0) {
            log.info("No device connected; nothing to refresh this pass.");
        } else {
            log.infoF!"%d device(s) connected."(devices.length);
        }

        auto now = Clock.currTime();

        // Collect per-app notification events as the pass runs, then emit a
        // tasteful, summarised set of desktop notifications at the end (rather
        // than one-per-app, which would spam when many apps are due).
        import app.persistence : InstalledApp;
        string[] refreshedNames;
        string[] failedNames;
        string[] expiringNames; // due-but-no-device, with a days-left hint

        void onResult(ref InstalledApp app, RefreshResult result) {
            string name = app.appName.length ? app.appName : app.bundleId;
            final switch (result) {
                case RefreshResult.refreshed:
                    refreshedNames ~= name;
                    break;
                case RefreshResult.failed:
                    failedNames ~= name;
                    break;
                case RefreshResult.skipped:
                    // When skipped because no device is connected, warn that the
                    // app is approaching expiry. We can compute a days-left hint
                    // from the recorded expiry date.
                    if (summaryNoDevice) {
                        expiringNames ~= name ~ expiryHint(app.expiryDate, now);
                    }
                    break;
            }
        }

        // The only path that reports apps as `skipped` via `onResult` is the
        // no-device branch, so we can set this up-front: when no device is
        // connected, every skip is a "due but couldn't refresh" expiry warning.
        summaryNoDevice = devices.length == 0;

        auto summary = refreshDueApps(session.configurationPath, session, devices, policy, now, &onResult);
        logSummary(summary);

        if (!noNotify)
            emitNotifications(refreshedNames, failedNames, expiringNames);
    }

    /// Set just before the refresh pass so the `onResult` closure can tell the
    /// "no device" case apart without re-reading the summary mid-pass.
    private bool summaryNoDevice = false;

    /// Builds a " (expires in N days)" suffix from an ISO-8601 expiry date.
    /// Returns "" when the date is unknown/unparseable.
    private string expiryHint(string expiryIso, SysTime now) {
        import std.format : format;
        if (expiryIso.length == 0)
            return "";
        try {
            auto expiry = SysTime.fromISOExtString(expiryIso);
            long days = (expiry - now).total!"days";
            if (days < 0)
                return " (expired)";
            return format!" (expires in %d day%s)"(days, days == 1 ? "" : "s");
        } catch (Exception) {
            return "";
        }
    }

    /// Emits a small, summarised set of desktop notifications for the pass.
    private void emitNotifications(string[] refreshed, string[] failed, string[] expiring) {
        import std.array : join;
        import std.format : format;

        // Refreshed: one line if a couple, summarised if many.
        if (refreshed.length == 1)
            notify("Sideloader", format!"Refreshed %s"(refreshed[0]));
        else if (refreshed.length > 1)
            notify("Sideloader", format!"Refreshed %d apps: %s"(refreshed.length, summarise(refreshed)));

        if (failed.length == 1)
            notify("Sideloader: refresh failed", format!"Failed to refresh %s"(failed[0]));
        else if (failed.length > 1)
            notify("Sideloader: refresh failed", format!"Failed to refresh %d apps: %s"(failed.length, summarise(failed)));

        if (expiring.length == 1)
            notify("Sideloader: connect your device", format!"%s — no device connected to refresh."(expiring[0]));
        else if (expiring.length > 1)
            notify("Sideloader: connect your device", format!"%d apps need refreshing but no device is connected: %s"(expiring.length, summarise(expiring)));
    }

    /// Joins up to 3 names, appending "and N more" beyond that, to stay tasteful.
    private string summarise(string[] names) {
        import std.array : join;
        import std.format : format;
        if (names.length <= 3)
            return names.join(", ");
        return names[0 .. 3].join(", ") ~ format!" and %d more"(names.length - 3);
    }

    /// Looping mode: repeatedly enumerate devices, refresh, then sleep the poll
    /// interval. Runs until interrupted (Ctrl-C). A failed pass is logged and the
    /// loop continues rather than aborting the daemon.
    private int runLoop(SideloaderSession session, RefreshPolicy policy)
    {
        auto log = getLogger();
        log.infoF!"Starting refresh daemon (poll every %s, refresh within %s of expiry). Press Ctrl-C to stop."(
            policy.pollInterval, policy.threshold);

        while (true) {
            log.info("Refresh cycle starting...");
            try {
                runOnce(session, policy);
            } catch (Exception e) {
                log.errorF!"Refresh cycle failed: %s"(e.msg);
            }
            log.infoF!"Refresh cycle complete; sleeping %s."(policy.pollInterval);
            Thread.sleep(policy.pollInterval);
        }
    }

    private void logSummary(RefreshSummary summary)
    {
        auto log = getLogger();
        if (summary.noDevice) {
            log.infoF!"Refresh summary: %d app(s) known, %d due, but no device connected (%d skipped)."(
                summary.totalApps, summary.dueApps, summary.skipped);
            return;
        }
        log.infoF!"Refresh summary: %d app(s) known, %d due — %d refreshed, %d failed, %d skipped."(
            summary.totalApps, summary.dueApps, summary.refreshed, summary.failed, summary.skipped);
    }
}
