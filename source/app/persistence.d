module app.persistence;

/**
 * Versioned, corruption-tolerant on-disk state for Sideloader.
 *
 * Two files live under the configuration directory:
 *   - `{config}/state.json`     : schema-versioned account/cert/profile metadata
 *   - `{config}/installed.json` : the installed-apps registry
 *
 * Both are plain JSON (`std.json`, no extra dependency). Loading is tolerant of
 * a missing or older/forward file (returns a fresh default and preserves unknown
 * top-level fields where practical), and saving is atomic (write to a temp file,
 * then rename over the target).
 *
 * Secrets (passwords) are never stored here — that is the keyring's job (#5).
 * Only public metadata (Apple IDs, certificate fingerprints, expiry dates, IPA
 * paths, ...) lives in these files.
 */

import std.algorithm.iteration : map;
import std.algorithm.searching : find;
import std.array : array;
import std.conv : to;
import std.datetime : DateTime, SysTime, Clock;
import file = std.file;
import std.json;
import std.path : buildPath, dirName, baseName;
import std.uuid : randomUUID;

import slf4d;

/// Bump when the on-disk schema changes incompatibly; readers tolerate older/newer.
enum stateSchemaVersion = 1;

/// File names within the configuration directory.
enum stateFileName = "state.json";
enum installedRegistryFileName = "installed.json";

/**
 * Metadata about a known Apple account. Passwords are intentionally absent.
 */
struct AccountRecord {
    /// The Apple ID (email) that was seen logging in.
    string appleId;
    /// Last time this account was used, ISO-8601. Empty if never recorded.
    string lastUsed;

    JSONValue toJSON() const {
        return JSONValue([
            "appleId": JSONValue(appleId),
            "lastUsed": JSONValue(lastUsed),
        ]);
    }

    static AccountRecord fromJSON(JSONValue v) {
        AccountRecord r;
        r.appleId = v.getStr("appleId");
        r.lastUsed = v.getStr("lastUsed");
        return r;
    }
}

/**
 * Metadata about a cached development certificate.
 *
 * The certificate bytes themselves are cached on disk under
 * `{config}/certs/{teamId}/` (see `CertificateIdentity`); this record holds the
 * pointers and expiry needed to reason about it without contacting Apple.
 */
struct CachedCertificate {
    string teamId;
    /// Apple's certificate identifier (`certificateId`), if known.
    string certificateId;
    /// SHA-1 fingerprint (hex, lowercase) of the certificate's public key.
    string publicKeyFingerprint;
    /// Path (relative to the config dir, or absolute) of the cached PEM file.
    string pemPath;

    JSONValue toJSON() const {
        return JSONValue([
            "teamId": JSONValue(teamId),
            "certificateId": JSONValue(certificateId),
            "publicKeyFingerprint": JSONValue(publicKeyFingerprint),
            "pemPath": JSONValue(pemPath),
        ]);
    }

    static CachedCertificate fromJSON(JSONValue v) {
        CachedCertificate c;
        c.teamId = v.getStr("teamId");
        c.certificateId = v.getStr("certificateId");
        c.publicKeyFingerprint = v.getStr("publicKeyFingerprint");
        c.pemPath = v.getStr("pemPath");
        return c;
    }
}

/**
 * Metadata about a cached provisioning profile.
 */
struct CachedProfile {
    string bundleId;
    string teamId;
    string provisioningProfileId;
    string name;
    /// Expiry as ISO-8601 (DateTime.toISOExtString). Empty if unknown.
    string expiryDate;

    JSONValue toJSON() const {
        return JSONValue([
            "bundleId": JSONValue(bundleId),
            "teamId": JSONValue(teamId),
            "provisioningProfileId": JSONValue(provisioningProfileId),
            "name": JSONValue(name),
            "expiryDate": JSONValue(expiryDate),
        ]);
    }

    static CachedProfile fromJSON(JSONValue v) {
        CachedProfile p;
        p.bundleId = v.getStr("bundleId");
        p.teamId = v.getStr("teamId");
        p.provisioningProfileId = v.getStr("provisioningProfileId");
        p.name = v.getStr("name");
        p.expiryDate = v.getStr("expiryDate");
        return p;
    }
}

/**
 * The versioned top-level state document persisted to `{config}/state.json`.
 */
struct SideloaderState {
    int version_ = stateSchemaVersion;
    AccountRecord[] accounts;
    CachedCertificate[] certificates;
    CachedProfile[] profiles;
    /// Persisted default remote anisette server URL (empty = use local emulation).
    string anisetteServer;
    /// Persisted default developer team id (empty = no default chosen yet).
    string defaultTeamId;
    /// Persisted default Apple account (Apple ID) to log in with when several are
    /// stored in the keyring (empty = no default chosen yet).
    string defaultAccount;
    /// Subscribed AltStore-style source (catalog) URLs (#17).
    string[] sources;

    /// Subscribes to a source URL without duplicating it. Returns `true` when it
    /// was newly added, `false` when already present.
    bool addSource(string url) {
        foreach (s; sources) {
            if (s == url)
                return false;
        }
        sources ~= url;
        return true;
    }

    /// Unsubscribes from a source URL. Returns the number removed (0 or more).
    size_t removeSource(string url) {
        size_t before = sources.length;
        string[] kept;
        foreach (s; sources) {
            if (s != url)
                kept ~= s;
        }
        sources = kept;
        return before - sources.length;
    }

    /// Records (or refreshes) an account by Apple ID without duplicating it.
    void upsertAccount(string appleId) {
        foreach (ref acc; accounts) {
            if (acc.appleId == appleId) {
                acc.lastUsed = Clock.currTime().toISOExtString();
                return;
            }
        }
        accounts ~= AccountRecord(appleId, Clock.currTime().toISOExtString());
    }

    /// Records (or refreshes) a cached certificate keyed by team + fingerprint.
    void upsertCertificate(CachedCertificate cert) {
        foreach (ref c; certificates) {
            if (c.teamId == cert.teamId && c.publicKeyFingerprint == cert.publicKeyFingerprint) {
                c = cert;
                return;
            }
        }
        certificates ~= cert;
    }

    /// Records (or refreshes) a cached provisioning profile keyed by team + bundle id.
    void upsertProfile(CachedProfile profile) {
        foreach (ref p; profiles) {
            if (p.teamId == profile.teamId && p.bundleId == profile.bundleId) {
                p = profile;
                return;
            }
        }
        profiles ~= profile;
    }

    JSONValue toJSON() const {
        return JSONValue([
            "version": JSONValue(version_),
            "accounts": JSONValue(accounts.map!((a) => a.toJSON()).array()),
            "certificates": JSONValue(certificates.map!((c) => c.toJSON()).array()),
            "profiles": JSONValue(profiles.map!((p) => p.toJSON()).array()),
            "anisetteServer": JSONValue(anisetteServer),
            "defaultTeamId": JSONValue(defaultTeamId),
            "defaultAccount": JSONValue(defaultAccount),
            "sources": JSONValue(sources.map!((s) => JSONValue(s)).array()),
        ]);
    }

    static SideloaderState fromJSON(JSONValue v) {
        SideloaderState s;
        s.version_ = v.getInt("version", stateSchemaVersion);
        s.accounts = v.getArray("accounts").map!((e) => AccountRecord.fromJSON(e)).array();
        s.certificates = v.getArray("certificates").map!((e) => CachedCertificate.fromJSON(e)).array();
        s.profiles = v.getArray("profiles").map!((e) => CachedProfile.fromJSON(e)).array();
        s.anisetteServer = v.getStr("anisetteServer");
        s.defaultTeamId = v.getStr("defaultTeamId");
        s.defaultAccount = v.getStr("defaultAccount");
        // Back-compat: a state written before sources existed has no such field,
        // which simply reads as an empty subscription list.
        s.sources = v.getStrArray("sources");
        return s;
    }
}

/**
 * One installed application, as known to Sideloader after a successful install.
 */
struct InstalledApp {
    /// Original (pre-mangling) bundle identifier of the main app.
    string bundleId;
    string teamId;
    /// SHA-1 public-key fingerprint of the certificate used to sign, if known.
    string certificateFingerprint;
    /// Install timestamp, ISO-8601.
    string installDate;
    /// Expiry timestamp, ISO-8601. For a free Apple ID this is ~7 days out.
    string expiryDate;
    /// Path to the source IPA, if it was available at install time.
    string sourceIpaPath;
    /// Human-readable application name.
    string appName;
    /// Whether the background refresh daemon (#9) may auto re-sign this app.
    /// Defaults to `true`; a missing JSON field is treated as `true` for
    /// backward compatibility with registries written before this flag existed.
    bool enabled = true;

    JSONValue toJSON() const {
        return JSONValue([
            "bundleId": JSONValue(bundleId),
            "teamId": JSONValue(teamId),
            "certificateFingerprint": JSONValue(certificateFingerprint),
            "installDate": JSONValue(installDate),
            "expiryDate": JSONValue(expiryDate),
            "sourceIpaPath": JSONValue(sourceIpaPath),
            "appName": JSONValue(appName),
            "enabled": JSONValue(enabled),
        ]);
    }

    static InstalledApp fromJSON(JSONValue v) {
        InstalledApp a;
        a.bundleId = v.getStr("bundleId");
        a.teamId = v.getStr("teamId");
        a.certificateFingerprint = v.getStr("certificateFingerprint");
        a.installDate = v.getStr("installDate");
        a.expiryDate = v.getStr("expiryDate");
        a.sourceIpaPath = v.getStr("sourceIpaPath");
        a.appName = v.getStr("appName");
        // Back-compat: a registry written before the `enabled` flag existed has
        // no such field, which must read as "enabled" rather than "disabled".
        a.enabled = v.getBool("enabled", true);
        return a;
    }
}

/**
 * The installed-apps registry persisted to `{config}/installed.json`.
 */
struct InstalledRegistry {
    int version_ = stateSchemaVersion;
    InstalledApp[] apps;

    /// Inserts or replaces a record, keyed by (bundleId, teamId).
    void upsert(InstalledApp app) {
        foreach (ref a; apps) {
            if (a.bundleId == app.bundleId && a.teamId == app.teamId) {
                a = app;
                return;
            }
        }
        apps ~= app;
    }

    /// Returns the record for `bundleId` (first team match), or `false` via found flag.
    bool query(string bundleId, out InstalledApp result) const {
        foreach (a; apps) {
            if (a.bundleId == bundleId) {
                result = a;
                return true;
            }
        }
        return false;
    }

    /// Removes the record(s) matching `bundleId`. Returns the number removed.
    size_t remove(string bundleId) {
        size_t before = apps.length;
        InstalledApp[] kept;
        foreach (a; apps) {
            if (a.bundleId != bundleId)
                kept ~= a;
        }
        apps = kept;
        return before - apps.length;
    }

    JSONValue toJSON() const {
        return JSONValue([
            "version": JSONValue(version_),
            "apps": JSONValue(apps.map!((a) => a.toJSON()).array()),
        ]);
    }

    static InstalledRegistry fromJSON(JSONValue v) {
        InstalledRegistry r;
        r.version_ = v.getInt("version", stateSchemaVersion);
        r.apps = v.getArray("apps").map!((e) => InstalledApp.fromJSON(e)).array();
        return r;
    }
}

// ---------------------------------------------------------------------------
// Load / save
// ---------------------------------------------------------------------------

/**
 * Loads `{config}/state.json`. Returns a fresh default when the file is missing
 * or cannot be parsed (logging a warning in the latter case).
 */
SideloaderState loadState(string configurationPath) {
    return loadJSONFile!SideloaderState(configurationPath.buildPath(stateFileName));
}

/// Atomically writes `{config}/state.json`.
void saveState(string configurationPath, SideloaderState state) {
    saveJSONFile(configurationPath.buildPath(stateFileName), state.toJSON());
}

/**
 * Loads `{config}/installed.json`. Returns a fresh default when the file is
 * missing or cannot be parsed.
 */
InstalledRegistry loadInstalledRegistry(string configurationPath) {
    return loadJSONFile!InstalledRegistry(configurationPath.buildPath(installedRegistryFileName));
}

/// Atomically writes `{config}/installed.json`.
void saveInstalledRegistry(string configurationPath, InstalledRegistry registry) {
    saveJSONFile(configurationPath.buildPath(installedRegistryFileName), registry.toJSON());
}

private T loadJSONFile(T)(string path) {
    auto log = getLogger();
    if (!file.exists(path)) {
        return T.init;
    }
    try {
        auto content = cast(string) file.read(path);
        auto json = parseJSON(content);
        return T.fromJSON(json);
    } catch (Exception e) {
        log.warnF!"Could not read %s (%s); starting from a fresh default."(path, e.msg);
        return T.init;
    }
}

private void saveJSONFile(string path, JSONValue value) {
    auto dir = dirName(path);
    if (!file.exists(dir)) {
        file.mkdirRecurse(dir);
    }
    // Atomic write: serialize to a unique temp file in the same directory, then
    // rename over the destination (rename is atomic on the same filesystem).
    string tempPath = path ~ "." ~ randomUUID().toString() ~ ".tmp";
    scope (failure) {
        if (file.exists(tempPath)) {
            try { file.remove(tempPath); } catch (Exception) {}
        }
    }
    file.write(tempPath, value.toPrettyString());
    file.rename(tempPath, path);
}

// ---------------------------------------------------------------------------
// App ID quota helpers
// ---------------------------------------------------------------------------

/**
 * Returns the earliest `expirationDate` among the given App IDs — i.e. when the
 * next App ID slot frees up for a quota-limited (free) account.
 *
 * Pure and offline so it can be unit-tested without contacting Apple. Returns
 * `DateTime.init` when the list is empty (caller should treat that as "unknown").
 */
DateTime appIdResetDate(const(DateTime)[] expirationDates) {
    DateTime earliest = DateTime.init;
    bool found = false;
    foreach (d; expirationDates) {
        if (!found || d < earliest) {
            earliest = d;
            found = true;
        }
    }
    return earliest;
}

unittest {
    // Empty -> DateTime.init.
    assert(appIdResetDate([]) == DateTime.init);

    // Picks the earliest expiration.
    auto a = DateTime(2026, 7, 10, 0, 0, 0);
    auto b = DateTime(2026, 7, 1, 0, 0, 0);
    auto c = DateTime(2026, 7, 20, 0, 0, 0);
    assert(appIdResetDate([a, b, c]) == b);
    assert(appIdResetDate([b]) == b);
}

// ---------------------------------------------------------------------------
// JSON helpers: tolerant accessors (missing/wrong-typed fields -> defaults)
// ---------------------------------------------------------------------------

private string getStr(JSONValue v, string key, string fallback = "") {
    if (v.type != JSONType.object) return fallback;
    if (auto p = key in v.object) {
        if (p.type == JSONType.string) return p.str;
    }
    return fallback;
}

private int getInt(JSONValue v, string key, int fallback = 0) {
    if (v.type != JSONType.object) return fallback;
    if (auto p = key in v.object) {
        if (p.type == JSONType.integer) return cast(int) p.integer;
        if (p.type == JSONType.uinteger) return cast(int) p.uinteger;
    }
    return fallback;
}

private bool getBool(JSONValue v, string key, bool fallback = false) {
    if (v.type != JSONType.object) return fallback;
    if (auto p = key in v.object) {
        if (p.type == JSONType.true_) return true;
        if (p.type == JSONType.false_) return false;
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

private string[] getStrArray(JSONValue v, string key) {
    string[] result;
    foreach (e; getArray(v, key)) {
        if (e.type == JSONType.string)
            result ~= e.str;
    }
    return result;
}

// ---------------------------------------------------------------------------
// unittests: JSON round-trip
// ---------------------------------------------------------------------------

unittest {
    // SideloaderState round-trips through JSON.
    SideloaderState s;
    s.upsertAccount("alice@example.com");
    s.upsertCertificate(CachedCertificate("TEAM1", "CERTID", "abc123", "certs/TEAM1/cert.pem"));
    s.upsertProfile(CachedProfile("com.example.app", "TEAM1", "PPID", "name", "2026-07-01T00:00:00"));
    s.anisetteServer = "https://ani.example.com/";
    s.defaultTeamId = "TEAM1";
    s.defaultAccount = "alice@example.com";
    assert(s.addSource("https://repo.example.com/repo.json"));
    assert(!s.addSource("https://repo.example.com/repo.json")); // dedup
    assert(s.addSource("https://other.example.com/repo.json"));

    auto json = s.toJSON();
    auto reparsed = SideloaderState.fromJSON(parseJSON(json.toString()));

    assert(reparsed.anisetteServer == "https://ani.example.com/");
    assert(reparsed.defaultTeamId == "TEAM1");
    assert(reparsed.defaultAccount == "alice@example.com");
    assert(reparsed.sources.length == 2);
    assert(reparsed.sources[0] == "https://repo.example.com/repo.json");
    assert(reparsed.sources[1] == "https://other.example.com/repo.json");

    // removeSource is idempotent and reports how many were removed.
    assert(reparsed.removeSource("https://repo.example.com/repo.json") == 1);
    assert(reparsed.removeSource("https://repo.example.com/repo.json") == 0);
    assert(reparsed.sources.length == 1);

    // Back-compat: a state written before `sources` reads as an empty list.
    auto legacyState = SideloaderState.fromJSON(parseJSON(`{"version": 1}`));
    assert(legacyState.sources.length == 0);
    assert(reparsed.version_ == stateSchemaVersion);
    assert(reparsed.accounts.length == 1);
    assert(reparsed.accounts[0].appleId == "alice@example.com");
    assert(reparsed.certificates.length == 1);
    assert(reparsed.certificates[0].teamId == "TEAM1");
    assert(reparsed.certificates[0].publicKeyFingerprint == "abc123");
    assert(reparsed.profiles.length == 1);
    assert(reparsed.profiles[0].bundleId == "com.example.app");
    assert(reparsed.profiles[0].expiryDate == "2026-07-01T00:00:00");

    // Upsert dedup: same account / cert / profile keys do not duplicate.
    s.upsertAccount("alice@example.com");
    s.upsertCertificate(CachedCertificate("TEAM1", "CERTID2", "abc123", "certs/TEAM1/cert.pem"));
    assert(s.accounts.length == 1);
    assert(s.certificates.length == 1);
    assert(s.certificates[0].certificateId == "CERTID2"); // replaced
}

unittest {
    // InstalledRegistry round-trips and supports upsert/query/remove.
    InstalledRegistry reg;
    reg.upsert(InstalledApp(
        "com.example.app", "TEAM1", "fp",
        "2026-06-24T00:00:00", "2026-07-01T00:00:00",
        "/path/to/app.ipa", "Example",
    ));
    reg.upsert(InstalledApp(
        "com.example.other", "TEAM1", "fp",
        "2026-06-24T00:00:00", "2026-07-01T00:00:00",
        "", "Other",
    ));

    auto json = reg.toJSON();
    auto reparsed = InstalledRegistry.fromJSON(parseJSON(json.toString()));
    assert(reparsed.apps.length == 2);

    InstalledApp found;
    assert(reparsed.query("com.example.app", found));
    assert(found.appName == "Example");
    assert(found.expiryDate == "2026-07-01T00:00:00");
    assert(found.sourceIpaPath == "/path/to/app.ipa");
    assert(found.enabled); // default true survives the round-trip

    // A disabled app round-trips as disabled.
    auto disabled = InstalledApp(
        "com.example.disabled", "TEAM1", "fp",
        "2026-06-24T00:00:00", "2026-07-01T00:00:00",
        "", "Disabled",
    );
    disabled.enabled = false;
    reg.upsert(disabled);
    auto reparsed2 = InstalledRegistry.fromJSON(parseJSON(reg.toJSON().toString()));
    InstalledApp d;
    assert(reparsed2.query("com.example.disabled", d));
    assert(!d.enabled);

    // Back-compat: a record without an `enabled` field reads as enabled.
    auto legacy = InstalledApp.fromJSON(parseJSON(`{"bundleId": "com.legacy.app"}`));
    assert(legacy.bundleId == "com.legacy.app");
    assert(legacy.enabled);

    InstalledApp missing;
    assert(!reparsed.query("com.does.not.exist", missing));

    // Upsert replaces in place rather than duplicating.
    reparsed.upsert(InstalledApp("com.example.app", "TEAM1", "fp2", "x", "y", "z", "Renamed"));
    assert(reparsed.apps.length == 2);
    assert(reparsed.query("com.example.app", found));
    assert(found.appName == "Renamed");

    // Remove drops the record.
    assert(reparsed.remove("com.example.app") == 1);
    assert(reparsed.apps.length == 1);
    assert(!reparsed.query("com.example.app", found));
}

unittest {
    // Tolerant of unknown fields and missing fields.
    auto json = parseJSON(`{
        "version": 99,
        "unknownTopLevel": {"a": 1},
        "accounts": [{"appleId": "x@y.z", "extra": true}],
        "apps": "not an array for this struct"
    }`);
    auto s = SideloaderState.fromJSON(json);
    assert(s.version_ == 99);
    assert(s.accounts.length == 1);
    assert(s.accounts[0].appleId == "x@y.z");
    assert(s.accounts[0].lastUsed == ""); // missing -> default

    // Completely empty object yields defaults, no throw.
    auto empty = SideloaderState.fromJSON(parseJSON("{}"));
    assert(empty.version_ == stateSchemaVersion);
    assert(empty.accounts.length == 0);
}
