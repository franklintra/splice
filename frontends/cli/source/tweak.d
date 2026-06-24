module tweak;

import std.algorithm.iteration : map;
import std.array : array;
import file = std.file;
import std.path;
import std.string;
import std.zip;

import slf4d;

import argparse;
import progress;

import imobiledevice;

import sideload;
import sideload.application;
import sideload.tweak;

import cli_frontend;
import jsonout;
import ui;

@(Command("tweak").Description(
    "Inject tweaks (.dylib or .deb) into an IPA before signing. "
    ~ "Writes a new patched IPA by default, or signs and installs it on a device with --install."))
struct TweakCommand
{
    mixin LoginCommand;

    @(PositionalArgument(0, "app path").Description("The path of the IPA file to inject the tweaks into."))
    string appPath;

    @(NamedArgument("inject").Description("A tweak to inject (.dylib or .deb). Repeatable.").Required())
    string[] inject;

    @(NamedArgument("o", "output").Description(
        "Write the patched IPA here. Defaults to ./<name>-tweaked.ipa when neither --output nor --install is given."))
    string output = null;

    @(NamedArgument("install").Description("Sign the tweaked app and install it on a connected device (like `install`)."))
    bool install = false;

    @(NamedArgument("team").Description("Team ID (if your account belongs to several teams). Only used with --install."))
    string teamId = null;

    @(NamedArgument("udid").Description("UDID of the device (if multiple are available). Only used with --install."))
    string udid = null;

    @(NamedArgument("wifi", "prefer-network").Description("Prefer connecting over Wi-Fi when installing (only used with --install)."))
    bool wifi = false;

    @(NamedArgument("singlethread").Description("Run the signature process on a single thread. Only used with --install."))
    bool singlethreaded;

    int opCall()
    {
        auto log = getLogger();

        Application app = openApp(appPath);

        // Inject the tweaks into the extracted bundle (patches the main executable).
        injectTweaks(app, inject);

        if (install) {
            return installTweaked(app, log);
        }

        // Default to ./<name>-tweaked.ipa when no explicit output was requested.
        string outputPath = output;
        if (outputPath.length == 0) {
            outputPath = baseName(appPath).stripExtension() ~ "-tweaked.ipa";
        }

        repackageIpa(app, outputPath);
        app.cleanup();
        log.infoF!"Wrote tweaked IPA to %s"(outputPath);

        if (g_jsonOutput) {
            import std.json : JSONValue;
            printJson(JSONValue([
                "status": JSONValue("ok"),
                "output": JSONValue(outputPath),
                "injected": JSONValue(inject.length),
            ]));
        }

        return 0;
    }

    private int installTweaked(Application app, Logger log)
    {
        auto session = makeSession();
        if (!session)
            return 1;
        string configurationPath = session.configurationPath;
        auto appleAccount = session.developerSession;

        auto team = selectTeamInteractive(session, teamId);

        string chosenUdid, transportLabel;
        auto device = selectConnectedDevice(this.udid, wifi, chosenUdid, transportLabel);
        if (!device)
            return 1;

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
        }, !singlethreaded, team.teamId);
        if (progressBar !is null)
            progressBar.finish();

        if (g_jsonOutput) {
            import std.json : JSONValue;
            printJson(JSONValue([
                "status": JSONValue("ok"),
                "bundleId": JSONValue(app.bundleIdentifier()),
                "injected": JSONValue(inject.length),
            ]));
        }

        return 0;
    }
}

/**
 * Repackages an (already-extracted, tweaked) application bundle into a fresh IPA
 * at `outputPath`. The bundle is zipped back under `Payload/<App.app>/...`,
 * mirroring the layout produced when the IPA was opened.
 */
private void repackageIpa(Application app, string outputPath)
{
    auto zip = new ZipArchive();
    string appFolderName = baseName(app.bundleDir);

    foreach (entry; file.dirEntries(app.bundleDir, file.SpanMode.breadth))
    {
        if (!entry.isFile)
            continue;

        // Path inside the archive: Payload/<App.app>/<relative path>.
        string relative = entry.asRelativePath(app.bundleDir).array().idup;
        string archivePath = buildPath("Payload", appFolderName, relative);

        auto member = new ArchiveMember();
        member.name = archivePath.replace("\\", "/");
        member.expandedData(cast(ubyte[]) file.read(entry.name));
        member.compressionMethod = CompressionMethod.deflate;
        zip.addMember(member);
    }

    auto outputDir = dirName(outputPath);
    if (outputDir.length && !file.exists(outputDir))
        file.mkdirRecurse(outputDir);

    file.write(outputPath, zip.build());
}
