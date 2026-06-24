module server.anisette;

/**
 * Anisette provider abstraction.
 *
 * "Anisette" is the set of device/identity headers Apple's GrandSlam servers
 * expect on every authenticated request. Historically Sideloader produced them
 * *locally* from a provisioned Android ADI (`adi.requestOTP(-2)`) plus a few
 * `Device` fields. That still works (`LocalAnisetteProvider`), but it requires
 * the Android `libCoreADI.so` / `libstoreservicescore.so` to be downloaded and
 * an ADI machine to be provisioned.
 *
 * A *remote* anisette server (e.g. https://github.com/Dadoum/anisette-v3-server)
 * exposes a `GET <url>/` endpoint returning the same header set as JSON. Pointing
 * at one (`RemoteAnisetteProvider`) lets Sideloader skip local Android-library
 * provisioning entirely. The `GET /` headers endpoint is served by both
 * anisette-v1 and anisette-v3 servers, so this is "anisette-v3 compatible"
 * without needing the v3 WebSocket provisioning session.
 *
 * The provider yields the header *values*; the two GSA call sites
 * (`AppleAccount.clientProvidedData` and `AppleAccount.sendRequest`) consume
 * them instead of touching `Device`/`ADI` directly.
 */

import std.base64;
import std.datetime;
import std.datetime.systime;
import std.format : format;
import std.json;
import std.string : toLower;

import requests;

import slf4d;

import provision;

import utils;

/// The default value for `X-Apple-I-MD-RINFO`, shared by local and remote paths.
enum anisetteRINFO = "17106176";

/**
 * A single coherent set of anisette header values for one GSA request.
 *
 * Time-sensitive fields (`X-Apple-I-Client-Time`, the OTP in `X-Apple-I-MD`,
 * ...) are captured at the moment the set is produced, so a fresh set should be
 * requested per outgoing request.
 */
struct AnisetteHeaders {
    string machineId;        /// X-Apple-I-MD-M
    string oneTimePassword;  /// X-Apple-I-MD
    string routingInfo;      /// X-Apple-I-MD-RINFO
    string localUserUUID;    /// X-Apple-I-MD-LU
    string deviceId;         /// X-Mme-Device-Id
    string clientInfo;       /// X-Mme-Client-Info (a.k.a. serverFriendlyDescription)
    string clientTime;       /// X-Apple-I-Client-Time (ISO-8601, no millis)
    string timeZone;         /// X-Apple-I-TimeZone
    string locale;           /// X-Apple-Locale
}

/**
 * Produces anisette header sets for an in-flight Apple login / request.
 *
 * Implementations: `LocalAnisetteProvider` (Android ADI, byte-for-byte identical
 * to the historical behaviour) and `RemoteAnisetteProvider` (an anisette-v1/v3
 * server).
 */
interface AnisetteProvider {
    /// Returns a fresh, coherent set of anisette headers.
    AnisetteHeaders headers();
}

/// Raised when a remote anisette server is unreachable or returns garbage.
class AnisetteException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

/**
 * The historical, local emulation path: anisette values come from a provisioned
 * Android ADI plus a few `Device` fields. Output is byte-for-byte identical to
 * what `AppleAccount` produced inline before the abstraction was introduced.
 */
final class LocalAnisetteProvider : AnisetteProvider {
    private Device device;
    private ADI adi;

    this(Device device, ADI adi) {
        this.device = device;
        this.adi = adi;
    }

    override AnisetteHeaders headers() {
        auto otp = adi.requestOTP(-2);
        auto time = Clock.currTime(UTC());

        AnisetteHeaders h;
        h.machineId = Base64.encode(otp.machineIdentifier);
        h.oneTimePassword = Base64.encode(otp.oneTimePassword);
        h.routingInfo = anisetteRINFO;
        h.localUserUUID = device.localUserUUID();
        h.deviceId = device.uniqueDeviceIdentifier();
        h.clientInfo = device.serverFriendlyDescription();
        h.clientTime = time.stripMilliseconds().toISOExtString();
        h.timeZone = time.timezone.dstName;
        h.locale = locale();
        return h;
    }
}

/**
 * Fetches anisette values from a remote anisette server.
 *
 * Performs `GET <baseUrl>/` and parses the JSON header map (case-insensitively,
 * since servers disagree on `X-MMe-Client-Info` vs `X-Mme-Client-Info`). A fresh
 * GET is performed per `headers()` call because anisette values are
 * time-sensitive.
 */
final class RemoteAnisetteProvider : AnisetteProvider {
    private string baseUrl;

    this(string baseUrl) {
        // Normalise so that we always hit `<url>/` exactly once.
        import std.string : endsWith;
        this.baseUrl = baseUrl.endsWith("/") ? baseUrl : baseUrl ~ "/";
    }

    override AnisetteHeaders headers() {
        auto log = getLogger();
        log.debugF!"Fetching anisette headers from %s"(baseUrl);

        Request request = Request();
        // Validate the anisette server's TLS certificate (MITM-resistant).
        request.sslSetVerifyPeer(true);

        string body_;
        try {
            auto response = request.get(baseUrl);
            if (response.code != 200) {
                throw new AnisetteException(
                    format!"Anisette server %s returned HTTP %d."(baseUrl, response.code)
                );
            }
            body_ = response.responseBody().data!string();
        } catch (AnisetteException) {
            throw new AnisetteException(
                format!"Anisette server %s returned an error status."(baseUrl)
            );
        } catch (Exception e) {
            throw new AnisetteException(
                format!"Could not reach anisette server %s: %s"(baseUrl, e.msg)
            );
        }

        return parseAnisetteJSON(body_, baseUrl);
    }
}

/**
 * Parses an anisette-server JSON body into an `AnisetteHeaders`.
 *
 * Keys are matched case-insensitively. Required identity fields must be present;
 * missing time/zone/locale fields are filled in locally (they are not secret and
 * a server may legitimately omit them).
 *
 * Factored out of `RemoteAnisetteProvider` so it can be unit-tested without a
 * live server.
 */
AnisetteHeaders parseAnisetteJSON(string jsonBody, string sourceLabel = "<anisette>") {
    JSONValue json;
    try {
        json = parseJSON(jsonBody);
    } catch (Exception e) {
        throw new AnisetteException(
            format!"Anisette server %s returned invalid JSON: %s"(sourceLabel, e.msg)
        );
    }

    if (json.type != JSONType.object) {
        throw new AnisetteException(
            format!"Anisette server %s did not return a JSON object."(sourceLabel)
        );
    }

    // Build a lowercase-keyed lookup so casing variants all resolve.
    string[string] lower;
    foreach (key, value; json.object) {
        if (value.type == JSONType.string) {
            lower[key.toLower()] = value.str;
        }
    }

    string get(string headerName) {
        if (auto p = headerName.toLower() in lower)
            return *p;
        return null;
    }

    string require(string headerName) {
        auto v = get(headerName);
        if (v is null) {
            throw new AnisetteException(
                format!"Anisette server %s response is missing required header %s."(sourceLabel, headerName)
            );
        }
        return v;
    }

    auto time = Clock.currTime(UTC());

    AnisetteHeaders h;
    h.machineId = require("X-Apple-I-MD-M");
    h.oneTimePassword = require("X-Apple-I-MD");
    h.localUserUUID = require("X-Apple-I-MD-LU");
    h.deviceId = require("X-Mme-Device-Id");
    h.clientInfo = require("X-Mme-Client-Info");
    // These are non-secret; fall back to local values if the server omits them.
    h.routingInfo = orLocal(get("X-Apple-I-MD-RINFO"), anisetteRINFO);
    h.clientTime = orLocal(get("X-Apple-I-Client-Time"), time.stripMilliseconds().toISOExtString());
    h.timeZone = orLocal(get("X-Apple-I-TimeZone"), time.timezone.dstName);
    h.locale = orLocal(get("X-Apple-Locale"), locale());
    return h;
}

private string orLocal(string serverValue, lazy string fallback) {
    return (serverValue is null || serverValue.length == 0) ? fallback : serverValue;
}

// ---------------------------------------------------------------------------
// unittests
// ---------------------------------------------------------------------------

unittest {
    // A typical anisette-v3 GET / response, deliberately using the `X-MMe-Client-Info`
    // casing variant to exercise case-insensitive matching.
    auto sample = `{
        "X-Apple-I-MD": "AAAA-otp-base64",
        "X-Apple-I-MD-M": "BBBB-machine-base64",
        "X-Apple-I-MD-RINFO": "17106176",
        "X-Apple-I-MD-LU": "0123456789ABCDEF",
        "X-Apple-I-SRL-NO": "0",
        "X-Apple-I-Client-Time": "2026-06-24T12:00:00Z",
        "X-Apple-I-TimeZone": "UTC",
        "X-Apple-Locale": "en_US",
        "X-Mme-Device-Id": "DEADBEEF-0000-1111-2222-333344445555",
        "X-MMe-Client-Info": "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1>"
    }`;

    auto h = parseAnisetteJSON(sample, "test");
    assert(h.oneTimePassword == "AAAA-otp-base64");
    assert(h.machineId == "BBBB-machine-base64");
    assert(h.routingInfo == "17106176");
    assert(h.localUserUUID == "0123456789ABCDEF");
    assert(h.deviceId == "DEADBEEF-0000-1111-2222-333344445555");
    // Matched despite the `X-MMe-Client-Info` casing.
    assert(h.clientInfo == "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1>");
    assert(h.clientTime == "2026-06-24T12:00:00Z");
    assert(h.timeZone == "UTC");
    assert(h.locale == "en_US");
}

unittest {
    // Missing time/zone/locale fields are filled in locally, not rejected.
    auto sample = `{
        "X-Apple-I-MD": "otp",
        "X-Apple-I-MD-M": "machine",
        "X-Apple-I-MD-LU": "lu",
        "X-Mme-Device-Id": "dev",
        "X-Mme-Client-Info": "info"
    }`;
    auto h = parseAnisetteJSON(sample, "test");
    assert(h.oneTimePassword == "otp");
    assert(h.routingInfo == anisetteRINFO); // defaulted
    assert(h.clientTime.length > 0);        // filled locally
    assert(h.locale.length > 0);            // filled locally
}

unittest {
    // A response missing a required identity header is rejected.
    auto sample = `{ "X-Apple-I-MD": "otp" }`;
    bool threw = false;
    try {
        parseAnisetteJSON(sample, "test");
    } catch (AnisetteException) {
        threw = true;
    }
    assert(threw);
}

unittest {
    // Non-JSON / non-object bodies are rejected with a clear exception.
    bool threwOnGarbage = false;
    try { parseAnisetteJSON("not json at all", "test"); }
    catch (AnisetteException) { threwOnGarbage = true; }
    assert(threwOnGarbage);

    bool threwOnArray = false;
    try { parseAnisetteJSON("[1, 2, 3]", "test"); }
    catch (AnisetteException) { threwOnArray = true; }
    assert(threwOnArray);
}
