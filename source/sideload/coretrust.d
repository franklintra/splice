module sideload.coretrust;

/**
 * TrollStore / CoreTrust-bypass detection for the permanent-install path (#19).
 *
 * TrollStore 2's permanent install relies on the CoreTrust signature-validation
 * bug (CVE-2023-41991), already implemented as `sideload.ct_bypass.bypassCoreTrust`.
 * That exploit only works on a specific iOS/iPadOS version range:
 *
 *   - iOS/iPadOS 14.0 through 16.6.1 inclusive  -> VULNERABLE (bypassable);
 *   - iOS/iPadOS 16.7 and later (incl. all 17.x / 18.x and the 16.7.x point
 *     releases) -> PATCHED (not bypassable);
 *   - anything older than 14.0 -> NOT supported (different exploit story).
 *
 * `isCoreTrustBypassable` is a PURE dotted-version comparison (no string compare,
 * no device access) so it is fully offline-unit-testable. `checkDevice` reads the
 * device's `ProductVersion`/`ProductType`/name over lockdownd and wraps the
 * result, but contains no policy of its own beyond delegating to the pure helper.
 *
 * Boundary documentation:
 *   - 16.6.1 is the LAST vulnerable build; 16.7 is the first patched train.
 *   - The 16.7 RC build (20H18) is treated as patched here (we split on the
 *     dotted version only, not on the build string).
 *   - A bare "16" with no minor is AMBIGUOUS and is treated as 16.0 -> bypassable.
 *     (We parse missing components as 0, so "16" == "16.0.0", which is < 16.6.1.)
 *     This is intentional and tested below.
 */

import std.algorithm.iteration : map;
import std.array : array, split;
import std.conv : to;
import std.string : strip;

import slf4d;

import imobiledevice;

/// Lowest iOS version on which the CoreTrust bypass works (inclusive).
private enum int[3] CT_MIN_VERSION = [14, 0, 0];
/// Highest iOS version on which the CoreTrust bypass works (inclusive). 16.7 is patched.
private enum int[3] CT_MAX_VERSION = [16, 6, 1];

/**
 * Parses a dotted iOS version string into its (major, minor, patch) components.
 *
 * Tolerant of:
 *   - missing minor/patch (e.g. "16" -> 16.0.0, "16.7" -> 16.7.0);
 *   - a trailing build suffix that some sources append (e.g. "16.6.1 (20G81)" or
 *     "16.6.1-20G81"): only the leading dotted-numeric portion is read.
 *
 * Returns `true` on success (filling `major`/`minor`/`patch`), `false` when the
 * string has no parseable leading numeric component at all (empty, "garbage").
 */
bool parseIosVersion(string version_, out int major, out int minor, out int patch) pure {
    string v = version_.strip();
    if (v.length == 0)
        return false;

    // Keep only the leading run of digits and dots; this drops a build suffix
    // like " (20G81)" without rejecting the whole string.
    size_t end = 0;
    while (end < v.length && (v[end] == '.' || (v[end] >= '0' && v[end] <= '9')))
        end++;
    v = v[0 .. end];
    if (v.length == 0)
        return false;

    auto parts = v.split(".");
    int[3] comps = [0, 0, 0];
    bool any = false;
    foreach (i, part; parts) {
        if (i >= 3)
            break;
        if (part.length == 0)
            continue; // tolerate "16..1" oddities
        try {
            comps[i] = part.to!int;
            any = true;
        } catch (Exception) {
            return false;
        }
    }
    if (!any)
        return false;

    major = comps[0];
    minor = comps[1];
    patch = comps[2];
    return true;
}

/// Three-way compare of two (major, minor, patch) triples: -1 / 0 / +1.
private int compareVersion(int[3] a, int[3] b) pure {
    foreach (i; 0 .. 3) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    return 0;
}

/**
 * Returns `true` when the CoreTrust bypass (CVE-2023-41991) works on the given
 * iOS version, i.e. `14.0 <= version <= 16.6.1`.
 *
 * PURE dotted-version comparison (not a string compare). Unparseable input
 * (empty, "garbage") and out-of-range versions return `false`.
 */
bool isCoreTrustBypassable(string iosVersion) pure {
    int major, minor, patch;
    if (!parseIosVersion(iosVersion, major, minor, patch))
        return false;
    int[3] v = [major, minor, patch];
    return compareVersion(v, CT_MIN_VERSION) >= 0
        && compareVersion(v, CT_MAX_VERSION) <= 0;
}

/**
 * Result of probing a connected device for permanent-install eligibility.
 */
struct CoreTrustStatus {
    /// iOS/iPadOS version reported by the device (`ProductVersion`), e.g. "16.6.1".
    string iosVersion;
    /// Human-readable device name (lockdownd `GetName`), e.g. "John's iPhone".
    string deviceName;
    /// Device model identifier (`ProductType`), e.g. "iPhone14,2". Empty if unknown.
    string productType;
    /// Whether the CoreTrust bypass works on this iOS version.
    bool bypassable;
}

/**
 * Reads the connected device's iOS version (and name / model) over lockdownd and
 * decides whether a permanent (TrollStore-style) install is available on it.
 *
 * The device must already be opened by the caller (see `selectConnectedDevice`).
 * Throws on a lockdownd failure (e.g. the device is locked / not trusted); the
 * caller is expected to surface that as a clean error.
 */
CoreTrustStatus checkDevice(iDevice device) {
    scope lockdown = new LockdowndClient(device, "sideloader.coretrust");

    CoreTrustStatus status;
    status.deviceName = lockdown.deviceName();
    status.iosVersion = lockdown[null, "ProductVersion"].str().native().strip();
    try {
        status.productType = lockdown[null, "ProductType"].str().native().strip();
    } catch (Exception) {
        // ProductType is best-effort; some odd lockdownd states omit it.
        status.productType = "";
    }
    status.bypassable = isCoreTrustBypassable(status.iosVersion);
    return status;
}

// ---------------------------------------------------------------------------
// unittests: pure version-range logic
// ---------------------------------------------------------------------------

unittest {
    // In-range versions are bypassable (14.0 .. 16.6.1 inclusive).
    assert(isCoreTrustBypassable("14.0"));
    assert(isCoreTrustBypassable("14.0.0"));
    assert(isCoreTrustBypassable("15.8.3"));
    assert(isCoreTrustBypassable("16.0"));
    assert(isCoreTrustBypassable("16.6"));
    assert(isCoreTrustBypassable("16.6.1"));
    // Bare "16" is treated as 16.0 -> bypassable (documented choice).
    assert(isCoreTrustBypassable("16"));
}

unittest {
    // Out-of-range / patched versions are NOT bypassable.
    assert(!isCoreTrustBypassable("13.7"));     // too old
    assert(!isCoreTrustBypassable("13.0"));
    assert(!isCoreTrustBypassable("16.7"));     // first patched train
    assert(!isCoreTrustBypassable("16.7.1"));
    assert(!isCoreTrustBypassable("16.7.2"));
    assert(!isCoreTrustBypassable("17.0"));
    assert(!isCoreTrustBypassable("17.4"));
    assert(!isCoreTrustBypassable("18.1"));
    // Just past the boundary.
    assert(!isCoreTrustBypassable("16.6.2"));
}

unittest {
    // Garbage / empty input -> not bypassable, no throw.
    assert(!isCoreTrustBypassable(""));
    assert(!isCoreTrustBypassable("   "));
    assert(!isCoreTrustBypassable("garbage"));
    assert(!isCoreTrustBypassable("vNext"));
}

unittest {
    // Build-suffixed strings parse on the leading dotted version only.
    assert(isCoreTrustBypassable("16.6.1 (20G81)"));
    assert(isCoreTrustBypassable("15.0-19A346"));
    assert(!isCoreTrustBypassable("16.7 (20H18)")); // the 16.7 RC build -> patched
}

unittest {
    // parseIosVersion fills components and tolerates partial input.
    int ma, mi, pa;
    assert(parseIosVersion("16.6.1", ma, mi, pa));
    assert(ma == 16 && mi == 6 && pa == 1);

    assert(parseIosVersion("16", ma, mi, pa));
    assert(ma == 16 && mi == 0 && pa == 0);

    assert(parseIosVersion("17.4", ma, mi, pa));
    assert(ma == 17 && mi == 4 && pa == 0);

    assert(!parseIosVersion("", ma, mi, pa));
    assert(!parseIosVersion("garbage", ma, mi, pa));
}
