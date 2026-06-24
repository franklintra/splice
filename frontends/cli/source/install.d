module install;

import slf4d;
import slf4d.default_provider;

import argparse;
import progress;

import imobiledevice;

import sideload;
import sideload.application;

import cli_frontend;

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
        Bar progressBar = new Bar();
        string message;
        progressBar.message = () => message;
        sideloadFull(configurationPath, device, appleAccount, app, (progress, action) {
            message = action;
            progressBar.index = cast(int) (progress * 100);
            progressBar.update();
        }, !singlethreaded, team.teamId);
        progressBar.finish();

        return 0;
    }
}
