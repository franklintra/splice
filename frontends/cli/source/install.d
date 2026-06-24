module install;

import slf4d;
import slf4d.default_provider;

import argparse;
import progress;

import imobiledevice;

import sideload;
import sideload.application;
import sideload.coretrust;

import cli_frontend;
import jsonout;
import ui;

@(Command("install").Description("Install an application on the device (renames the app, register the identifier, sign and install automatically)."))
struct InstallCommand
{
    mixin LoginCommand;

    @(PositionalArgument(0, "app path").Description("The path of the IPA file to sideload."))
    string appPath;

    @(NamedArgument("team").Description("Team ID (if your account belongs to several teams)."))
    string teamId = null;

    @(NamedArgument("udid").Description("UDID of the device (if multiple are available)."))
    string udid = null;

    @(NamedArgument("wifi", "prefer-network").Description("Prefer connecting over Wi-Fi when the device is reachable both over USB and Wi-Fi (requires a prior USB pairing with Wi-Fi sync enabled)."))
    bool wifi = false;

    @(NamedArgument("singlethread").Description("Run the signature process on a single thread. Sacrifices speed for more consistency."))
    bool singlethreaded;

    @(NamedArgument("permanent", "troll").Description("Install permanently via the CoreTrust bypass (CVE-2023-41991). Only works on a vulnerable iOS (14.0-16.6.1); the app survives the 7-day expiry and is not auto-refreshed."))
    bool permanent = false;

    int opCall()
    {
        Application app = openApp(appPath);

        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        string configurationPath = session.configurationPath;
        auto appleAccount = session.developerSession;

        // Resolve the team up-front (honours --team, the persisted default or an
        // interactive picker) and hand its id to sideloadFull so multi-team users
        // are not silently bound to the first team.
        auto team = selectTeamInteractive(session, teamId);

        string chosenUdid, transportLabel;
        auto device = selectConnectedDevice(this.udid, wifi, chosenUdid, transportLabel);
        if (!device)
            return 1;

        // Probe the device for CoreTrust-bypass (permanent install) eligibility
        // (#19). This is best-effort: a probe failure must not block a normal
        // dev-cert install, but it gates `--permanent`.
        bool bypassable = false;
        string iosVersion = "";
        try {
            auto status = checkDevice(device);
            bypassable = status.bypassable;
            iosVersion = status.iosVersion;
        } catch (Exception e) {
            log.debugF!"Could not determine CoreTrust eligibility: %s"(e.msg);
        }

        if (permanent && !bypassable) {
            // Refuse the permanent path on a non-vulnerable device.
            log.errorF!"--permanent requires a vulnerable iOS (14.0-16.6.1), but this device reports `%s`."(
                iosVersion.length ? iosVersion : "unknown");
            log.error("The CoreTrust bug (CVE-2023-41991) is patched on 16.7+ / 17.x / 18.x.");
            log.error("Run `splice trollstore status` for details. Re-run without --permanent for a normal install.");
            if (g_jsonOutput)
                printJsonError("permanent install not available on this device");
            return 1;
        }

        if (permanent) {
            log.warn("Installing PERMANENTLY via the CoreTrust bypass (CVE-2023-41991).");
            log.warn("This app will survive past the usual 7-day expiry and will NOT be auto-refreshed.");
        } else if (bypassable) {
            // Inform: a permanent install is available but the user didn't opt in.
            log.infoF!"This device (iOS %s) supports a PERMANENT install. Re-run with --permanent to install an app that never expires and needs no re-signing (CVE-2023-41991)."(iosVersion);
        }

        // In --json mode suppress the human progress bar (it writes to stdout);
        // a structured result is printed once at the end.
        Bar progressBar = g_jsonOutput ? null : new Bar();
        string message;
        if (progressBar !is null)
            progressBar.message = () => message;
        sideloadFull(configurationPath, device, appleAccount, app, (progress, action) {
            message = action;
            if (progressBar !is null) {
                progressBar.index = cast(int) (progress * 100);
                progressBar.update();
            }
        }, !singlethreaded, team.teamId, permanent);
        if (progressBar !is null)
            progressBar.finish();

        if (g_jsonOutput) {
            import std.json : JSONValue;
            import app.persistence : loadInstalledRegistry, InstalledApp;

            // Surface the recorded expiry/bundle id from the registry that
            // sideloadFull just updated, when available.
            JSONValue[string] result = [
                "status":   JSONValue("ok"),
                "bundleId": JSONValue(app.bundleIdentifier()),
            ];
            auto registry = loadInstalledRegistry(configurationPath);
            InstalledApp record;
            if (registry.query(app.bundleIdentifier(), record)) {
                result["expiryDate"] = JSONValue(record.expiryDate);
                result["permanent"] = JSONValue(record.permanent);
                if (record.teamId.length)
                    result["teamId"] = JSONValue(record.teamId);
            }
            printJson(JSONValue(result));
        }

        return 0;
    }
}
