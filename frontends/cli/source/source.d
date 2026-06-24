module sources;

/**
 * `sideloader source <add|remove|list|browse|install>` (#17).
 *
 * Manages subscriptions to AltStore-style JSON sources (catalogs / repos) and
 * lets the user browse and install apps from them without manually downloading
 * an IPA. The source model + parser live in `app.sources`; subscribed source
 * URLs are persisted in `state.json` (`SideloaderState.sources`).
 *
 * `source install` fetches the chosen app's latest IPA to a temp file (streamed
 * with a progress bar, like `app.downloadAndInstallDeps`) and then runs the
 * normal sign+install flow (`makeSession` + device selection + `sideloadFull`),
 * cleaning up the temp IPA afterwards.
 */

import std.algorithm.searching : canFind;
import std.array : array;
import std.format : format;
import std.path : buildPath, baseName;
import std.stdio;
import std.string : strip, toLower, indexOf, endsWith;
import std.sumtype;
import std.uuid : randomUUID;
import file = std.file;

import slf4d;

import argparse;
import progress;

import requests;

import imobiledevice;

import sideload;
import sideload.application;

import app.persistence : loadState, saveState, SideloaderState;
import app.sources;
import app.session : systemConfigurationPath;

import cli_frontend;
import jsonout;

@(Command("source").Description("Manage AltStore-style sources (catalogs) and install apps from them."))
struct SourceCommand
{
    int opCall()
    {
        return cmd.match!(
                (SourceAdd cmd) => cmd(),
                (SourceRemove cmd) => cmd(),
                (SourceList cmd) => cmd(),
                (SourceBrowse cmd) => cmd(),
                (SourceInstall cmd) => cmd()
        );
    }

    @SubCommands
    SumType!(SourceAdd, SourceRemove, SourceList, SourceBrowse, SourceInstall) cmd;
}

@(Command("add").Description("Subscribe to a source by URL (validates that it parses)."))
struct SourceAdd
{
    @(PositionalArgument(0, "url").Description("The URL of the source JSON document."))
    string url;

    int opCall()
    {
        auto log = getLogger();
        string configurationPath = systemConfigurationPath();
        string trimmed = url.strip();

        // Fetch up-front so we don't subscribe to a URL that does not parse.
        Source source;
        try {
            source = fetchSource(trimmed);
        } catch (SourceException e) {
            if (g_jsonOutput) {
                printJsonError(e.msg);
            } else {
                log.errorF!"Could not add source: %s"(e.msg);
            }
            return 1;
        }

        auto state = loadState(configurationPath);
        bool added = state.addSource(trimmed);
        if (added)
            saveState(configurationPath, state);

        if (g_jsonOutput) {
            import std.json : JSONValue;
            printJson(JSONValue([
                "status":   JSONValue(added ? "added" : "already-subscribed"),
                "url":      JSONValue(trimmed),
                "name":     JSONValue(source.name),
                "appCount": JSONValue(source.apps.length),
            ]));
            return 0;
        }

        if (added)
            log.infoF!"Added source `%s` (%d app(s)): %s"(source.name, source.apps.length, trimmed);
        else
            log.infoF!"Already subscribed to `%s` (%d app(s)): %s"(source.name, source.apps.length, trimmed);
        return 0;
    }
}

@(Command("remove").Description("Unsubscribe from a source by URL (idempotent)."))
struct SourceRemove
{
    @(PositionalArgument(0, "url").Description("The URL of the source to remove."))
    string url;

    int opCall()
    {
        auto log = getLogger();
        string configurationPath = systemConfigurationPath();
        string trimmed = url.strip();

        auto state = loadState(configurationPath);
        size_t removed = state.removeSource(trimmed);
        if (removed)
            saveState(configurationPath, state);

        if (g_jsonOutput) {
            import std.json : JSONValue;
            printJson(JSONValue([
                "status": JSONValue(removed ? "removed" : "not-subscribed"),
                "url":    JSONValue(trimmed),
            ]));
            return 0;
        }

        if (removed)
            log.infoF!"Removed source: %s"(trimmed);
        else
            log.infoF!"Not subscribed to: %s"(trimmed);
        return 0;
    }
}

@(Command("list").Description("List subscribed sources."))
struct SourceList
{
    @(NamedArgument("names").Description("Fetch each source to also show its name (network-dependent)."))
    bool names = false;

    int opCall()
    {
        string configurationPath = systemConfigurationPath();
        auto state = loadState(configurationPath);

        if (g_jsonOutput) {
            import std.json : JSONValue;
            JSONValue[] arr;
            foreach (url; state.sources) {
                JSONValue[string] entry = ["url": JSONValue(url)];
                if (names) {
                    try {
                        auto src = fetchSource(url);
                        entry["name"] = JSONValue(src.name);
                        entry["appCount"] = JSONValue(src.apps.length);
                    } catch (SourceException) {
                        entry["name"] = JSONValue("");
                    }
                }
                arr ~= JSONValue(entry);
            }
            printJson(JSONValue(arr));
            return 0;
        }

        if (state.sources.length == 0) {
            writeln("No sources subscribed. Add one with `sideloader source add <url>`.");
            return 0;
        }

        writefln!"%d source(s) subscribed:"(state.sources.length);
        foreach (url; state.sources) {
            if (names) {
                try {
                    auto src = fetchSource(url);
                    writefln!" - %s (%d app(s)): %s"(src.name, src.apps.length, url);
                } catch (SourceException e) {
                    writefln!" - %s (unreachable: %s)"(url, e.msg);
                }
            } else {
                writefln!" - %s"(url);
            }
        }
        return 0;
    }
}

@(Command("browse").Description("List apps available in subscribed sources."))
struct SourceBrowse
{
    @(NamedArgument("source").Description("Limit to one source (its identifier, name or URL)."))
    string source = null;

    @(NamedArgument("search").Description("Only show apps whose name / bundle id contains this text (case-insensitive)."))
    string search = null;

    int opCall()
    {
        auto log = getLogger();
        string configurationPath = systemConfigurationPath();
        auto state = loadState(configurationPath);

        auto sourcesToBrowse = resolveSources(state, this.source, log);

        string needle = search is null ? null : search.strip().toLower();

        if (g_jsonOutput) {
            import std.json : JSONValue;
            JSONValue[] arr;
            foreach (src; sourcesToBrowse) {
                foreach (app; src.apps) {
                    if (!matchesSearch(app, needle))
                        continue;
                    auto latest = latestVersion(app);
                    arr ~= JSONValue([
                        "name":             JSONValue(app.name),
                        "bundleIdentifier": JSONValue(app.bundleIdentifier),
                        "developerName":    JSONValue(app.developerName),
                        "version":          JSONValue(latest.version_),
                        "downloadURL":      JSONValue(latest.downloadURL),
                        "source":           JSONValue(src.name.length ? src.name : src.identifier),
                    ]);
                }
            }
            printJson(JSONValue(arr));
            return 0;
        }

        size_t shown = 0;
        foreach (src; sourcesToBrowse) {
            bool printedHeader = false;
            foreach (app; src.apps) {
                if (!matchesSearch(app, needle))
                    continue;
                if (!printedHeader) {
                    writefln!"# %s"(src.name.length ? src.name : src.identifier);
                    printedHeader = true;
                }
                auto latest = latestVersion(app);
                writefln!" - %s (%s) v%s — %s"(
                    app.name, app.bundleIdentifier,
                    latest.version_.length ? latest.version_ : "?",
                    app.developerName.length ? app.developerName : "unknown");
                shown++;
            }
        }
        if (shown == 0)
            writeln("No apps found.");
        return 0;
    }
}

@(Command("install").Description("Download and install an app from a subscribed source by its bundle id."))
struct SourceInstall
{
    mixin LoginCommand;

    @(PositionalArgument(0, "bundle id").Description("The bundle identifier of the app to install."))
    string bundleId;

    @(NamedArgument("source").Description("Limit the lookup to one source (its identifier, name or URL)."))
    string source = null;

    @(NamedArgument("team").Description("Team ID (if your account belongs to several teams)."))
    string teamId = null;

    @(NamedArgument("udid").Description("UDID of the device (if multiple are available)."))
    string udid = null;

    @(NamedArgument("wifi", "prefer-network").Description("Prefer connecting over Wi-Fi when reachable both over USB and Wi-Fi."))
    bool wifi = false;

    @(NamedArgument("singlethread").Description("Run the signature process on a single thread."))
    bool singlethreaded;

    int opCall()
    {
        auto log = getLogger();
        string configurationPath = systemConfigurationPath();
        auto state = loadState(configurationPath);

        auto sourcesToSearch = resolveSources(state, this.source, log);
        if (sourcesToSearch.length == 0) {
            log.error("No sources to search. Add one with `sideloader source add <url>`.");
            return 1;
        }

        // Find the app by bundle id across the chosen sources.
        SourceApp[] matches;
        string[] matchSourceNames;
        foreach (src; sourcesToSearch) {
            foreach (app; src.apps) {
                if (app.bundleIdentifier == bundleId) {
                    matches ~= app;
                    matchSourceNames ~= src.name.length ? src.name : src.identifier;
                }
            }
        }

        if (matches.length == 0) {
            log.errorF!"No app with bundle id `%s` found in the searched source(s)."(bundleId);
            return 1;
        }
        if (matches.length > 1 && this.source is null) {
            log.warnF!"`%s` is offered by %d sources; using the one from `%s`. Pass --source to disambiguate."(
                bundleId, matches.length, matchSourceNames[0]);
        }

        SourceApp app = matches[0];
        auto latest = latestVersion(app);
        if (latest.downloadURL.length == 0) {
            log.errorF!"App `%s` has no downloadable version."(bundleId);
            return 1;
        }

        // Download the IPA to a stable per-app cache path (NOT a temp file): the
        // install records this path as the app's `sourceIpaPath`, and
        // `refresh`/`daemon` re-open it to re-sign the app before its 7-day
        // profile expires. A temp file deleted right after install could never
        // be refreshed. `uninstall` cleans this cache up.
        string ipaCacheDir = configurationPath.buildPath("source-ipas");
        try { file.mkdirRecurse(ipaCacheDir); } catch (Exception) {}
        string cachedIpa = ipaCacheDir.buildPath(bundleId ~ ".ipa");
        removeQuietly(cachedIpa);

        try {
            downloadIpa(latest.downloadURL, cachedIpa, latest.size);
        } catch (Exception e) {
            removeQuietly(cachedIpa);
            log.errorF!"Could not download IPA: %s"(e.msg);
            return 1;
        }

        // From here on this mirrors `InstallCommand`: open the IPA, log in, pick
        // the team and device, then run the full sign+install flow.
        Application application = openApp(cachedIpa);

        auto session = makeSession();
        if (!session)
            return 1;
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
        sideloadFull(session.configurationPath, device, appleAccount, application, (progress, action) {
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
                "status":   JSONValue("ok"),
                "bundleId": JSONValue(application.bundleIdentifier()),
                "version":  JSONValue(latest.version_),
            ]));
        } else {
            log.infoF!"Installed `%s` v%s."(app.name, latest.version_);
        }
        return 0;
    }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/**
 * Resolves which sources a browse/install should act on.
 *
 * With `--source` given, only the subscribed source whose identifier, name or
 * URL matches is fetched (it must already be subscribed). Without it, every
 * subscribed source is fetched best-effort; ones that fail are skipped with a
 * warning so a single dead repo doesn't break the whole listing.
 */
private Source[] resolveSources(SideloaderState state, string selector, Logger log)
{
    Source[] result;
    foreach (url; state.sources) {
        // When a selector is given and it matches the URL, fetch just this one.
        if (selector !is null && url != selector.strip()) {
            // We still might match by name/identifier, which needs a fetch; do
            // that lazily below.
        }
        Source src;
        try {
            src = fetchSource(url);
        } catch (SourceException e) {
            if (selector is null)
                log.warnF!"Skipping unreachable source %s (%s)."(url, e.msg);
            continue;
        }

        if (selector !is null) {
            auto sel = selector.strip();
            if (url != sel && src.identifier != sel && src.name != sel)
                continue;
        }
        result ~= src;
    }

    if (selector !is null && result.length == 0)
        log.warnF!"No subscribed source matched `%s`."(selector);

    return result;
}

private void removeQuietly(string path)
{
    if (file.exists(path)) {
        try { file.remove(path); } catch (Exception) {}
    }
}

private bool matchesSearch(SourceApp app, string needle)
{
    if (needle is null || needle.length == 0)
        return true;
    return app.name.toLower().canFind(needle)
        || app.bundleIdentifier.toLower().canFind(needle);
}

/**
 * Streams an IPA from `url` to `destPath` with a progress bar (suppressed in
 * `--json` mode). Mirrors the streaming download in `app.downloadAndInstallDeps`.
 */
private void downloadIpa(string url, string destPath, long advertisedSize)
{
    auto log = getLogger();
    log.infoF!"Downloading %s ..."(url);

    Request request = Request();
    request.sslSetVerifyPeer(true);
    request.useStreaming = true;

    auto response = request.get(url);
    if (response.code != 200)
        throw new Exception(format!"server returned HTTP %d"(response.code));

    auto responseStream = response.receiveAsRange();

    float size = cast(float) response.contentLength;
    if (size <= 0)
        size = advertisedSize > 0 ? cast(float) advertisedSize : 0;

    Bar progressBar = g_jsonOutput ? null : new Bar();
    if (progressBar !is null)
        progressBar.message = () => "Downloading";

    auto sink = File(destPath, "wb");
    scope (exit) sink.close();

    while (!responseStream.empty) {
        sink.rawWrite(responseStream.front);
        responseStream.popFront();
        if (progressBar !is null && size > 0) {
            progressBar.index = cast(int) (cast(float) response.contentReceived / size * 100);
            progressBar.update();
        }
    }
    if (progressBar !is null)
        progressBar.finish();

    log.info("Download completed.");
}
