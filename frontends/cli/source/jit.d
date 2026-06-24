module jit;

/**
 * `splice jit <bundle-id>` (issue #18): enable JIT for an already-running
 * app on a connected device, SideJITServer / StikDebug style.
 *
 * PREREQUISITES (surfaced as clear errors at runtime):
 *   - Developer Mode is enabled on the device and a Developer Disk Image is
 *     mounted (the `com.apple.debugserver` service only exists then);
 *   - the target app is installed AND currently running in the foreground.
 *
 * The actual handshake lives in `sideload.jit.enableJIT`; this command just
 * selects the device and reports success/failure (with `--json` support).
 */

import std.format;
import std.json : JSONValue;
import std.stdio;

import slf4d;

import argparse;

import imobiledevice;

import sideload.jit;

import cli_frontend;
import jsonout;
import ui;

@(Command("jit").Description("Enable JIT for an already-running app on the device (requires Developer Mode + a mounted Developer Disk Image)."))
struct JITCommand
{
    @(PositionalArgument(0, "bundle id").Description("Bundle identifier of the app to enable JIT for (the original or the on-device id)."))
    string bundleId;

    @(NamedArgument("udid").Description("UDID of the device (if multiple are available)."))
    string udid = null;

    @(NamedArgument("wifi", "prefer-network").Description("Prefer connecting over Wi-Fi when the device is reachable both over USB and Wi-Fi (requires a prior USB pairing with Wi-Fi sync enabled)."))
    bool wifi = false;

    int opCall()
    {
        auto log = getLogger();

        string chosenUdid, transportLabel;
        auto device = selectConnectedDevice(udid, wifi, chosenUdid, transportLabel);
        if (!device) {
            if (g_jsonOutput)
                printJsonError("No device connected. Connect a device (over USB or Wi-Fi) and try again.");
            return 1;
        }

        try {
            enableJIT(device, bundleId);
        } catch (Exception e) {
            if (g_jsonOutput)
                printJsonError(e.msg);
            else
                log.errorF!"Failed to enable JIT for `%s`: %s"(bundleId, e.msg);
            return 1;
        }

        if (g_jsonOutput) {
            printJson(JSONValue([
                "status":   JSONValue("ok"),
                "bundleId": JSONValue(bundleId),
            ]));
        } else {
            success(format!"JIT enabled for `%s`. The app can now use just-in-time compilation."(bundleId));
        }
        return 0;
    }
}
