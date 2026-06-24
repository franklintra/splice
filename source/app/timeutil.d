module app.timeutil;

/**
 * Small, pure time-formatting helpers shared by the frontends.
 *
 * These used to live in the CLI frontend (`frontends/cli/source/apps.d`), but the
 * GTK app-management UI (#14) needs the very same expiry-countdown rendering, so
 * the logic moved here into the core where both can import it. Everything is pure
 * and offline (no clock, no device), which keeps it unit-testable.
 */

import std.datetime : Duration, SysTime;
import std.format : format;

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
string humanizeDuration(Duration d)
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

/**
 * Parses an ISO-8601 expiry into a `SysTime`, returning `SysTime.init` when the
 * string is empty or unparseable (callers treat that as "unknown").
 */
SysTime parseExpiry(string iso)
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
// unittests: pure expiry-countdown formatting
// ---------------------------------------------------------------------------

unittest {
    import std.datetime : dur;

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
