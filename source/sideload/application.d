module sideload.application;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import file = std.file;
import std.parallelism;
import std.path;
import std.string;
import std.uuid;
import std.zip;

import slf4d;

import plist;

import server.developersession;
import sideload.bundle;
import sideload.plugin;

class Application: Bundle {
    string tempPath;
    /// The path the application was opened from (the source IPA when opened from
    /// a file, otherwise the app bundle folder). Used by the installed-apps
    /// registry to remember where to re-sign from later.
    string sourcePath;

    this(string path) {
        sourcePath = path;
        if (file.isFile(path)) {
            // Use a unique temp directory per Application so concurrent runs (or
            // two installs of IPAs sharing the same base name) never collide.
            tempPath = file.tempDir().buildPath("Sideloader-" ~ randomUUID().toString());
            file.mkdirRecurse(tempPath);
            auto ipa = new ZipArchive(file.read(path));

            foreach (kv; parallel(ipa.directory().byKeyValue())) {
                auto k = kv.key;
                auto v = kv.value;

                auto entryPath = tempPath.buildPath(k);
                if (k[$ - 1] != '/') {
                    auto dirname = dirName(entryPath);
                    if (!file.exists(dirname)) {
                        file.mkdirRecurse(dirname);
                    }
                    file.write(entryPath, ipa.expand(v));
                }
            }

            auto payloadFolder = tempPath.buildPath("Payload");
            assertBundle(file.exists(payloadFolder), "No Payload folder!");

            auto apps = file.dirEntries(payloadFolder, file.SpanMode.shallow)
                .filter!(
                    folder =>
                        folder[$ - 4..$] == ".app" ||
                        folder[$ - 5..$] == ".app/" // It should not happen, but just in case
                ).array;
            assertBundle(apps.length == 1, "No or too many application folder!");

            path = apps[0];
        }

        super(path);
    }

    ~this() {
        // Intentionally empty: file I/O in the GC destructor is unreliable in D.
        // Callers must invoke cleanup() explicitly once the temp dir is no longer
        // needed (see sideloadFull).
    }

    /// Removes the extraction temp directory if it exists. Idempotent and
    /// non-fatal: safe to call more than once, and a failure is logged rather
    /// than thrown so it can never abort an otherwise successful install.
    void cleanup() {
        if (tempPath && file.exists(tempPath)) {
            try {
                file.rmdirRecurse(tempPath);
            } catch (Exception e) {
                getLogger().warnF!"Could not remove temporary extraction directory %s: %s"(tempPath, e.msg);
            }
        }
        tempPath = null;
    }

    /// Fetches a mobileprovision file for the app
    void provisionApplication(DeveloperSession account, DeveloperTeam team) {
        auto appBundleIdentifier = appInfo["CFBundleIdentifier"].str().native();
        getLogger().debugF!"AppID: %s.%s"(appBundleIdentifier, team.teamId);
    }
}
