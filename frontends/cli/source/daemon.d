module daemon;

import core.thread : Thread;

import std.datetime : Clock, dur, Duration;
import std.stdio;

import slf4d;

import argparse;

import imobiledevice;

import app.session : SideloaderSession;

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

        auto summary = refreshDueApps(session.configurationPath, session, devices, policy, Clock.currTime());
        logSummary(summary);
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
