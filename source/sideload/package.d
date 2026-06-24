module sideload;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.concurrency;
import std.conv;
import std.datetime;
import std.exception;
import file = std.file;
import std.format;
import std.path;
import std.uni;

import slf4d;

import plist;

import imobiledevice;

import server.developersession;

public import sideload.application;
public import sideload.bundle;
import sideload.certificateidentity;
import sideload.sign;

import utils;

void sideloadFull(
    string configurationPath,
    iDevice device,
    DeveloperSession developer,
    Application app,
    void delegate(double progress, string action) progressCallback,
    bool isMultithreaded = false,
    string teamId = null,
    bool permanent = false,
) {
    enum STEP_COUNT = 9.0;
    auto log = getLogger();

    // Remove the IPA extraction temp dir once we are completely done (signing and
    // transfer both read from it, so this only runs after the whole flow exits,
    // success or failure). Non-fatal by construction (cleanup() swallows errors).
    scope(exit) app.cleanup();

    bool isSideStore = app.bundleIdentifier() == "com.SideStore.SideStore";

    // Select the development team. When a `teamId` is supplied (the CLI resolves
    // it from `--team`, the persisted default or an interactive picker), use the
    // matching team; otherwise fall back to the first team for backward
    // compatibility with callers (e.g. the GUIs) that do not pass one yet.
    progressCallback(0 / STEP_COUNT, "Fetching development teams");
    auto teams = developer.listTeams().unwrap();
    enforce(teams.length > 0, "No development team found for this account.");
    DeveloperTeam team = teams[0];
    if (teamId !is null) {
        auto matching = teams.filter!((t) => t.teamId == teamId).array();
        enforce(matching.length > 0, "No matching team found.");
        team = matching[0];
    }

    // list development devices from the account
    progressCallback(1 / STEP_COUNT, "List account's development devices");
    auto devices = developer.listDevices!iOS(team).unwrap();
    auto deviceUdid = device.udid();

    // if the current device is not registered as a development device for this account, do it!
    if (!devices.any!((device) => device.deviceNumber == deviceUdid)) {
        progressCallback(2 / STEP_COUNT, "Register the current device as a development device");
        scope lockdown = new LockdowndClient(device, "sideloader.developer");
        auto deviceName = lockdown.deviceName();
        developer.addDevice!iOS(team, deviceName, deviceUdid).unwrap();
    }

    // create a certificate for the developer
    progressCallback(3 / STEP_COUNT, "Generating a certificate for Sideloader");
    auto certIdentity = new CertificateIdentity(configurationPath, developer);

    // check if we registered an app id for it (if not create it)
    progressCallback(4 / STEP_COUNT, "Creating App IDs for the application");
    string mainAppBundleId = app.bundleIdentifier();
    string mainAppIdStr = mainAppBundleId ~ "." ~ team.teamId;
    app.bundleIdentifier = mainAppIdStr;
    string mainAppName = app.bundleName();

    auto listAppIdResponse = developer.listAppIds!iOS(team).unwrap();

    auto appExtensions = app.appExtensions();

    foreach (ref plugin; appExtensions) {
        string pluginBundleIdentifier = plugin.bundleIdentifier();
        assertBundle(
            pluginBundleIdentifier.startsWith(mainAppBundleId) &&
            pluginBundleIdentifier.length > mainAppBundleId.length,
            "Plug-ins are not formed with the main app bundle identifier"
        );
        plugin.bundleIdentifier = mainAppIdStr ~ pluginBundleIdentifier[mainAppBundleId.length..$];
    }

    auto bundlesWithAppID = app ~ appExtensions;

    log.debugF!"App IDs needed: %-(%s, %)"(bundlesWithAppID.map!((b) => b.bundleIdentifier()).array());

    // Search which App IDs have to be registered (we don't want to start registering App IDs if we don't
    // have enough of them to register them all!! otherwise we will waste their precious App IDs)
    auto appIdsToRegister = bundlesWithAppID.filter!((bundle) => !listAppIdResponse.appIds.canFind!((a) => a.identifier == bundle.bundleIdentifier())).array();

    // Surface the App ID quota proactively before registering anything, so the
    // user knows how many slots they are using and, when slots are exhausted,
    // when the next one frees up. Existing App IDs are reused (only the missing
    // ones above are registered), so this never wastes the precious quota.
    {
        import persistence = app.persistence;
        log.infoF!"App ID quota: %d of %d available, %d new App ID(s) to register."(
            listAppIdResponse.availableQuantity, listAppIdResponse.maxQuantity, appIdsToRegister.length);
        if (listAppIdResponse.appIds.length) {
            auto resetDate = persistence.appIdResetDate(
                listAppIdResponse.appIds.map!((appId) => appId.expirationDate).array());
            log.infoF!"Next App ID slot frees up on %s."(resetDate.toSimpleString());
        }
    }

    if (appIdsToRegister.length > listAppIdResponse.availableQuantity) {
        auto minDate = listAppIdResponse.appIds.map!((appId) => appId.expirationDate).minElement();
        throw new NoAppIdRemainingException(minDate);
    }

    foreach (bundle; appIdsToRegister) {
        auto appIdName = bundle.bundleName.filter!((dchar c) => c.isAlphaNum).array().to!string();
        if (appIdName.length == 0) {
            appIdName = bundle.bundleIdentifier;
        }
        log.infoF!"Creating App ID `%s` for the bundle `%s`..."(appIdName, bundle.bundleIdentifier);
        developer.addAppId!iOS(team, bundle.bundleIdentifier, appIdName).unwrap();
        log.info("OK.");
    }
    listAppIdResponse = developer.listAppIds!iOS(team).unwrap();
    auto appIds = listAppIdResponse.appIds.filter!((appId) => bundlesWithAppID.canFind!((bundle) => appId.identifier == bundle.bundleIdentifier())).array();
    auto mainAppId = appIds.find!((appId) => appId.identifier == mainAppIdStr)[0];

    foreach (ref appId; appIds) {
        if (!appId.features[AppIdFeatures.appGroup].boolean().native()) {
            // We need to enable app groups then !
            appId.features = developer.updateAppId!iOS(team, appId, dict(AppIdFeatures.appGroup, true)).unwrap();
        }
    }

    // create an app group for it if needed
    progressCallback(5 / STEP_COUNT, "Creating an application group");
    auto groupIdentifier = "group." ~ mainAppIdStr;
    auto groupName = "app group for " ~ mainAppId.name;

    if (isSideStore) {
        app.appInfo["ALTAppGroups"] = [groupIdentifier.pl].pl;
    }

    auto appGroups = developer.listApplicationGroups!iOS(team).unwrap();
    auto matchingAppGroups = appGroups.find!((appGroup) => appGroup.identifier == groupIdentifier).array();
    ApplicationGroup appGroup;
    if (matchingAppGroups.empty) {
        appGroup = developer.addApplicationGroup!iOS(team, groupIdentifier, groupName).unwrap();
    } else {
        appGroup = matchingAppGroups[0];
    }

    progressCallback(6 / STEP_COUNT, "Manage App IDs and groups");
    ProvisioningProfile[string] provisioningProfiles;
    foreach (appId; appIds) {
        developer.assignApplicationGroupToAppId!iOS(team, appId, appGroup).unwrap();
        provisioningProfiles[appId.identifier] = developer.downloadTeamProvisioningProfile!iOS(team, mainAppId).unwrap();
    }

    // sign the app with all the retrieved material!
    progressCallback(7 / STEP_COUNT, "Signing the application bundle");
    double accumulator = 0;
    sign(app, certIdentity, provisioningProfiles, (progress) => progressCallback((7 + (accumulator += progress)) / STEP_COUNT, "Signing the application bundle"));

    // Permanent (TrollStore-style) install: after the normal dev-cert signing,
    // re-stamp every Mach-O in the bundle with the CoreTrust bypass (#19). This
    // makes the binaries pass on-device validation even after the 7-day dev
    // profile would otherwise expire. The caller (CLI `install --permanent`) has
    // already verified the device is on a vulnerable iOS version.
    if (permanent) {
        progressCallback(7 / STEP_COUNT, "Applying the CoreTrust bypass (permanent install)");
        applyCoreTrustBypass(app);
    }

    // connect to the device's installation daemon and send to it the signed app
    double progress = 8 / STEP_COUNT;
    progressCallback(progress, "Installing the application on the device");
    scope lockdownClient = new LockdowndClient(device, "sideloader.app_install");

    // set up clients and proxies
    auto installationProxyService = lockdownClient.startService("com.apple.mobile.installation_proxy");
    scope installationProxyClient = new InstallationProxyClient(device, installationProxyService);

    scope misagentService = lockdownClient.startService("com.apple.misagent");
    scope misagentClient = new MisagentClient(device, misagentService);

    scope afcService = lockdownClient.startService(AFC_SERVICE_NAME);
    scope afcClient = new AFCClient(device, afcService);

    string stagingDir = "PublicStaging";

    string[] props;
    if (afcClient.getFileInfo(stagingDir, props) == AFCError.AFC_E_SUCCESS) {
        // The directory already exists, there should not be any data in there, so let's delete it
        afcClient.removePathAndContents(stagingDir);
    }
    afcClient.makeDirectory(stagingDir).assertSuccess();

    auto options = dict(
        "PackageType", "Developer"
    );

    auto remoteAppFolder = stagingDir.buildPath(baseName(app.bundleDir)).toForwardSlashes();
    if (afcClient.getFileInfo(remoteAppFolder, props) != AFCError.AFC_E_SUCCESS) {
        // The directory does not exist, so let's create it!
        afcClient.makeDirectory(remoteAppFolder).assertSuccess();
    }

    auto files = file.dirEntries(app.bundleDir, file.SpanMode.breadth).array();
    // 75% of the last step is sending the files.
    auto transferStep = 3 / (STEP_COUNT * files.length * 4);

    foreach (f; files) {
        auto remotePath = remoteAppFolder.buildPath(f.asRelativePath(app.bundleDir).array()).toForwardSlashes();
        if (f.isDir()) {
            afcClient.makeDirectory(remotePath);
        } else {
            auto remoteFile = afcClient.open(remotePath, AFCFileMode.AFC_FOPEN_WRONLY);
            scope(exit) afcClient.close(remoteFile);

            ubyte[] fileData = cast(ubyte[]) file.read(f);
            uint bytesWrote = 0;
            while (bytesWrote < fileData.length) {
                bytesWrote += afcClient.write(remoteFile, fileData);
            }
        }
        progress += transferStep;
        progressCallback(progress, "Installing the application on the device (Transfer)");
    }

    // This is negligible in terms of time
    foreach (profile; provisioningProfiles.values()) {
        misagentClient.install(new PlistData(profile.encodedProfile));
    }

    Tid parentTid = thisTid();
    installationProxyClient.install(remoteAppFolder, options, (command, statusPlist) {
        try {
            auto status = statusPlist.dict();
            if (auto statusEntry = "Status" in status) {
                if (statusEntry.str().native() == "Complete") {
                    parentTid.send(null);
                    return;
                }

                progressCallback(
                    progress + (status["PercentComplete"].uinteger().native() / (400.0 * STEP_COUNT)),
                    format!"Installing the application on the device (%s)"(statusEntry.str().native())
                );
            } else {
                auto errorPlist = "Error" in status;
                auto descriptionPlist = "ErrorDescription" in status;
                auto detailPlist = "ErrorDetail" in status;
                throw new AppInstallationException(
                    errorPlist ? errorPlist.str().native() : "(null)",
                    descriptionPlist ? descriptionPlist.str().native() : "(null)",
                    detailPlist ? cast(long) detailPlist.uinteger().native() : -1
                );
            }
        } catch (Exception t) {
            parentTid.send(cast(immutable) t);
        }
    });
    receive(
            (immutable(Exception) t) => throw cast() t,
            (typeof(null)) {}
    );

    // Record the successful install in the persistent registry so a later run
    // knows which apps are installed and when each expires, without contacting
    // Apple. Non-fatal: a registry failure must never fail the install.
    try {
        import std.datetime : Clock;
        import persistence = app.persistence;

        auto registry = persistence.loadInstalledRegistry(configurationPath);
        auto record = persistence.InstalledApp(
            mainAppBundleId,
            team.teamId,
            certIdentity.publicKeyFingerprint(),
            Clock.currTime().toISOExtString(),
            // A permanent (CoreTrust-bypass) install never expires, so record an
            // empty expiry; the refresh daemon also keys off `permanent` directly.
            permanent ? "" : mainAppId.expirationDate.toISOExtString(),
            app.sourcePath,
            mainAppName,
        );
        record.permanent = permanent;
        registry.upsert(record);
        persistence.saveInstalledRegistry(configurationPath, registry);

        // Also remember the account + cert/profile metadata in state.json.
        auto state = persistence.loadState(configurationPath);
        state.upsertAccount(developer.appleId);
        state.upsertCertificate(persistence.CachedCertificate(
            team.teamId,
            "",
            certIdentity.publicKeyFingerprint(),
            buildPath("certs", team.teamId, "cert.pem"),
        ));
        if (auto mainProfile = mainAppIdStr in provisioningProfiles) {
            state.upsertProfile(persistence.CachedProfile(
                mainAppBundleId,
                team.teamId,
                mainProfile.provisioningProfileId,
                mainProfile.name,
                mainAppId.expirationDate.toISOExtString(),
            ));
        }
        persistence.saveState(configurationPath, state);
    } catch (Exception e) {
        log.warnF!"Could not record install in the persistence layer: %s"(e.msg);
    }

    progressCallback(1.0, "Done!");
}

/**
 * Re-stamps every Mach-O executable in the bundle with the TrollStore 2 CoreTrust
 * bypass (CVE-2023-41991), so the app passes on-device signature validation
 * without a (renewable) development provisioning profile (#19).
 *
 * Runs AFTER the normal `sign` pass: the bypass replaces the code-signature blob
 * produced by signing. It patches the main app executable and each sub-bundle's
 * executable (frameworks / app extensions), mirroring what `sideloader trollsign`
 * does for a single Mach-O. Only the device's main image needs it strictly, but
 * patching the whole bundle keeps every embedded binary self-consistent.
 *
 * Caller responsibility: this must only be used on a device whose iOS version is
 * within the vulnerable range (`sideload.coretrust.isCoreTrustBypassable`).
 */
private void applyCoreTrustBypass(Application app) {
    import sideload.bundle : Bundle;
    import sideload.ct_bypass : bypassCoreTrust;
    import sideload.macho : MachO, makeMachO;

    auto log = getLogger();

    void patchBundle(Bundle bundle) {
        if (auto execEntry = "CFBundleExecutable" in bundle.appInfo) {
            string executableName = execEntry.str().native();
            string executablePath = bundle.bundleDir.buildPath(executableName);
            if (file.exists(executablePath)) {
                MachO[] machOs = MachO.parse(cast(ubyte[]) file.read(executablePath));
                foreach (ref machO; machOs) {
                    machO.bypassCoreTrust();
                }
                file.write(executablePath, makeMachO(machOs));
                log.debugF!"Applied CoreTrust bypass to `%s`."(executableName);
            }
        }

        foreach (sub; bundle.subBundles()) {
            patchBundle(sub);
        }
    }

    patchBundle(app);
}

class NoAppIdRemainingException: Exception {
    this(DateTime minExpirationDate, string file = __FILE__, int line = __LINE__) {
        super(format!"Cannot make any more app ID, you have to wait until %s to get a new app ID"(minExpirationDate.toSimpleString()), file, line);
    }
}

class AppInstallationException: Exception {
    this(string error, string description, long detail, string file = __FILE__, int line = __LINE__) {
        super(format!"Cannot install the application on the device! %s: %s (%d)"(error, description, detail), file, line);
    }
}
