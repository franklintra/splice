module sidestore;

import std.algorithm;
import std.array;
import std.format;
import std.stdio;
import std.string;
import std.sumtype;

import slf4d;

import argparse;

import plist;

import imobiledevice;

import tools;
import tools.sidestorepairingfile;

import cli_frontend;
import ui;

@(Command("sidestore").Description("First-class SideStore companion: detect SideStore and set up on-device refresh (pairing file)."))
struct SideStoreCommand
{
    int opCall()
    {
        return cmd.match!(
                (SideStoreStatus cmd) => cmd(),
                (SideStorePair cmd) => cmd(),
        );
    }

    @SubCommands
    SumType!(SideStoreStatus, SideStorePair) cmd;
}

/**
 * Resolves the UDID to act on, honouring an explicit `--udid` and otherwise
 * picking the sole connected device (deduping a device reachable both over USB
 * and Wi-Fi into one). Logs clear guidance and returns null (caller should
 * `return 1`) when there is no device or the choice is ambiguous. Never throws
 * on the "no device" path. SideStore pairing wants a cabled connection, so this
 * keeps the default (USB-preferred) transport.
 */
private string resolveDeviceUdid(string explicitUdid)
{
    return selectConnectedUdid(explicitUdid);
}

@(Command("status").Description("Report whether SideStore is installed on the device."))
struct SideStoreStatus
{
    @(NamedArgument("udid").Description("UDID of the device (if multiple are available)."))
    string udid = null;

    int opCall()
    {
        auto log = getLogger();

        string deviceId = resolveDeviceUdid(udid);
        if (!deviceId)
            return 1;

        iDevice device;
        SideStoreTool tool;
        try {
            device = new iDevice(deviceId);
            tool = new SideStoreTool(device);
        } catch (Exception ex) {
            log.errorF!"Could not connect to the device: %s"(ex.msg);
            log.error("Make sure the device is unlocked and that it trusts this computer.");
            return 1;
        }

        if (tool.diagnostic() != null) {
            // Not installed (this is the SideStore detection surfaced to the CLI).
            log.info("SideStore is NOT installed on this device.");
            log.info("Install SideStore first (https://sidestore.io), then run `sidestore pair`.");
            return 1;
        }

        success("SideStore is installed on this device.");
        foreach (bundleId; tool.sideStoreBundles) {
            string ver = sideStoreVersion(tool.lockdowndClient, device, bundleId);
            if (ver.length)
                field(bundleId, paint(format!"version %s"(ver), Theme.muted));
            else
                field(bundleId, "");
        }
        note("Run `sidestore pair` to set up the pairing file so SideStore can refresh apps on-device.");

        return 0;
    }
}

@(Command("pair", "setup").Description("Pair the device and push SideStore's pairing file so it can refresh apps on-device.").ShortDescription("Set up SideStore on-device refresh (alias: setup)."))
struct SideStorePair
{
    @(NamedArgument("udid").Description("UDID of the device (if multiple are available)."))
    string udid = null;

    @(NamedArgument("anisette-server").Description("Anisette server URL to point SideStore at. Currently printed for you to set in-app (see notes). Falls back to the persisted default."))
    string anisetteServer = null;

    int opCall()
    {
        auto log = getLogger();

        string deviceId = resolveDeviceUdid(udid);
        if (!deviceId)
            return 1;

        iDevice device;
        SideStoreTool tool;
        try {
            device = new iDevice(deviceId);
            tool = new SideStoreTool(device);
        } catch (Exception ex) {
            log.errorF!"Could not connect to the device: %s"(ex.msg);
            log.error("Make sure the device is unlocked and that it trusts this computer.");
            return 1;
        }

        if (tool.diagnostic() != null) {
            log.errorF!"%s"(tool.diagnostic());
            log.error("Install SideStore first (https://sidestore.io), then run `sidestore pair` again.");
            return 1;
        }

        log.info("Setting up SideStore's pairing file. Keep your device unlocked and trust this computer if prompted.");

        // Reuse SideStoreTool.run() for the whole pair + push-pairing-file flow.
        // The notify delegate mirrors `tool run`'s console behaviour: print the
        // message and wait for the user to press enter before retrying.
        tool.run((message, canCancel) {
            message = format!"%s [OK = return]%s"(message, canCancel ? " [exit = ^C]" : "");
            stdout.writeln(message);
            readln();
            return false;
        });

        log.info("Done. SideStore can now refresh your apps on-device using this pairing file.");

        // Anisette server: surface the configured value. SideStore reads its
        // anisette server URL from its in-app settings (no documented container
        // file we can safely write), so we instruct the user rather than write a
        // speculative file that could corrupt SideStore's configuration.
        string anisette = resolveSideStoreAnisette(device, anisetteServer);
        if (anisette.length) {
            writeln();
            field("Anisette server (Splice)", paint(anisette, Theme.accent));
            note("SideStore stores its anisette server in its own in-app settings, so it can't be");
            note("pushed from here. Open SideStore → Settings and set the anisette server to the");
            note("URL above if you want SideStore to use the same one.");
        }

        return 0;
    }
}

/**
 * Resolves the anisette server URL to surface for SideStore. An explicit
 * `--anisette-server` on the subcommand wins; otherwise we fall back to the
 * persisted default resolved by `resolveAnisetteServer` (which also honours the
 * global `--anisette-server`). Returns empty when none is configured.
 */
private string resolveSideStoreAnisette(iDevice device, string explicit)
{
    if (explicit.length)
        return explicit.strip();
    // resolveAnisetteServer reads the persisted default (and the global flag,
    // surfaced via g_anisetteServer in entryPoint). Pass the system config path.
    return resolveAnisetteServer(systemConfigurationPath());
}

/**
 * Best-effort lookup of the installed SideStore short version string via
 * installation_proxy. Returns empty on any error so `status` never crashes.
 */
private string sideStoreVersion(LockdowndClient lockdowndClient, iDevice device, string bundleId)
{
    try {
        scope service = lockdowndClient.startService("com.apple.mobile.installation_proxy");
        scope client = new InstallationProxyClient(device, service);

        auto results = client.browse([
            "ApplicationType": "User".pl,
            "ReturnAttributes": [
                "CFBundleIdentifier".pl,
                "CFBundleShortVersionString".pl,
                "CFBundleVersion".pl,
            ].pl
        ].pl).array().native();

        foreach (elem; results) {
            auto dict = elem.dict();
            if (auto id = "CFBundleIdentifier" in dict) {
                if (id.str().native() == bundleId) {
                    if (auto sv = "CFBundleShortVersionString" in dict)
                        return sv.str().native();
                    if (auto bv = "CFBundleVersion" in dict)
                        return bv.str().native();
                }
            }
        }
    } catch (Exception) {
        // Version is informational only.
    }
    return "";
}
