module app.sources;

/**
 * AltStore-style "source" (a.k.a. catalog / repo) support (#17).
 *
 * An AltStore / SideStore *source* is a plain JSON document that lists a number
 * of installable apps. Pointing Sideloader at one lets the user browse and
 * install apps without manually downloading IPAs.
 *
 * The format has two historical shapes for a per-app version:
 *
 *   - legacy single-version form, with top-level `version` / `downloadURL` /
 *     `versionDate` / `size` fields on the app object; and
 *   - the newer `versions` array (newest first), where each entry carries its
 *     own `version` / `date` / `downloadURL` / `size` / `localizedDescription`.
 *
 * `parseSource` tolerates BOTH: when an app has no `versions` array but does
 * carry a top-level `downloadURL`/`version`, one synthetic `SourceAppVersion`
 * is created from those fields. All fields are optional and parsed defensively
 * (a missing or wrong-typed field yields a sensible default rather than an
 * exception) so a partially-malformed source still yields whatever apps it can.
 *
 * Parsing is pure (`parseSource(JSONValue)` / `parseSource(string)`) so it is
 * unit-tested offline; `fetchSource(url)` does the network GET (mirroring the
 * `requests` usage in `server.anisette`) and feeds the body to the parser.
 */

import std.algorithm.iteration : map;
import std.array : array;
import std.format : format;
import std.json;

import slf4d;

import requests;

/// One concrete downloadable version of an app in a source.
struct SourceAppVersion {
    /// The version string, e.g. "1.2.3". (`version` is a D keyword, hence `version_`.)
    string version_;
    /// Release date as written in the source (ISO-ish string). May be empty.
    string date;
    /// Direct URL of the IPA to download. The load-bearing field.
    string downloadURL;
    /// Size in bytes, if the source advertises it (0 = unknown).
    long size;
    /// Per-version changelog / description, if present.
    string localizedDescription;
}

/// One app entry within a source.
struct SourceApp {
    string name;
    string bundleIdentifier;
    string developerName;
    string localizedDescription;
    string iconURL;
    /// Versions newest-first. Always at least the synthesized legacy version
    /// when the source used the single-version form and a downloadURL existed.
    SourceAppVersion[] versions;
}

/// A parsed source document.
struct Source {
    string name;
    string identifier;
    string sourceURL;
    SourceApp[] apps;
}

/// Raised when a source cannot be fetched or parsed.
class SourceException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

/**
 * Returns the latest (newest) version of an app: the first `versions` entry, or
 * a default-constructed `SourceAppVersion` when the app advertises none.
 */
SourceAppVersion latestVersion(SourceApp app) {
    if (app.versions.length)
        return app.versions[0];
    return SourceAppVersion.init;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Parses a source JSON string. Throws `SourceException` on invalid JSON.
Source parseSource(string jsonBody, string sourceLabel = "<source>") {
    JSONValue json;
    try {
        json = parseJSON(jsonBody);
    } catch (Exception e) {
        throw new SourceException(
            format!"Source %s returned invalid JSON: %s"(sourceLabel, e.msg)
        );
    }
    return parseSource(json, sourceLabel);
}

/// Parses an already-decoded source JSON document. Throws on a non-object root.
Source parseSource(JSONValue json, string sourceLabel = "<source>") {
    if (json.type != JSONType.object) {
        throw new SourceException(
            format!"Source %s did not return a JSON object."(sourceLabel)
        );
    }

    Source src;
    src.name = json.getStr("name");
    src.identifier = json.getStr("identifier");
    src.sourceURL = json.getStr("sourceURL");

    foreach (appJson; json.getArray("apps")) {
        if (appJson.type != JSONType.object)
            continue;
        src.apps ~= parseApp(appJson);
    }

    return src;
}

private SourceApp parseApp(JSONValue v) {
    SourceApp app;
    app.name = v.getStr("name");
    app.bundleIdentifier = v.getStr("bundleIdentifier");
    app.developerName = v.getStr("developerName");
    app.localizedDescription = v.getStr("localizedDescription");
    app.iconURL = v.getStr("iconURL");

    // Newer form: a `versions` array, newest first.
    foreach (verJson; v.getArray("versions")) {
        if (verJson.type != JSONType.object)
            continue;
        app.versions ~= parseVersion(verJson);
    }

    // Legacy single-version form: synthesize one version from the top-level
    // fields when there was no `versions` array but a downloadURL is present.
    if (app.versions.length == 0) {
        auto legacyUrl = v.getStr("downloadURL");
        auto legacyVer = v.getStr("version");
        if (legacyUrl.length || legacyVer.length) {
            SourceAppVersion sv;
            sv.version_ = legacyVer;
            sv.date = v.getStr("versionDate");
            sv.downloadURL = legacyUrl;
            sv.size = v.getLong("size");
            // Fall back to the app's own description for the version changelog.
            sv.localizedDescription = app.localizedDescription;
            app.versions ~= sv;
        }
    }

    return app;
}

private SourceAppVersion parseVersion(JSONValue v) {
    SourceAppVersion sv;
    sv.version_ = v.getStr("version");
    sv.date = v.getStr("date");
    sv.downloadURL = v.getStr("downloadURL");
    sv.size = v.getLong("size");
    sv.localizedDescription = v.getStr("localizedDescription");
    return sv;
}

// ---------------------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------------------

/**
 * Fetches and parses a source from a URL over HTTPS.
 *
 * Validates the server's TLS certificate (MITM-resistant), mirroring the
 * `requests` usage in `server.anisette`. Throws `SourceException` with a clear
 * message on any network or parse failure.
 */
Source fetchSource(string url) {
    auto log = getLogger();
    log.debugF!"Fetching source from %s"(url);

    Request request = Request();
    request.sslSetVerifyPeer(true);

    string body_;
    try {
        auto response = request.get(url);
        if (response.code != 200) {
            throw new SourceException(
                format!"Source %s returned HTTP %d."(url, response.code)
            );
        }
        body_ = response.responseBody().data!string();
    } catch (SourceException e) {
        throw e;
    } catch (Exception e) {
        throw new SourceException(
            format!"Could not reach source %s: %s"(url, e.msg)
        );
    }

    return parseSource(body_, url);
}

// ---------------------------------------------------------------------------
// JSON helpers: tolerant accessors (mirrors app.persistence)
// ---------------------------------------------------------------------------

private string getStr(JSONValue v, string key, string fallback = "") {
    if (v.type != JSONType.object) return fallback;
    if (auto p = key in v.object) {
        if (p.type == JSONType.string) return p.str;
    }
    return fallback;
}

private long getLong(JSONValue v, string key, long fallback = 0) {
    if (v.type != JSONType.object) return fallback;
    if (auto p = key in v.object) {
        if (p.type == JSONType.integer) return p.integer;
        if (p.type == JSONType.uinteger) return cast(long) p.uinteger;
    }
    return fallback;
}

private JSONValue[] getArray(JSONValue v, string key) {
    if (v.type != JSONType.object) return [];
    if (auto p = key in v.object) {
        if (p.type == JSONType.array) return p.array;
    }
    return [];
}

// ---------------------------------------------------------------------------
// unittests
// ---------------------------------------------------------------------------

unittest {
    // Newer `versions[]` form: latest = first entry.
    auto sample = `{
        "name": "My Repo",
        "identifier": "com.example.repo",
        "sourceURL": "https://example.com/repo.json",
        "apps": [
            {
                "name": "Some App",
                "bundleIdentifier": "com.example.app",
                "developerName": "Dev",
                "localizedDescription": "An app.",
                "iconURL": "https://example.com/icon.png",
                "versions": [
                    {
                        "version": "1.2.3",
                        "date": "2024-02-01",
                        "downloadURL": "https://example.com/app-1.2.3.ipa",
                        "size": 12345,
                        "localizedDescription": "Newest."
                    },
                    {
                        "version": "1.2.2",
                        "date": "2024-01-01",
                        "downloadURL": "https://example.com/app-1.2.2.ipa",
                        "size": 100
                    }
                ]
            }
        ],
        "news": [ {"title": "ignored"} ]
    }`;

    auto src = parseSource(sample, "test");
    assert(src.name == "My Repo");
    assert(src.identifier == "com.example.repo");
    assert(src.sourceURL == "https://example.com/repo.json");
    assert(src.apps.length == 1);

    auto app = src.apps[0];
    assert(app.name == "Some App");
    assert(app.bundleIdentifier == "com.example.app");
    assert(app.developerName == "Dev");
    assert(app.iconURL == "https://example.com/icon.png");
    assert(app.versions.length == 2);

    auto latest = latestVersion(app);
    assert(latest.version_ == "1.2.3");
    assert(latest.downloadURL == "https://example.com/app-1.2.3.ipa");
    assert(latest.size == 12345);
    assert(latest.date == "2024-02-01");
    assert(latest.localizedDescription == "Newest.");
}

unittest {
    // Legacy single-version form: synthesize one version from top-level fields.
    auto sample = `{
        "name": "Legacy Repo",
        "apps": [
            {
                "name": "Legacy App",
                "bundleIdentifier": "com.example.legacy",
                "developerName": "Old Dev",
                "version": "0.9.0",
                "versionDate": "2020-05-05",
                "downloadURL": "https://example.com/legacy.ipa",
                "size": 999,
                "localizedDescription": "A legacy app."
            }
        ]
    }`;

    auto src = parseSource(sample, "test");
    assert(src.name == "Legacy Repo");
    assert(src.apps.length == 1);

    auto app = src.apps[0];
    assert(app.bundleIdentifier == "com.example.legacy");
    assert(app.versions.length == 1); // synthesized

    auto latest = latestVersion(app);
    assert(latest.version_ == "0.9.0");
    assert(latest.date == "2020-05-05");
    assert(latest.downloadURL == "https://example.com/legacy.ipa");
    assert(latest.size == 999);
    // Falls back to the app's description for the synthesized version.
    assert(latest.localizedDescription == "A legacy app.");
}

unittest {
    // Defensive: missing fields, wrong-typed apps array, an app without any
    // version info all parse without throwing.
    auto src = parseSource(`{
        "apps": [
            {"name": "No Versions", "bundleIdentifier": "com.x.noversions"},
            "not an object",
            {"name": "Has URL only", "bundleIdentifier": "com.x.url", "downloadURL": "https://x/y.ipa"}
        ]
    }`, "test");
    assert(src.name == "");
    assert(src.apps.length == 2); // the string entry is skipped

    assert(src.apps[0].bundleIdentifier == "com.x.noversions");
    assert(src.apps[0].versions.length == 0); // nothing to synthesize
    assert(latestVersion(src.apps[0]).downloadURL == "");

    assert(src.apps[1].versions.length == 1);
    assert(latestVersion(src.apps[1]).downloadURL == "https://x/y.ipa");

    // Empty object yields an empty source, no throw.
    auto empty = parseSource("{}", "test");
    assert(empty.apps.length == 0);
}

unittest {
    // Non-JSON and non-object roots are rejected with SourceException.
    bool threwGarbage = false;
    try { parseSource("not json", "test"); }
    catch (SourceException) { threwGarbage = true; }
    assert(threwGarbage);

    bool threwArray = false;
    try { parseSource("[1, 2, 3]", "test"); }
    catch (SourceException) { threwArray = true; }
    assert(threwArray);
}
