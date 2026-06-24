module server.appleaccount;

import std.algorithm.iteration;
import std.array;
import std.base64;
import std.datetime;
import std.datetime.systime;
import std.format;
import std.sumtype;
import std.typecons;
import std.uni;
import std.zlib;

import botan.block.aes;
import botan.block.aes_ni;
import botan.block.aes_ssse3;
import botan.filters.pipe;
import botan.filters.transform_filter;
import botan.hash.sha2_32;
import botan.libstate.lookup;
import botan.mac.hmac;
import botan.modes.aead.aead;
import botan.modes.cipher_mode;
import botan.stream.ctr;
import botan.utils.cpuid;

import requests;

import slf4d;

import provision;

import plist;

import constants;
import server.anisette;
import server.applicationinformation;
import server.applesrpsession;
import utils;

enum AppleLoginErrorCode {
    mismatchedSRP = 1,
    misformattedEncryptedToken = 2,
    no2FAAttempt = 3,
    unsupportedNextStep = 4,
    anisetteProvisioningFailed = 5,
    urlSwitchingUnsupported = 6,
    tooManyRetries = 7,
    accountLocked = -20209,
    invalidValidationCode = -21669,
    invalidPassword = -22406,
    unableToSignIn = -36607
}

struct AppleLoginError {
    AppleLoginErrorCode code;
    string description;

    alias code this;
}

alias AppleLoginResponse = SumType!(AppleAccount, AppleLoginError);

struct Success {}
struct ReloginNeeded {}
alias AppleSecondaryActionResponse = SumType!(Success, ReloginNeeded, AppleLoginError);
alias Send2FADelegate = bool delegate();
alias Submit2FADelegate = AppleSecondaryActionResponse delegate(string code);
alias TFAHandlerDelegate = void delegate(Send2FADelegate send, Submit2FADelegate submit);
alias NextLoginStepHandler = AppleSecondaryActionResponse delegate(string identityToken, string[string] urlBag, string urlKey, bool canIgnore);

enum RINFO = "17106176";

package class AppleAccount {
    private Device device;
    private ADI adi;

    // Source of the anisette headers (X-Apple-I-MD*, X-Mme-*). Defaults to a
    // LocalAnisetteProvider built from `device`+`adi`, but may be a
    // RemoteAnisetteProvider pointing at an anisette-v1/v3 server.
    private AnisetteProvider anisetteProvider;

    private ApplicationInformation appInfo;

    private string appleIdentifier;
    private string adsid;
    private string token;

    string[string] urls;

    string appleId() {
        return appleIdentifier;
    }

    package this(Device device, ADI adi, AnisetteProvider anisetteProvider, ApplicationInformation appInfo, string[string] urlBag, string appleId, string adsid, string token) {
        this.device = device;
        this.adi = adi;
        this.anisetteProvider = anisetteProvider !is null ? anisetteProvider : new LocalAnisetteProvider(device, adi);
        this.appInfo = appInfo;
        this.urls = urlBag;
        this.appleIdentifier = appleId;
        this.adsid = adsid;
        this.token = token;
    }

    package static AppleLoginResponse login(ApplicationInformation applicationInformation, Device device, ADI adi, string appleId, string password, TFAHandlerDelegate tfaHandler, AnisetteProvider anisetteProvider = null) {
        auto log = getLogger();
        // Resolve the anisette source once so the 2FA sub-flow and the recursive
        // NextLoginStepHandler login share the same provider.
        auto resolvedAnisette = anisetteProvider !is null ? anisetteProvider : new LocalAnisetteProvider(device, adi);
        return login(applicationInformation, device, adi, appleId, password, (string identityToken, string[string] urls, string urlBagKey, bool canIgnore) {
            if (urlBagKey == "repair") {
                log.info("Apple tells us that your account is broken. We don't care (they actually just want you to add 2FA).");
                return AppleSecondaryActionResponse(Success());
            }

            if (urlBagKey != "trustedDeviceSecondaryAuth" && urlBagKey != "secondaryAuth") {
                string error = format!`Unsupported next authentication step: "%s"`(urlBagKey);
                if (!canIgnore) {
                    log.error(error);
                    return AppleSecondaryActionResponse(AppleLoginError(AppleLoginErrorCode.unsupportedNextStep, error));
                } else {
                    log.warn(error);
                    return AppleSecondaryActionResponse(Success());
                }
            }

            log.debug_("2FA with trusted device needed.");
            // 2FA is needed
            auto anisette = resolvedAnisette.headers();

            Request request = Request();
            // Validate Apple's TLS certificate against the system trust store (MITM-resistant).
            request.sslSetVerifyPeer(true);

            request.addHeaders(cast(string[string]) [
                "X-Apple-I-MD": anisette.oneTimePassword,
                "X-Apple-I-MD-M": anisette.machineId,
                "X-Apple-I-MD-RINFO": anisette.routingInfo,

                "X-Apple-I-Client-Time": anisette.clientTime,
                "X-Apple-Locale": anisette.locale,
                "X-Apple-I-TimeZone": anisette.timeZone,

                "X-Apple-Identity-Token": identityToken,

                "X-Mme-Client-Info": anisette.clientInfo,

                "User-Agent": applicationInformation.applicationName
            ]);
            request.addHeaders(applicationInformation.headers);

            // sends code to the trusted devices
            bool delegate() sendCode;
            if (urlBagKey == "trustedDeviceSecondaryAuth") {
                sendCode = () {
                    auto res = request.get(urls["trustedDeviceSecondaryAuth"]);
                    return res.code == 200;
                };
            } else {
                sendCode = () {
                    // urls["trustedDeviceSecondaryAuth"] to select the right phone number.
                    auto res = request.get(urls["secondaryAuth"]);
                    // auto res = request.put("https://gsa.apple.com/auth/verify/phone/", `{"phoneNumber": {"id": 1}, "mode": "sms"}`);
                    log.infoF!"Code sent: %s"(res.responseBody().data!string());
                    return res.code == 200;
                };
            }

            // submits the given code to Apple servers
            AppleSecondaryActionResponse response = AppleSecondaryActionResponse(AppleLoginError(AppleLoginErrorCode.no2FAAttempt, "2FA has not been completed."));
            AppleSecondaryActionResponse delegate(string) submitCode;
            if (urlBagKey == "trustedDeviceSecondaryAuth") {
                submitCode = (string code) {
                    request.addHeaders(["security-code": code]);
                    auto codeValidationPlist = Plist.fromXml(request.get(urls["validateCode"]).responseBody().data!string()).dict();
                    log.traceF!"Trusted device 2FA response: %s"(codeValidationPlist.toXml());
                    auto resultCode = codeValidationPlist["ec"].uinteger().native();

                    if (resultCode == 0) {
                        response = AppleSecondaryActionResponse(ReloginNeeded());
                    } else {
                        response = AppleSecondaryActionResponse(AppleLoginError(cast(AppleLoginErrorCode) resultCode, codeValidationPlist["em"].str().native()));
                    }

                    return response;
                };
            } else if (urlBagKey == "secondaryAuth") {
                submitCode = (string code) {
                    auto result = request.post("https://gsa.apple.com/auth/verify/phone/securitycode",
                        format!`{"securityCode": {"code": "%s"}, "phoneNumber": {"id": 1}, "mode": "sms"}`(code),
                        "application/json"
                    );
                    auto resultCode = result.code();
                    log.traceF!"SMS 2FA response: %s"(resultCode);

                    if (resultCode == 200) {
                        response = AppleSecondaryActionResponse(ReloginNeeded());
                    } else {
                        response = AppleSecondaryActionResponse(AppleLoginError(cast(AppleLoginErrorCode) resultCode, result.responseBody().data!string()));
                    }

                    return response;
                };
            }

            tfaHandler(sendCode, submitCode);
            return response;
        }, resolvedAnisette);
    }

    package static AppleLoginResponse login(ApplicationInformation applicationInformation, Device device, ADI adi, string appleId, string password, NextLoginStepHandler nextStepHandler, AnisetteProvider anisetteProvider = null) {
        return login(applicationInformation, device, adi, appleId, password, nextStepHandler, 0, anisetteProvider);
    }

    // Maximum number of times we will reprovision/resync/switch-URL and retry the
    // login before giving up, to avoid an infinite loop if the server keeps asking.
    private enum maxLoginRetries = 2;

    private static AppleLoginResponse login(ApplicationInformation applicationInformation, Device device, ADI adi, string appleId, string password, NextLoginStepHandler nextStepHandler, uint attempt, AnisetteProvider anisetteProvider = null) {
        auto log = getLogger();

        log.info("Logging in...");

        appleId = appleId.toLower();

        // Resolve the anisette source. When none is supplied this is the historical
        // LocalAnisetteProvider(device, adi) path, so behaviour is byte-identical.
        auto anisette = anisetteProvider !is null ? anisetteProvider : new LocalAnisetteProvider(device, adi);

        Request request = Request();
        // Validate Apple's TLS certificate against the system trust store (MITM-resistant).
        request.sslSetVerifyPeer(true);

        request.addHeaders([
            "Content-Type": "text/x-xml-plist",
            "Accept": "text/x-xml-plist",

            // "X-Mme-Device-Id": device.uniqueDeviceIdentifier,
            // on macOS, MMe for the Client-Info header is written with 2 caps, while on Windows it is Mme...
            // and HTTP headers are supposed to be case-insensitive in the HTTP spec...
            "X-Mme-Client-Info": anisette.headers().clientInfo,
            // "X-Apple-I-MD-LU": device.localUserUUID

            "User-Agent": applicationInformation.applicationName
        ]);

        request.addHeaders(applicationInformation.headers);

        // Fetch URLs from Apple servers
        log.debug_("Fetching URL bag...");
        auto urlsPlist = Plist.fromXml(request.get("https://gsa.apple.com/grandslam/GsService2/lookup").responseBody().data!string())["urls"]
            .dict().native();
        log.debug_("URL bag OK.");

        string[string] urls;
        foreach (key, url; urlsPlist) {
            urls[key] = url.str().native();
        }

        // Apple auth protocol is a slightly modified GSA, see AppleSRPSession code for details
        auto srpSession = new AppleSRPSession();
        auto A = srpSession.step1();

        Plist request1 = dict(
            "Header", dict(
                "Version", "1.0.1".pl
            ),
            "Request", dict(
                "A2k", A.pl, // [SRP] A, 2048
                "cpd", clientProvidedData(applicationInformation, anisette),
                "o", "init".pl,
                "ps", [ // protocols supported
                    "s2k".pl,
                    "s2k_fo".pl
                ].pl,
                "u", appleId.pl // username
            )
        );

        string request1Str = request1.toXml();
        log.trace(request1Str);

        log.debug_("Sending first auth request...");
        auto response1Str = request.post(urls["gsService"], request1Str).responseBody().data!string();
        log.trace(response1Str);
        auto response1 = Plist.fromXml(response1Str)["Response"];
        log.debug_("First auth request OK.");

        auto error1 = response1["Status"].dict().validateStatus();
        if (!error1.isNull()) {
            return AppleLoginResponse(error1.get());
        }

        auto iterations = cast(size_t) response1["i"].uinteger().native();
        auto salt = response1["s"].data().native();
        auto selectedProtocol = response1["sp"].str().native();
        auto cookie = response1["c"].str().native();
        auto B = response1["B"].data().native();

        auto M1 = srpSession.step2(appleId, password, selectedProtocol == "s2k_fo", B, salt, iterations);

        Plist request2 = dict(
            "Header", dict(
                "Version", "1.0.1".pl
            ),
            "Request", dict(
                "M1", M1.pl,
                "c", cookie.pl,
                "cpd", clientProvidedData(applicationInformation, anisette),
                "o", "complete".pl,
                "u", appleId.pl
            )
        );

        string request2Str = request2.toXml();
        log.trace(request2Str);

        log.debug_("Sending the second request...");
        auto response2Str = request.post(urls["gsService"], request2Str).responseBody().data!string();
        log.trace(response2Str);
        log.debug_("Second request OK.");

        auto response2 = Plist.fromXml(response2Str)["Response"].dict();
        auto status2 = response2["Status"].dict();
        auto error2 = status2.validateStatus();
        if (!error2.isNull()) {
            return AppleLoginResponse(error2.get());
        }

        auto spd = response2["spd"].data().native();
        // auto np = response2["np"].str().native(); // we assume that the negociation was well performed, too lazy to check for real
        auto M2 = response2["M2"].data().native();

        if (!srpSession.step3(M2)) {
            return AppleLoginResponse(AppleLoginError(AppleLoginErrorCode.mismatchedSRP, "Cannot log-in to the Apple server. Negociation failed."));
        }

        auto K = srpSession.K;

        auto hmac = new HMAC(new SHA256());
        hmac.setKey(K.ptr, K.length);
        hmac.update("extra data key:");
        auto extraDataKey = SymmetricKey(hmac.finished());

        hmac.update("extra data iv:");
        auto extraDataIvVec = hmac.finished();
        extraDataIvVec.length = 16;
        auto extraDataIv = InitializationVector(extraDataIvVec);

        auto aes = cast(TransformationFilter) getCipher("AES-256/CBC/NoPadding", DECRYPTION);
        aes.setKey(extraDataKey);
        aes.setIv(extraDataIv);

        auto aesDecryptor = Pipe(aes);
        aesDecryptor.processMsg(spd.ptr, spd.length);
        auto spdLength = aesDecryptor.read(spd);
        auto decryptedSpd = cast(string) spd[0..spdLength];
        log.traceF!"spd: %s"(decryptedSpd);

        auto serverProvidedData = Plist.fromXml(decryptedSpd).dict();

        string idmsToken = serverProvidedData["GsIdmsToken"].str().native();
        string adsid = serverProvidedData["adsid"].str().native();

        auto hsc = status2["hsc"].uinteger().native();
        auto sk = "sk" in serverProvidedData;
        auto c = "c" in serverProvidedData;

        bool canIgnore = sk && c;

        AppleLoginResponse completeAuthentication() {
            auto log = getLogger();

            log.debug_("Completing authentication...");
            ubyte[] sessionKey = serverProvidedData["sk"].data().native();
            ubyte[] c = serverProvidedData["c"].data().native();

            auto appTokens = new HMAC(new SHA256());
            appTokens.setKey(sessionKey.ptr, sessionKey.length);
            appTokens.update("apptokens");
            appTokens.update(adsid);
            appTokens.update(applicationInformation.applicationId);
            auto checksum = appTokens.finished()[].dup;

            Plist request3 = dict(
                "Header", dict(
                    "Version", "1.0.1".pl
                ),
                "Request", dict(
                    "u", adsid.pl,
                    "app", [
                        applicationInformation.applicationId.pl
                    ].pl,
                    "c", c.pl,
                    "t", idmsToken.pl,
                    "checksum", checksum.pl,
                    "cpd", clientProvidedData(applicationInformation, anisette),
                    "o", "apptokens".pl,
                )
            );

            string request3Str = request3.toXml();
            log.trace(request3Str);

            auto response3Str = request.post(urls["gsService"], request3Str).responseBody().data!string();
            log.trace(response3Str);

            auto response3 = Plist.fromXml(response3Str)["Response"].dict();
            auto error3 = response3["Status"].dict().validateStatus();
            if (!error3.isNull()) {
                return AppleLoginResponse(error3.get());
            }

            ubyte[] encryptedToken = response3["et"].data().native();
            char[3] header = cast(char[]) encryptedToken[0..3];

            if (header != "XYZ") {
                return AppleLoginResponse(AppleLoginError(AppleLoginErrorCode.misformattedEncryptedToken, "Encrypted token is in an unknown format."));
            }

            auto gcm = getAead(
                "AES-256/GCM", DECRYPTION
            );
            gcm.setKey(sessionKey.ptr, sessionKey.length);
            gcm.setAssociatedData(encryptedToken.ptr, 3);
            gcm.start(encryptedToken[3..3 + 16].ptr, 16); // iv
            SecureVector!ubyte decryptedEt = encryptedToken[16 + 3..$];
            gcm.finish(decryptedEt);
            auto decryptedToken = Plist.fromXml(cast(string) decryptedEt[]).dict();

            auto token = decryptedToken["t"][applicationInformation.applicationId]["token"].str().native();

            return AppleLoginResponse(new AppleAccount(device, adi, anisette, applicationInformation, urls, appleId, adsid, token));
        }

        switch (hsc) {
            case 409: /+ secondaryActionRequired +/
                auto secondaryActionKey = status2["au"].str().native();
                string identityToken = Base64.encode(cast(ubyte[]) (adsid ~ ":" ~ idmsToken));
                return nextStepHandler(identityToken, urls, secondaryActionKey, canIgnore).match!(
                    (AppleLoginError error) => AppleLoginResponse(error),
                    (ReloginNeeded _) => login(applicationInformation, device, adi, appleId, password, nextStepHandler, attempt, anisette),
                    (Success _) => completeAuthentication(),
                );
            case 433: /+ anisetteReprovisionRequired +/
                if (attempt >= maxLoginRetries) {
                    return AppleLoginResponse(AppleLoginError(
                        AppleLoginErrorCode.tooManyRetries,
                        format!"Apple keeps requesting Anisette reprovisioning after %d attempts; giving up."(attempt)
                    ));
                }
                // When anisette comes from a remote server, the local Android ADI
                // is not the source of these headers, so reprovisioning it would be
                // pointless (and the libraries may not even be present). A fresh GET
                // already yields new values, so just retry.
                if (cast(LocalAnisetteProvider) anisette is null) {
                    log.warnF!"Server requested Anisette reprovision (attempt %d) but a remote anisette server is in use; retrying with fresh headers..."(attempt + 1);
                    return login(applicationInformation, device, adi, appleId, password, nextStepHandler, attempt + 1, anisette);
                }
                log.warnF!"Server requested Anisette reprovision (attempt %d). Wiping and re-provisioning..."(attempt + 1);
                try {
                    adi.eraseProvisioning(-2);
                    auto provisioningSession = new ProvisioningSession(adi, device);
                    provisioningSession.provision(-2);
                } catch (Exception e) {
                    return AppleLoginResponse(AppleLoginError(
                        AppleLoginErrorCode.anisetteProvisioningFailed,
                        format!"Anisette reprovisioning failed: %s"(e.msg)
                    ));
                }
                log.info("Reprovisioned successfully, retrying login...");
                return login(applicationInformation, device, adi, appleId, password, nextStepHandler, attempt + 1, anisette);
            case 434: /+ anisetteResyncRequired +/
                if (attempt >= maxLoginRetries) {
                    return AppleLoginResponse(AppleLoginError(
                        AppleLoginErrorCode.tooManyRetries,
                        format!"Apple keeps requesting Anisette resync after %d attempts; giving up."(attempt)
                    ));
                }
                // As above: with a remote anisette server the local ADI cannot be
                // synchronised; a fresh GET provides up-to-date values, so retry.
                if (cast(LocalAnisetteProvider) anisette is null) {
                    log.warnF!"Server requested Anisette resync (attempt %d) but a remote anisette server is in use; retrying with fresh headers..."(attempt + 1);
                    return login(applicationInformation, device, adi, appleId, password, nextStepHandler, attempt + 1, anisette);
                }
                log.warnF!"Server requested Anisette resync (attempt %d). Synchronizing..."(attempt + 1);
                try {
                    auto resyncData = status2["X-Apple-I-MD-DATA"].str().native();
                    ubyte[] serverIntermediateMetadata = Base64.decode(resyncData);
                    adi.synchronize(-2, serverIntermediateMetadata);
                } catch (Exception e) {
                    return AppleLoginResponse(AppleLoginError(
                        AppleLoginErrorCode.anisetteProvisioningFailed,
                        format!"Anisette resync failed: %s"(e.msg)
                    ));
                }
                log.info("Resynchronized successfully, retrying login...");
                return login(applicationInformation, device, adi, appleId, password, nextStepHandler, attempt + 1, anisette);
            case 435: /+ urlSwitchingRequired +/
                // Apple wants us to retry against a different GSA endpoint. The
                // exact location of the replacement URL in the response could not
                // be confirmed without a live Apple flow, so rather than silently
                // proceeding against the old endpoint (which would loop or fail),
                // surface a clear, actionable error.
                log.errorF!"Server requested URL switching (hsc 435). Response: %s"(response2Str);
                return AppleLoginResponse(AppleLoginError(
                    AppleLoginErrorCode.urlSwitchingUnsupported,
                    "Apple requested a GSA endpoint switch (status 435) which is not yet supported. " ~
                    "Please report this along with the debug logs."
                ));
            default: break;
        }

        return completeAuthentication();
    }

    private static Plist clientProvidedData(ApplicationInformation applicationInformation, AnisetteProvider anisetteProvider) {
        auto anisette = anisetteProvider.headers();

        return dict(
            // Time
            "X-Apple-I-Client-Time", anisette.clientTime.pl,
            // Anisette headers
            "X-Apple-I-MD", anisette.oneTimePassword.pl,
            "X-Apple-I-MD-LU", anisette.localUserUUID.pl,
            "X-Apple-I-MD-M", anisette.machineId.pl,
            "X-Apple-I-MD-RINFO", anisette.routingInfo.pl,

            "X-Apple-I-SRL-NO", "0".pl,
            "X-Apple-I-TimeZone", anisette.timeZone.pl,
            "X-Apple-Locale", anisette.locale.pl,

            // Device UUID
            "X-Mme-Device-Id", anisette.deviceId.pl,
            // Miscellaneous headers took from a real request
            "bootstrap", true.pl,
            // "capp": applicationInformation.applicationName.pl,
            // "ckgen": true.pl,
            "icscrec", true.pl,
            "loc", locale().pl,
            "pbe", false.pl,
            "prkgen", true.pl,
            "svct", "iCloud".pl,
        );
    }

    package Plist sendRequest(string url, Plist request) {
        auto rq = Request();

        auto anisette = anisetteProvider.headers();

        // Validate Apple's TLS certificate against the system trust store (MITM-resistant).
        rq.sslSetVerifyPeer(true);
        rq.addHeaders(cast(string[string]) [
            "Content-Type": "text/x-xml-plist",
            "Accept": "text/x-xml-plist",
            "Accept-Language": "en-us",
            "User-Agent": appInfo.applicationName,

            "X-Apple-I-Identity-Id": adsid,
            "X-Apple-GS-Token": token,

            "X-Apple-I-MD-M": anisette.machineId,
            "X-Apple-I-MD": anisette.oneTimePassword,
            "X-Apple-I-MD-LU": anisette.localUserUUID,
            "X-Apple-I-MD-RINFO": anisette.routingInfo,

            "X-Mme-Device-Id": anisette.deviceId,
            "X-Mme-Client-Info": anisette.clientInfo,

            "X-Apple-I-Client-Time": anisette.clientTime,
            "X-Apple-Locale": anisette.locale,
            "X-Apple-I-TimeZone": anisette.timeZone,
        ]);

        // Application information
        rq.addHeaders(appInfo.headers);
        Response httpResponse;
        if (request !is null) {
            httpResponse = rq.post(url, request.toXml(), "text/x-xml-plist");
        } else {
            httpResponse = rq.get(url);
        }

        auto response = Plist.fromXml(httpResponse.responseBody.data!string());
        getLogger().trace(response.toXml());

        return response;
    }
}

private:
Nullable!AppleLoginError validateStatus(PlistDict status) {
    long errorCode = cast(long) status["ec"].uinteger().native();
    if (!errorCode) {
        return Nullable!AppleLoginError.init;
    }

    return Nullable!AppleLoginError(AppleLoginError(cast(AppleLoginErrorCode) errorCode, status["em"].str().native()));
}
