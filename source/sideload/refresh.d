module sideload.refresh;

/**
 * Reusable refresh core for the background daemon (#9) and the future
 * `refresh`/`list`/`uninstall` CLI commands (#10).
 *
 * AltServer keeps free-developer-account apps alive by periodically re-signing
 * and reinstalling them before their (~7 day) provisioning profile expires.
 * Sideloader does the same: the installed-apps registry (`app.persistence`)
 * already records each app's `expiryDate` and the `sourceIpaPath` it was
 * installed from, and `sideload.sideloadFull` already performs a complete
 * re-register + re-sign + reinstall and refreshes the registry's `expiryDate`.
 *
 * This module ties those together:
 *   - `appsDueForRefresh` is a PURE function (offline, unit-tested) that decides
 *     which enabled apps are within the refresh window or already expired;
 *   - `refreshApp` refreshes a single app on a single device (non-fatal: catches
 *     and reports failures so a loop can apply backoff);
 *   - `refreshDueApps` is a single-pass orchestrator that loads the registry,
 *     computes the due apps, and refreshes each on a connected device with
 *     retry/backoff, returning a `RefreshSummary`.
 *
 * Only USB discovery is supported here; Wi-Fi/usbmuxd-network discovery is #13.
 */

import core.thread : Thread;

import std.algorithm.iteration : filter, map;
import std.array : array;
import std.datetime : SysTime, Duration, dur, Clock;
import file = std.file;

import slf4d;

import imobiledevice;

import server.developersession;

import app.persistence;
import app.session : SideloaderSession;

import sideload;
import sideload.application;

/**
 * Tunable policy for the background refresh.
 *
 * Defaults mirror AltServer-style behaviour for free accounts: a ~7 day profile
 * lifetime means we want to re-sign comfortably before expiry. `threshold` is
 * the "refresh when expiry is within this window" lookahead; `pollInterval` is
 * how often the looping daemon wakes up to check; `maxRetries`/`backoffBase`
 * govern per-app retry on transient failure.
 */
struct RefreshPolicy {
    /// Refresh an app when its expiry is at or within this window (default 2 days).
    Duration threshold = dur!"hours"(48);
    /// How often the looping daemon re-checks devices (default 1 hour).
    Duration pollInterval = dur!"hours"(1);
    /// Maximum attempts per app within a single pass before giving up.
    uint maxRetries = 3;
    /// Base backoff between retries; attempt N waits `backoffBase * 2^(N-1)`.
    Duration backoffBase = dur!"seconds"(5);
}

/// Outcome of refreshing one app, so the loop can apply backoff and reporting.
enum RefreshResult {
    /// The app was successfully re-signed and reinstalled.
    refreshed,
    /// The app could not be refreshed (e.g. signing/install failure).
    failed,
    /// The app was not refreshed for a benign reason (e.g. missing source IPA).
    skipped,
}

/// Aggregate counts from a single `refreshDueApps` pass.
struct RefreshSummary {
    /// Number of apps the registry knew about at the start of the pass.
    size_t totalApps;
    /// Number of apps that were due (enabled + within threshold/expired).
    size_t dueApps;
    /// Number successfully refreshed this pass.
    size_t refreshed;
    /// Number that failed after exhausting retries.
    size_t failed;
    /// Number skipped (no device, missing IPA, ...).
    size_t skipped;
    /// True when there was no connected device to refresh onto.
    bool noDevice;
}

/**
 * Returns the subset of `apps` that are due for a refresh, as of `now`.
 *
 * An app is due when ALL of:
 *   - it is `enabled` (the daemon must respect the per-app toggle), AND
 *   - its `expiryDate` is empty/unparseable (treated conservatively as due), OR
 *     parseable and at or before `now + threshold` (this also covers an already
 *     expired app, whose expiry is before `now`).
 *
 * Pure and offline: parses ISO-8601 via `SysTime.fromISOExtString` and never
 * contacts a device or Apple, so it is fully unit-testable.
 */
InstalledApp[] appsDueForRefresh(InstalledApp[] apps, SysTime now, Duration threshold) {
    InstalledApp[] due;
    SysTime cutoff = now + threshold;
    foreach (app; apps) {
        if (!app.enabled)
            continue;
        if (app.expiryDate.length == 0) {
            // Unknown expiry: be conservative and refresh.
            due ~= app;
            continue;
        }
        SysTime expiry;
        try {
            expiry = SysTime.fromISOExtString(app.expiryDate);
        } catch (Exception) {
            // Unparseable expiry: also conservative -> due.
            due ~= app;
            continue;
        }
        if (expiry <= cutoff)
            due ~= app;
    }
    return due;
}

/**
 * Refreshes a single installed app on a single device.
 *
 * Verifies the source IPA still exists (skips with a clear warning otherwise),
 * opens it as an `Application`, and calls `sideloadFull` with the app's recorded
 * `teamId`. `sideloadFull` re-registers the App ID, re-signs, reinstalls and
 * updates the registry's `expiryDate` itself, and always runs `cleanup()` on the
 * extraction temp dir.
 *
 * Non-fatal: any exception is caught and logged, and reported back as
 * `RefreshResult.failed` so the caller can apply backoff and continue with other
 * apps rather than aborting the whole pass.
 */
RefreshResult refreshApp(
    string configPath,
    SideloaderSession session,
    iDevice device,
    ref InstalledApp app,
    void delegate(double progress, string action) progress,
) {
    auto log = getLogger();

    if (app.sourceIpaPath.length == 0) {
        log.warnF!"Skipping %s: no source IPA path was recorded at install time."(app.bundleId);
        return RefreshResult.skipped;
    }
    if (!file.exists(app.sourceIpaPath)) {
        log.warnF!"Skipping %s: source IPA `%s` no longer exists."(app.bundleId, app.sourceIpaPath);
        return RefreshResult.skipped;
    }

    DeveloperSession developer = session.developerSession;
    if (developer is null) {
        log.errorF!"Cannot refresh %s: not logged in."(app.bundleId);
        return RefreshResult.failed;
    }

    Application application;
    try {
        application = new Application(app.sourceIpaPath);
    } catch (Exception e) {
        log.warnF!"Skipping %s: could not open source IPA `%s`: %s"(app.bundleId, app.sourceIpaPath, e.msg);
        return RefreshResult.skipped;
    }

    // sideloadFull already runs application.cleanup() via its own scope(exit),
    // but guard against an early throw before it takes ownership.
    scope(failure) application.cleanup();

    try {
        log.infoF!"Refreshing %s (%s)..."(app.appName.length ? app.appName : app.bundleId, app.bundleId);
        sideloadFull(configPath, device, developer, application, progress, false, app.teamId);
        log.infoF!"Refreshed %s."(app.bundleId);
        return RefreshResult.refreshed;
    } catch (Exception e) {
        log.errorF!"Failed to refresh %s: %s"(app.bundleId, e.msg);
        return RefreshResult.failed;
    }
}

/**
 * Single-pass refresh of every due app across the connected devices.
 *
 * Loads the registry, computes the due apps as of `now`, and refreshes each on a
 * connected device (first connected device for now — multi-device targeting can
 * be refined later). Applies a simple exponential backoff between retries up to
 * `policy.maxRetries`. Returns a `RefreshSummary`; with `devices.length == 0` it
 * refreshes nothing and reports `noDevice = true`.
 *
 * The optional `onResult` callback is invoked once per due app with that app and
 * its terminal `RefreshResult`, letting a caller (e.g. the daemon) surface
 * per-app desktop notifications without re-deriving the due set. When there is
 * no connected device, it is invoked with `RefreshResult.skipped` for each due
 * app so callers can warn that those apps will keep ageing toward expiry.
 */
RefreshSummary refreshDueApps(
    string configPath,
    SideloaderSession session,
    iDevice[] devices,
    RefreshPolicy policy,
    SysTime now,
    void delegate(ref InstalledApp app, RefreshResult result) onResult = null,
) {
    auto log = getLogger();
    RefreshSummary summary;

    auto registry = loadInstalledRegistry(configPath);
    summary.totalApps = registry.apps.length;

    auto due = appsDueForRefresh(registry.apps, now, policy.threshold);
    summary.dueApps = due.length;

    if (due.length == 0) {
        log.info("No apps are due for refresh.");
        return summary;
    }

    if (devices.length == 0) {
        log.warnF!"%d app(s) are due for refresh, but no device is connected."(due.length);
        summary.noDevice = true;
        summary.skipped += due.length;
        if (onResult !is null) {
            foreach (ref app; due)
                onResult(app, RefreshResult.skipped);
        }
        return summary;
    }

    // For now refresh every due app on the first connected device. Targeting a
    // specific device (e.g. the one an app is actually installed on) is a future
    // refinement once we record per-app device identity.
    iDevice device = devices[0];

    foreach (ref app; due) {
        RefreshResult result = RefreshResult.failed;
        uint attempts = policy.maxRetries == 0 ? 1 : policy.maxRetries;

        foreach (attempt; 0 .. attempts) {
            result = refreshApp(configPath, session, device, app, (progress, action) {
                log.traceF!"[%s] %.0f%% %s"(app.bundleId, progress * 100, action);
            });

            // Only `failed` is worth retrying; `skipped`/`refreshed` are terminal.
            if (result != RefreshResult.failed)
                break;

            if (attempt + 1 < attempts) {
                Duration wait = backoffDelay(policy.backoffBase, attempt);
                log.warnF!"Retrying %s in %s (attempt %d/%d)..."(app.bundleId, wait, attempt + 2, attempts);
                Thread.sleep(wait);
            }
        }

        final switch (result) {
            case RefreshResult.refreshed:
                summary.refreshed++;
                break;
            case RefreshResult.failed:
                summary.failed++;
                break;
            case RefreshResult.skipped:
                summary.skipped++;
                break;
        }

        if (onResult !is null)
            onResult(app, result);
    }

    return summary;
}

/**
 * Exponential backoff delay for a zero-based retry `attempt`: attempt 0 waits
 * `base`, attempt 1 waits `2*base`, attempt 2 waits `4*base`, ... Pure so the
 * scheduling can be unit-tested.
 */
Duration backoffDelay(Duration base, uint attempt) {
    // base * 2^attempt, capped at attempt 16 to avoid silly multipliers.
    uint shift = attempt > 16 ? 16 : attempt;
    return base * (1L << shift);
}

// ---------------------------------------------------------------------------
// unittests: pure scheduling / backoff logic
// ---------------------------------------------------------------------------

version (unittest) {
    private InstalledApp mkApp(string bundleId, string expiryIso, bool enabled = true) {
        InstalledApp a;
        a.bundleId = bundleId;
        a.teamId = "TEAM1";
        a.expiryDate = expiryIso;
        a.sourceIpaPath = "/some/path.ipa";
        a.appName = bundleId;
        a.enabled = enabled;
        return a;
    }
}

unittest {
    // appsDueForRefresh: due / not-due / expired / disabled / bad-date.
    import std.algorithm.searching : canFind;
    import std.algorithm.iteration : map;
    import std.array : array;

    auto now = SysTime.fromISOExtString("2026-06-24T12:00:00Z");
    auto threshold = dur!"hours"(48);

    auto apps = [
        // Expires well outside the window -> NOT due.
        mkApp("com.notdue", "2026-07-10T12:00:00Z"),
        // Expires inside the 48h window -> due.
        mkApp("com.due.soon", "2026-06-25T12:00:00Z"),
        // Already expired -> due.
        mkApp("com.expired", "2026-06-20T12:00:00Z"),
        // Inside window but DISABLED -> NOT due.
        mkApp("com.disabled", "2026-06-25T12:00:00Z", false),
        // Empty expiry -> conservative due.
        mkApp("com.noexpiry", ""),
        // Unparseable expiry -> conservative due.
        mkApp("com.baddate", "not-a-date"),
        // Exactly at the cutoff boundary -> due (<= cutoff).
        mkApp("com.boundary", "2026-06-26T12:00:00Z"),
    ];

    auto due = appsDueForRefresh(apps, now, threshold).map!((a) => a.bundleId).array();

    assert(due.canFind("com.due.soon"));
    assert(due.canFind("com.expired"));
    assert(due.canFind("com.noexpiry"));
    assert(due.canFind("com.baddate"));
    assert(due.canFind("com.boundary"));

    assert(!due.canFind("com.notdue"));
    assert(!due.canFind("com.disabled"));

    assert(due.length == 5);
}

unittest {
    // Empty input -> empty output, no throw.
    auto now = SysTime.fromISOExtString("2026-06-24T12:00:00Z");
    assert(appsDueForRefresh([], now, dur!"hours"(48)).length == 0);
}

unittest {
    // A disabled app that is already expired is still NOT due (toggle wins).
    auto now = SysTime.fromISOExtString("2026-06-24T12:00:00Z");
    auto apps = [mkApp("com.disabled.expired", "2026-01-01T00:00:00Z", false)];
    assert(appsDueForRefresh(apps, now, dur!"hours"(48)).length == 0);
}

unittest {
    // backoffDelay grows exponentially from the base.
    auto base = dur!"seconds"(5);
    assert(backoffDelay(base, 0) == dur!"seconds"(5));
    assert(backoffDelay(base, 1) == dur!"seconds"(10));
    assert(backoffDelay(base, 2) == dur!"seconds"(20));
    assert(backoffDelay(base, 3) == dur!"seconds"(40));
    // Very large attempts are capped rather than overflowing.
    assert(backoffDelay(base, 100) == base * (1L << 16));
}
