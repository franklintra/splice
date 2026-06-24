module cli_frontend;

import core.stdc.stdlib;

import std.array;
import std.datetime;
import std.exception;
import std.format;
import std.parallelism;
import std.path;
import std.process;
import std.stdio;
import std.sumtype;
import std.string;
import std.traits;
import std.typecons;
import file = std.file;

import slf4d;
import slf4d.default_provider;
import slf4d.provider;

import botan.cert.x509.x509cert;
import botan.pubkey.algo.rsa;

import plist;

import provision;

import imobiledevice;

import server.appleaccount;
import server.developersession;
import version_string;

import sideload;
import sideload.bundle;
import sideload.application;
import sideload.certificateidentity;
import sideload.sign;

import argparse;

import app;
import app.session;
import utils;

version = X509;

// Re-exported from the core so existing CLI code can keep importing them from
// `cli_frontend`. The single source of truth lives in `app.session`.
alias systemConfigurationPath = app.session.systemConfigurationPath;
alias defaultConfigurationPath = app.session.defaultConfigurationPath;

noreturn wrongArgument(string msg) {
    getLogger().error(msg);
    exit(1);
}

auto openApp(string path) {
    if (!file.exists(path))
        return wrongArgument("The specified app file does not exist.");

    if (!path.endsWith(".ipa"))
        return wrongArgument("The app is not an ipa file.");

    if (!file.isFile(path))
        return wrongArgument("The app should be an ipa file.");

    return new Application(path);
}

auto openAppFolder(string path) {
    if (!file.exists(path))
        return wrongArgument("The specified app file does not exist.");

    if (file.isFile(path))
        return wrongArgument("The app should be a folder.");

    return new Application(path);
}


auto readFile(string path) {
    return cast(ubyte[]) file.read(path);
}

auto readPrivateKey(string path) {
    RandomNumberGenerator rng = RandomNumberGenerator.makeRng();
    return RSAPrivateKey(loadKey(path, rng));
}

auto readCertificate(string path) {
    return X509Certificate(path, false);
}

extern(C) char* getpass(const(char)* prompt);

string readPasswordLine(string prompt) {
    version (Windows) {
        write(prompt.toStringz(), " [/!\\ The password will appear in clear text in the terminal]: ");
        return readln().chomp();
    } else {
        return fromStringz(cast(immutable) getpass(prompt.toStringz()));
    }
}

/// Attempts an Apple login with the given credentials, wiring the interactive
/// 2FA prompt. Returns the session on success, or `null` on failure.
private DeveloperSession attemptLogin(Device device, ADI adi, string appleId, string password) {
    auto log = getLogger();
    return DeveloperSession.login(
        device,
        adi,
        appleId,
        password,
        (sendCode, submitCode) {
            sendCode();
            string code;
            do {
                write("A code has been sent to your devices, please type it here (type `resend` to resend one): ");
                code = readln().chomp();
                if (code == "resend") {
                    sendCode();
                    continue;
                }
            } while (submitCode(code).match!((Success _) => false, (ReloginNeeded _) => false, (AppleLoginError _) => true));
        })
    .match!(
        (DeveloperSession session) => session,
        (AppleLoginError error) {
            log.errorF!"Can't log-in! %s (%d)"(error.description, error);
            return null;
        }
    );
}

DeveloperSession login(Device device, ADI adi, bool interactive) {
    import keyring;

    auto log = getLogger();

    log.info("Logging in...");

    auto kr = makeKeyring();

    // Try to re-use stored credentials so the user isn't re-prompted.
    string storedAppleId, storedPassword;
    if (deserializeCredentials(kr.lookup(), storedAppleId, storedPassword)) {
        log.infoF!"Found stored credentials for %s, logging in silently..."(storedAppleId);
        if (auto session = attemptLogin(device, adi, storedAppleId, storedPassword))
            return session;
        log.warn("Silent login with stored credentials failed; clearing them.");
        kr.clear();
    }

    if (!interactive) {
        log.error("You are not logged in. (use `sidestore login` to log-in, or add `-i` to make us ask you the account)");
        return null;
    }

    log.info("Please enter your account informations. They will only be sent to Apple servers.");
    log.info("See it for yourself at https://github.com/Dadoum/Sideloader/");

    write("Apple ID: ");
    string appleId = readln().chomp();
    string password = readPasswordLine("Password: ");

    auto session = attemptLogin(device, adi, appleId, password);
    if (session) {
        // Persist the credentials in the OS secure store so subsequent runs
        // don't have to prompt again.
        kr.store(serializeCredentials(appleId, password));
    }
    return session;
}

auto initializeADI(string configurationPath)
{
    scope log = getLogger();
    if (!(file.exists(configurationPath.buildPath("lib/libstoreservicescore.so")) && file.exists(configurationPath.buildPath("lib/libCoreADI.so")))) {
        auto succeeded = downloadAndInstallDeps(configurationPath, (progress) {
            write(format!"%.2f %% completed\r"(progress * 100));
            stdout.flush();

            return false;
        });

        if (!succeeded) {
            log.error("Download failed.");
            exit(1);
        }
        log.info("Download completed.");
    }

    scope provisioningData = app.initializeADI(configurationPath);
    return provisioningData;
}

// planned commands

import account;
import app_id;
import certificate;
import device;
import install;
import sign;
// @(Command("swift-setup").Description("Set-up certificates to build a Swift Package Manager iOS application (requires SPM in the path)."))
import team;
import tool;
// @(Command("tweak").Description("Install a tweak in an ipa file."))

mixin template LoginCommand()
{
    import provision;
    import app.session : SideloaderSession;
    @(NamedArgument("i", "interactive").Description("Prompt to type passwords if needed."))
    bool interactive = false;

    final auto login(Device device, ADI adi) => cli_frontend.login(device, adi, interactive);

    /**
     * Builds a `SideloaderSession` with the resolved configuration path and the
     * provisioned device/adi (downloading the ADI native libraries first if
     * needed, via the CLI `initializeADI`), then logs in using the interactive
     * CLI login strategy.
     *
     * Returns the session on success, or `null` when login failed (the caller
     * should `return 1`).
     */
    final SideloaderSession makeSession()
    {
        string configurationPath = systemConfigurationPath();
        scope provisioningData = initializeADI(configurationPath);
        auto session = new SideloaderSession(configurationPath, provisioningData);
        if (!session.ensureLoggedIn((device, adi) => login(device, adi)))
            return null;
        return session;
    }
}

@(Command("version").Description("Print the version."))
struct VersionCommand {
    int opCall() {
        writeln(versionStr);
        return 0;
    }
}

/**
 * On Apple Silicon, the iOS-tooling libraries (libimobiledevice, libusbmuxd, libplist)
 * are installed by Homebrew under /opt/homebrew/lib, which is NOT part of dyld's default
 * fallback search path (unlike /usr/local/lib on Intel). Since we dlopen() them by their
 * bare so-name, the process would fail to find them unless the user manually exported
 * DYLD_FALLBACK_LIBRARY_PATH. We transparently re-exec ourselves once with the Homebrew
 * prefixes injected so the CLI "just works". Returns the child exit code, or -1 when no
 * re-exec is needed (already shimmed, or not on macOS).
 */
int reExecWithHomebrewLibs()
{
    version (OSX) {
        if (environment.get("SIDELOADER_DYLD_SHIM") !is null)
            return -1;

        import core.runtime : Runtime;

        string[] searchPaths = ["/opt/homebrew/lib", "/usr/local/lib"];
        string existing = environment.get("DYLD_FALLBACK_LIBRARY_PATH", "");
        if (existing.length)
            searchPaths ~= existing;
        string home = environment.get("HOME", "");
        if (home.length)
            searchPaths ~= home ~ "/lib";
        searchPaths ~= "/usr/lib";

        string[string] childEnv = environment.toAA();
        childEnv["SIDELOADER_DYLD_SHIM"] = "1";
        childEnv["DYLD_FALLBACK_LIBRARY_PATH"] = searchPaths.join(":");

        string[] childArgs = file.thisExePath() ~ Runtime.args[1 .. $];
        return wait(spawnProcess(childArgs, childEnv));
    } else {
        return -1;
    }
}

int entryPoint(Commands commands)
{
    int shimExitCode = reExecWithHomebrewLibs();
    if (shimExitCode != -1)
        return shimExitCode;

    version (linux) {
        import core.stdc.locale;
        setlocale(LC_ALL, "");
    }

    defaultPoolThreads = commands.threadCount;
    configureLoggingProvider(new shared DefaultProvider(true, commands.debug_ ? Levels.TRACE : Levels.INFO));

    try
    {
        return commands.cmd.match!(
                (AppIdCommand cmd) => cmd(),
                (CertificateCommand cmd) => cmd(),
                (DeviceCommand cmd) => cmd(),
                (InstallCommand cmd) => cmd(),
                (LoginAccountCommand cmd) => cmd(),
                (LogoutCommand cmd) => cmd(),
                (SignCommand cmd) => cmd(),
                (TrollsignCommand cmd) => cmd(),
                (TeamCommand cmd) => cmd(),
                (ToolCommand cmd) => cmd(),
                (VersionCommand cmd) => cmd(),
        );
    }
    catch (Exception ex)
    {
        getLogger().errorF!"%s at %s:%d: %s"(typeid(ex).name, ex.file, ex.line, ex.msg);
        getLogger().debugF!"Full exception: %s"(ex);
        return 1;
    }
}

struct Commands
{
    @(NamedArgument("d", "debug").Description("Enable debug logging"))
    bool debug_;

    @(NamedArgument("thread-count").Description("Numbers of threads to be used for signing the application bundle"))
    uint threadCount = uint.max;

    @SubCommands
    SumType!(AppIdCommand, CertificateCommand, DeviceCommand, InstallCommand, LoginAccountCommand, LogoutCommand, SignCommand, TrollsignCommand, TeamCommand, ToolCommand, VersionCommand) cmd;
}

mixin CLI!Commands.main!entryPoint;

