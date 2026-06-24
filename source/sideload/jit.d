module sideload.jit;

/**
 * JIT enablement helper (issue #18), in the style of SideJITServer / StikDebug /
 * Jitterbug.
 *
 * On iOS, attaching a debugger to a running app makes the kernel set the
 * `CS_DEBUGGED` flag on that process, which is what lets the app create RWX (JIT)
 * mappings. We never actually debug anything: we just connect to the on-device
 * `com.apple.debugserver`, speak just enough of the GDB-remote (RSP) protocol to
 * ATTACH to the already-running target app by its executable name, then DETACH,
 * leaving the process running with `CS_DEBUGGED` set.
 *
 * Sequence (see `enableJIT`):
 *   1. Resolve the app's on-device executable name (`CFBundleExecutable`) via
 *      installation_proxy, accepting either the original bundle id or the mangled
 *      `<bundleId>.<teamId>` form Sideloader installs under.
 *   2. Start `com.apple.debugserver` (only present when a Developer Disk Image is
 *      mounted / Developer Mode is on — otherwise this is the actionable error).
 *   3. RSP handshake: `QStartNoAckMode`, `QSetMaxPacketSize`, then
 *      `vAttachName;<hex executable name>`.
 *   4. On a successful stop reply (`T..`/`S..`) send `D` (detach), leaving the
 *      app running with JIT enabled. An error reply (`Exx`) means the app is not
 *      running / cannot be attached.
 *
 * REALITY NOTE: the actual handshake requires a real iOS device with Developer
 * Mode enabled, a DDI mounted, and the target app already running. The
 * device-touching path here is therefore compile-verified against
 * libimobiledevice's debugserver API and the documented RSP technique; the pure
 * helpers below (`hexEncode`, `executableNameToAttachArg`, `stopReplyIndicatesSuccess`)
 * are unit-tested offline.
 */

import std.algorithm.searching : startsWith;
import std.ascii : isHexDigit, toUpper;
import std.string : strip;

import slf4d;

import plist;

import imobiledevice;

// ---------------------------------------------------------------------------
// Pure RSP helpers (offline-testable)
// ---------------------------------------------------------------------------

/**
 * Lowercase-hex encodes the raw bytes of `s` (e.g. "Foo" -> "466f6f"). The RSP
 * `vAttachName` packet carries the target executable name as a hex string, so
 * this is how we build that argument. PURE.
 */
string hexEncode(const(char)[] s) {
    static immutable digits = "0123456789abcdef";
    char[] outBuf;
    outBuf.reserve(s.length * 2);
    foreach (ubyte b; cast(const(ubyte)[]) s) {
        outBuf ~= digits[b >> 4];
        outBuf ~= digits[b & 0x0f];
    }
    return cast(string) outBuf;
}

/**
 * Builds the argument token for the `vAttachName` RSP command from an executable
 * name: the name hex-encoded. The caller sends `sendCommand("vAttachName", [arg])`
 * which libimobiledevice frames as `$vAttachName;<hex>#xx`. PURE.
 */
string executableNameToAttachArg(string executableName) {
    return ";" ~ hexEncode(executableName);
}

/**
 * Interprets an RSP reply to an attach request.
 *
 * debugserver answers a successful attach with a STOP reply: `T<hh>...` (signal
 * + thread/register info) or the simpler `S<hh>`. A failure is `E<xx>` (an error
 * code). An empty reply means the command was not understood. Leading `+`/`-`
 * ack bytes (if ack mode is still on) and surrounding whitespace are tolerated.
 * PURE.
 *
 * Returns true when the reply indicates a successful stop (attach succeeded).
 */
bool stopReplyIndicatesSuccess(string reply) {
    auto r = reply.strip();
    // Tolerate a leading ack byte that may precede the payload.
    while (r.length && (r[0] == '+' || r[0] == '-'))
        r = r[1 .. $];
    r = r.strip();
    if (r.length == 0)
        return false;
    if (r[0] == 'E')
        return false;
    return r[0] == 'T' || r[0] == 'S';
}

/**
 * Extracts the error code from an `Exx` RSP reply (e.g. "E50" -> "50"), or "" if
 * the reply is not an error reply. Used only to make the thrown message clearer.
 * PURE.
 */
string parseErrorCode(string reply) {
    auto r = reply.strip();
    while (r.length && (r[0] == '+' || r[0] == '-'))
        r = r[1 .. $];
    r = r.strip();
    if (r.length >= 1 && r[0] == 'E') {
        size_t end = 1;
        while (end < r.length && r[end].isHexDigit)
            end++;
        return r[1 .. end].idup;
    }
    return "";
}

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

/// Thrown when the requested bundle id is not installed on the device.
class AppNotInstalledException: Exception {
    this(string bundleId, string file = __FILE__, int line = __LINE__) {
        super(
            "The app `" ~ bundleId ~ "` is not installed on this device. " ~
            "Install it first, then launch it before enabling JIT.",
            file, line);
    }
}

/// Thrown when debugserver refused to attach (the app is almost certainly not
/// running — JIT can only be enabled for a process that is already started).
class JitAttachException: Exception {
    this(string bundleId, string reply, string file = __FILE__, int line = __LINE__) {
        string code = parseErrorCode(reply);
        super(
            "Could not attach to `" ~ bundleId ~ "` to enable JIT" ~
            (code.length ? " (debugserver error E" ~ code ~ ")" : "") ~
            ". Make sure the app is currently RUNNING in the foreground on the device, then try again.",
            file, line);
    }
}

// ---------------------------------------------------------------------------
// Executable-name resolution
// ---------------------------------------------------------------------------

/**
 * Resolves the on-device executable name (`CFBundleExecutable`) for `bundleId`
 * via installation_proxy. Accepts either the original bundle id or the mangled
 * `<bundleId>.<teamId>` form (Sideloader installs apps under the mangled id, see
 * `apps.d`). Returns the executable name, or null if the app is not present.
 *
 * Browses User apps once and matches `CFBundleIdentifier` against `bundleId` and
 * `bundleId.*` (prefix), reading `CFBundleExecutable` from the same record.
 */
private string resolveExecutableName(iDevice device, LockdowndClient lockdown, string bundleId) {
    scope service = lockdown.startService("com.apple.mobile.installation_proxy");
    scope client = new InstallationProxyClient(device, service);

    auto result = client.browse([
        "ApplicationType": "User".pl,
        "ReturnAttributes": [
            "CFBundleIdentifier".pl,
            "CFBundleExecutable".pl,
            "Path".pl,
        ].pl
    ].pl);

    foreach (entry; result.array()) {
        auto appDict = entry.dict();
        auto idEntry = "CFBundleIdentifier" in appDict;
        if (!idEntry)
            continue;
        string onDeviceId = idEntry.str().native();

        // Accept the original id, the mangled <bundleId>.<teamId>, or vice-versa.
        bool matches = onDeviceId == bundleId
            || onDeviceId.startsWith(bundleId ~ ".")
            || bundleId.startsWith(onDeviceId ~ ".");
        if (!matches)
            continue;

        if (auto execEntry = "CFBundleExecutable" in appDict) {
            string exec = execEntry.str().native();
            if (exec.length)
                return exec;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// JIT enablement
// ---------------------------------------------------------------------------

/**
 * Enables JIT for the app identified by `bundleId` running on `device`.
 *
 * Resolves the executable name, opens `com.apple.debugserver`, performs the RSP
 * handshake (no-ack, max packet size, `vAttachName;<hex name>`), verifies the
 * stop reply, then detaches so the app keeps running with `CS_DEBUGGED` set.
 *
 * Throws:
 *   - `DebugserverUnavailableException` when debugserver cannot be started
 *     (Developer Mode off / DDI not mounted) — message includes remediation.
 *   - `AppNotInstalledException` when `bundleId` is not on the device.
 *   - `JitAttachException` when the attach fails (app not running).
 */
void enableJIT(iDevice device, string bundleId) {
    auto log = getLogger();

    scope lockdown = new LockdowndClient(device, "sideloader.jit");

    string executableName = resolveExecutableName(device, lockdown, bundleId);
    if (executableName is null)
        throw new AppNotInstalledException(bundleId);
    log.debugF!"Resolved `%s` to on-device executable `%s`."(bundleId, executableName);

    // Starting this service is the Developer-Mode/DDI gate; the constructor
    // throws DebugserverUnavailableException (with remediation) if it can't.
    scope debugserver = new DebugserverClient(device, "sideloader.jit");
    debugserver.setReceiveTimeout(5000);

    // --- RSP handshake ---
    // 1. Switch to no-ack mode: ask the target, then stop ack-handling locally.
    debugserver.sendCommand("QStartNoAckMode", []);
    debugserver.setAckMode(false);

    // 2. Advertise a generous max packet size (mirrors what debuggers send).
    debugserver.sendCommand("QSetMaxPacketSize:", ["20000"]);

    // 3. Attach to the already-running app by executable name. The name is hex
    //    encoded and prefixed with ';' to form `vAttachName;<hex>`.
    string attachArg = executableNameToAttachArg(executableName);
    log.infoF!"Attaching to `%s` to enable JIT..."(bundleId);
    string reply = debugserver.sendCommand("vAttachName", [attachArg]);
    log.debugF!"Attach reply: %s"(reply);

    if (!stopReplyIndicatesSuccess(reply))
        throw new JitAttachException(bundleId, reply);

    // 4. Detach, leaving the process running with CS_DEBUGGED (JIT) enabled.
    debugserver.sendCommand("D", []);
    log.infoF!"JIT enabled for `%s`."(bundleId);
}

// ---------------------------------------------------------------------------
// Pure unittests (offline)
// ---------------------------------------------------------------------------

unittest {
    // hexEncode: lowercase hex of the raw bytes.
    assert(hexEncode("Foo") == "466f6f");
    assert(hexEncode("") == "");
    assert(hexEncode("A") == "41");
    // Multi-byte / high-bit byte.
    assert(hexEncode(cast(string) [cast(char) 0x00, cast(char) 0xff]) == "00ff");

    // executableNameToAttachArg: ';' + hex.
    assert(executableNameToAttachArg("Foo") == ";466f6f");
    assert(executableNameToAttachArg("MyApp") == ";4d79417070");

    // stopReplyIndicatesSuccess: T../S.. succeed, E.. and empty fail.
    assert(stopReplyIndicatesSuccess("T11thread:1f03;"));
    assert(stopReplyIndicatesSuccess("S05"));
    assert(!stopReplyIndicatesSuccess("E50"));
    assert(!stopReplyIndicatesSuccess(""));
    assert(!stopReplyIndicatesSuccess("OK")); // not a stop reply
    // Tolerates a leading ack byte and whitespace.
    assert(stopReplyIndicatesSuccess("+T05thread:1;"));
    assert(!stopReplyIndicatesSuccess("+E08"));
    assert(stopReplyIndicatesSuccess("  T13  "));

    // parseErrorCode: extracts the hex code, empty for non-errors.
    assert(parseErrorCode("E50") == "50");
    assert(parseErrorCode("+E08") == "08");
    assert(parseErrorCode("T05") == "");
    assert(parseErrorCode("") == "");
}
