module cli_frontend;

import core.stdc.stdlib;

import std.array;
import std.conv;
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

import server.anisette;
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

/**
 * Remote anisette server URL selected for this invocation, resolved in
 * `entryPoint` from the `--anisette-server` flag (falling back to the persisted
 * default). Empty means "use local emulation". It is consumed by `makeSession`,
 * which has no direct access to the top-level `Commands` struct.
 */
package string g_anisetteServer = "";

/**
 * Apple ID selected for this invocation via the global `--account` flag (set in
 * `entryPoint`). Empty means "use the persisted default account (or the only one
 * stored)". Consumed by `login`, which has no access to the top-level `Commands`.
 */
package string g_selectedAccount = "";

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
private DeveloperSession attemptLogin(Device device, ADI adi, string appleId, string password, AnisetteProvider anisetteProvider = null) {
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
        },
        anisetteProvider)
    .match!(
        (DeveloperSession session) => session,
        (AppleLoginError error) {
            log.errorF!"Can't log-in! %s (%d)"(error.description, error);
            return null;
        }
    );
}

DeveloperSession login(Device device, ADI adi, bool interactive, AnisetteProvider anisetteProvider = null) {
    import keyring;
    import app.persistence : loadState, saveState;

    auto log = getLogger();

    log.info("Logging in...");

    auto kr = makeKeyring();
    string configurationPath = systemConfigurationPath();

    // Try to re-use a stored account so the user isn't re-prompted. Multiple
    // accounts may be stored; pick the one requested via `--account`, otherwise
    // the persisted default, otherwise the only one stored.
    StoredAccount[] accounts;
    string storedDefault;
    if (deserializeAccounts(kr.lookup(), accounts, storedDefault) && accounts.length) {
        // `--account` (g_selectedAccount) wins; else the state.json default; else
        // the blob's own default.
        string wanted = g_selectedAccount.length ? g_selectedAccount : loadState(configurationPath).defaultAccount;
        if (wanted.length == 0)
            wanted = storedDefault;

        auto chosen = pickAccount(accounts, wanted);
        if (g_selectedAccount.length && chosen.appleId != g_selectedAccount) {
            log.warnF!"No stored account matches --account %s; using %s instead."(g_selectedAccount, chosen.appleId);
        }

        log.infoF!"Found stored credentials for %s, logging in silently..."(chosen.appleId);
        if (auto session = attemptLogin(device, adi, chosen.appleId, chosen.password, anisetteProvider))
            return session;
        log.warnF!"Silent login with stored credentials for %s failed; removing them."(chosen.appleId);

        // Drop just the failing account, keeping any others.
        accounts = removeAccount(accounts, chosen.appleId);
        if (accounts.length) {
            if (storedDefault == chosen.appleId)
                storedDefault = accounts[0].appleId;
            kr.store(serializeAccounts(accounts, storedDefault));
        } else {
            kr.clear();
        }
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

    auto session = attemptLogin(device, adi, appleId, password, anisetteProvider);
    if (session) {
        // Persist (add/update) this account in the OS secure store and make it the
        // default, so subsequent runs don't have to prompt again.
        StoredAccount[] current;
        string currentDefault;
        deserializeAccounts(kr.lookup(), current, currentDefault);
        current = upsertAccount(current, StoredAccount(appleId, password));
        kr.store(serializeAccounts(current, appleId));

        auto state = loadState(configurationPath);
        state.defaultAccount = appleId;
        saveState(configurationPath, state);
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

/**
 * Resolves the remote anisette server URL for this invocation.
 *
 * Precedence: the `--anisette-server` flag (`g_anisetteServer`, set in
 * `entryPoint`) wins and is persisted as the new default; otherwise the persisted
 * default from `state.json` is used; if neither is set, returns empty (meaning
 * "use local emulation").
 */
string resolveAnisetteServer(string configurationPath)
{
    import app.persistence : loadState, saveState;

    auto state = loadState(configurationPath);
    if (g_anisetteServer.length) {
        // Explicit flag: use it and persist it as the new default.
        if (state.anisetteServer != g_anisetteServer) {
            state.anisetteServer = g_anisetteServer;
            saveState(configurationPath, state);
        }
        return g_anisetteServer;
    }
    return state.anisetteServer;
}

/**
 * Resolves which developer team a CLI command should act on.
 *
 * Precedence (no prompt unless genuinely ambiguous):
 *   1. an explicit `--team <teamId>` always wins;
 *   2. otherwise a persisted `defaultTeamId` from `state.json` that still
 *      matches an available team is used silently;
 *   3. otherwise, if the account has exactly one team, it is used silently;
 *   4. otherwise (several teams, no default) a numbered list is printed and the
 *      user is prompted on stdin; the choice is persisted as the new default.
 *
 * `session` must already be logged in (call `makeSession` first).
 */
DeveloperTeam selectTeamInteractive(SideloaderSession session, string teamId)
{
    import app.persistence : loadState, saveState;

    auto log = getLogger();
    auto state = loadState(session.configurationPath);

    bool ambiguous;
    DeveloperTeam[] teams;
    auto team = session.resolveTeam(teamId, state.defaultTeamId, ambiguous, teams);

    if (!ambiguous)
        return team;

    // Several teams and no usable default: present a numbered picker.
    writeln("You belong to several development teams. Please choose one:");
    foreach (i, t; teams) {
        writefln!"  [%d] %s (ID: %s)"(i + 1, t.name, t.teamId);
    }

    size_t choice;
    while (true) {
        write(format!"Enter a number between 1 and %d: "(teams.length));
        stdout.flush();
        string line = readln();
        if (line is null) {
            // EOF (non-interactive stdin): fall back to the first team without
            // persisting, so scripted use does not hang.
            log.warn("No selection provided; defaulting to the first team.");
            return teams[0];
        }
        line = line.chomp();
        try {
            choice = line.to!size_t();
        } catch (Exception) {
            choice = 0;
        }
        if (choice >= 1 && choice <= teams.length)
            break;
        writeln("Invalid selection, please try again.");
    }

    team = teams[choice - 1];

    // Persist the choice as the new default for subsequent runs.
    state.defaultTeamId = team.teamId;
    saveState(session.configurationPath, state);
    log.infoF!"Saved `%s` as your default team."(team.name);

    return team;
}

// planned commands

import account;
import app_id;
import apps;
import certificate;
import daemon;
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
    import server.anisette : AnisetteProvider, RemoteAnisetteProvider;
    static import app;
    import app.session : SideloaderSession;
    @(NamedArgument("i", "interactive").Description("Prompt to type passwords if needed."))
    bool interactive = false;

    final auto login(Device device, ADI adi, AnisetteProvider anisetteProvider) =>
        cli_frontend.login(device, adi, interactive, anisetteProvider);

    /**
     * Builds a `SideloaderSession` with the resolved configuration path, then logs
     * in using the interactive CLI login strategy.
     *
     * Anisette headers come from a remote anisette server when one is configured
     * (`--anisette-server` or the persisted default); in that case we skip the
     * Android ADI native-library download and machine provisioning entirely, only
     * creating the local `Device` identity. Otherwise we fall back to local
     * emulation (downloading the libraries and provisioning ADI as before).
     *
     * Returns the session on success, or `null` when login failed (the caller
     * should `return 1`).
     */
    final SideloaderSession makeSession()
    {
        string configurationPath = systemConfigurationPath();
        string anisetteServer = resolveAnisetteServer(configurationPath);

        if (anisetteServer.length) {
            getLogger().infoF!"Using remote anisette server: %s"(anisetteServer);
            // Remote anisette: no Android libraries / ADI provisioning needed.
            auto device = app.initializeDevice(configurationPath);
            auto provider = cast(AnisetteProvider) new RemoteAnisetteProvider(anisetteServer);
            auto session = new SideloaderSession(configurationPath);
            session.device = device;
            session.developerSession = login(device, null, provider);
            return session.developerSession ? session : null;
        }

        // Local emulation path (unchanged): download libs + provision ADI.
        scope provisioningData = initializeADI(configurationPath);
        auto session = new SideloaderSession(configurationPath, provisioningData);
        if (!session.ensureLoggedIn((device, adi) => login(device, adi, null)))
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

    // Surface the chosen anisette server to the (commands-unaware) makeSession path.
    g_anisetteServer = commands.anisetteServer.strip();

    // Surface the chosen stored account to the (commands-unaware) login path.
    g_selectedAccount = commands.account.strip();

    try
    {
        return commands.cmd.match!(
                (AppIdCommand cmd) => cmd(),
                (CertificateCommand cmd) => cmd(),
                (DaemonCommand cmd) => cmd(),
                (DeviceCommand cmd) => cmd(),
                (InstallCommand cmd) => cmd(),
                (ListCommand cmd) => cmd(),
                (LoginAccountCommand cmd) => cmd(),
                (LogoutCommand cmd) => cmd(),
                (RefreshCommand cmd) => cmd(),
                (SignCommand cmd) => cmd(),
                (TrollsignCommand cmd) => cmd(),
                (TeamCommand cmd) => cmd(),
                (ToolCommand cmd) => cmd(),
                (UninstallCommand cmd) => cmd(),
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

    @(NamedArgument("anisette-server").Description("Use a remote anisette server (anisette-v1/v3 compatible) instead of local emulation. The URL is persisted as the new default."))
    string anisetteServer = "";

    @(NamedArgument("account").Description("Apple ID to use when several accounts are stored (defaults to the saved default account)."))
    string account = "";

    @SubCommands
    SumType!(AppIdCommand, CertificateCommand, DaemonCommand, DeviceCommand, InstallCommand, ListCommand, LoginAccountCommand, LogoutCommand, RefreshCommand, SignCommand, TrollsignCommand, TeamCommand, ToolCommand, UninstallCommand, VersionCommand) cmd;
}

mixin CLI!Commands.main!entryPoint;

