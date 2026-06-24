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

        writefln!"Device:      %s"(status.deviceName);
        if (status.productType.length)
            writefln!"Model:       %s"(status.productType);
        writefln!"iOS version: %s"(status.iosVersion);
        writeln();

        if (status.bypassable) {
            writeln("A PERMANENT install is AVAILABLE on this device.");
            writeln("Its iOS version is vulnerable to the CoreTrust bug (CVE-2023-41991),");
            writeln("which TrollStore 2 uses to install apps that:");
            writeln("  - survive past the usual 7-day developer-certificate expiry,");
            writeln("  - need no Apple ID and never have to be re-signed/refreshed.");
            writeln();
            writeln("TRADE-OFFS / what you should understand first:");
            writeln("  - This relies on a now-PATCHED exploit; it only works because this");
            writeln("    device is on a vulnerable iOS version (14.0 - 16.6.1).");
            writeln("  - Updating iOS to 16.7 or later removes the vulnerability; already");
            writeln("    installed permanent apps generally keep working, but you will not");
            writeln("    be able to install new ones.");
            writeln("  - A permanent app is NOT managed/renewed by Sideloader's refresh");
            writeln("    daemon. You are responsible for understanding what you install.");
            writeln();
            writeln("To use it, install with:  sideloader install --permanent <app.ipa>");
        } else {
            writeln("A permanent install is NOT available on this device.");
            writeln("The CoreTrust bug (CVE-2023-41991) only works on iOS/iPadOS 14.0 - 16.6.1.");
            writeln("This device is either too old or on a patched iOS (16.7+ / 17.x / 18.x),");
            writeln("so apps must be installed with a developer certificate and refreshed");
            writeln("before they expire (~every 7 days).");
        }

        return 0;
    }
}
