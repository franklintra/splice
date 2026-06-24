module trollstore;

import std.stdio;
import std.sumtype;

import slf4d;

import argparse;

import std.json : JSONValue;

import imobiledevice;

import sideload.coretrust;

import cli_frontend;
import jsonout;
import ui;

@(Command("trollstore").Description("TrollStore / CoreTrust permanent-install helpers (CVE-2023-41991)."))
struct TrollStoreCommand
{
    int opCall()
    {
        return cmd.match!(
                (TrollStoreStatus cmd) => cmd(),
        );
    }

    @SubCommands
    SumType!(TrollStoreStatus) cmd;
}

@(Command("status").Description("Report whether a permanent (TrollStore-style) install is available on the connected device."))
struct TrollStoreStatus
{
    @(NamedArgument("udid").Description("UDID of the device (if multiple are available)."))
    string udid = null;

    @(NamedArgument("wifi", "prefer-network").Description("Prefer connecting over Wi-Fi when the device is reachable both over USB and Wi-Fi (requires a prior USB pairing with Wi-Fi sync enabled)."))
    bool wifi = false;

    int opCall()
    {
        auto log = getLogger();

        string chosenUdid, transportLabel;
        auto device = selectConnectedDevice(this.udid, wifi, chosenUdid, transportLabel);
        if (!device) {
            // selectConnectedDevice already logged a clear "no device" message.
            if (g_jsonOutput)
                printJsonError("No device connected.");
            return 1;
        }

        CoreTrustStatus status;
        try {
            status = checkDevice(device);
        } catch (Exception e) {
            log.errorF!"Could not read the device's iOS version: %s"(e.msg);
            log.error("Make sure the device is unlocked and trusts this computer.");
            if (g_jsonOutput)
                printJsonError(e.msg);
            return 1;
        }

        if (g_jsonOutput) {
            printJson(JSONValue([
                "iosVersion":               JSONValue(status.iosVersion),
                "deviceName":               JSONValue(status.deviceName),
                "productType":              JSONValue(status.productType),
                "bypassable":               JSONValue(status.bypassable),
                "permanentInstallAvailable": JSONValue(status.bypassable),
            ]));
            return 0;
        }

        header("Device");
        field("Device", status.deviceName);
        if (status.productType.length)
            field("Model", status.productType);
        field("iOS version", status.iosVersion);

        if (status.bypassable) {
            header("Permanent install");
            success("A PERMANENT install is AVAILABLE on this device.");
            note("Its iOS version is vulnerable to the CoreTrust bug (CVE-2023-41991),");
            note("which TrollStore 2 uses to install apps that:");
            note("  - survive past the usual 7-day developer-certificate expiry,");
            note("  - need no Apple ID and never have to be re-signed/refreshed.");
            header("Trade-offs / what you should understand first");
            note("  - This relies on a now-PATCHED exploit; it only works because this");
            note("    device is on a vulnerable iOS version (14.0 - 16.6.1).");
            note("  - Updating iOS to 16.7 or later removes the vulnerability; already");
            note("    installed permanent apps generally keep working, but you will not");
            note("    be able to install new ones.");
            note("  - A permanent app is NOT managed/renewed by Splice's refresh");
            note("    daemon. You are responsible for understanding what you install.");
            writeln();
            note("To use it, install with:  splice install --permanent <app.ipa>");
        } else {
            header("Permanent install");
            warning("A permanent install is NOT available on this device.");
            note("The CoreTrust bug (CVE-2023-41991) only works on iOS/iPadOS 14.0 - 16.6.1.");
            note("This device is either too old or on a patched iOS (16.7+ / 17.x / 18.x),");
            note("so apps must be installed with a developer certificate and refreshed");
            note("before they expire (~every 7 days).");
        }

        return 0;
    }
}
