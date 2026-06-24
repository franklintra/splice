module service;

/**
 * `splice service <install|uninstall|status>` (#11).
 *
 * Generates and manages a per-user background service unit that periodically
 * runs `splice daemon --once` so installed free-account apps get re-signed
 * before their (~7 day) provisioning profile expires — without the user having
 * to keep a terminal open.
 *
 * Three platforms are supported:
 *   - macOS:   a launchd LaunchAgent plist under ~/Library/LaunchAgents,
 *              loaded with `launchctl`. (Fully implemented and testable here.)
 *   - Linux:   a systemd *user* service + timer under ~/.config/systemd/user,
 *              enabled with `systemctl --user`.
 *   - Windows: a Task Scheduler task created with `schtasks`.
 *
 * The pure unit-file/string generators (`launchdPlist`, `systemdService`,
 * `systemdTimer`, `schtasksArgs`) live here with unittests so they can be
 * verified offline on any host.
 *
 * Testability: the macOS unit directory honours the `SIDELOADER_LAUNCH_AGENTS_DIR`
 * environment override (and a hidden `--unit-dir` flag) so tests can redirect it
 * to a temp directory instead of the user's real `~/Library/LaunchAgents`.
 */

import std.conv : to;
import std.path : buildPath, expandTilde;
import std.process : environment, execute, Config;
import std.string : strip;

import ui;
import std.sumtype;
import file = std.file;

import slf4d;

import argparse;

import app.session : systemConfigurationPath;

import cli_frontend;

/// Reverse-DNS service label / identifier. (Lowercase to match unit conventions;
/// the keyring schema uses the mixed-case `dev.dadoum.Sideloader` app id.)
enum serviceLabel = "dev.dadoum.sideloader";

/// Default refresh cadence for the scheduled service: every 6 hours. A free
/// profile lives ~7 days and the daemon refreshes within 48h of expiry, so a
/// few checks per day comfortably catches every app without hammering Apple.
enum uint defaultIntervalSeconds = 6 * 3600;

@(Command("service").Description("Install/uninstall a background service that periodically refreshes your apps."))
struct ServiceCommand
{
    int opCall()
    {
        return cmd.match!(
                (InstallService cmd) => cmd(),
                (UninstallService cmd) => cmd(),
                (StatusService cmd) => cmd()
        );
    }

    @SubCommands
    SumType!(InstallService, UninstallService, StatusService) cmd;
}

// ---------------------------------------------------------------------------
// Subcommands
// ---------------------------------------------------------------------------

@(Command("install").Description("Generate the platform service unit and enable it."))
struct InstallService
{
    @(NamedArgument("interval").Description("Refresh interval in seconds (default 21600 = every 6 hours)."))
    uint interval = defaultIntervalSeconds;

    @(NamedArgument("no-notify").Description("Pass --no-notify to the scheduled daemon (suppress desktop notifications)."))
    bool noNotify = false;

    @(NamedArgument("unit-dir").Description("Override the directory the unit is written to (testing). Also honours SIDELOADER_LAUNCH_AGENTS_DIR / SIDELOADER_SYSTEMD_USER_DIR."))
    string unitDir = null;

    int opCall()
    {
        auto log = getLogger();
        if (interval < 60) {
            log.error("Refresh interval must be at least 60 seconds.");
            return 1;
        }
        return installService(interval, noNotify, unitDir.strip());
    }
}

@(Command("uninstall").Description("Disable and remove the background service. Idempotent."))
struct UninstallService
{
    @(NamedArgument("unit-dir").Description("Override the directory the unit is in (testing)."))
    string unitDir = null;

    int opCall()
    {
        return uninstallService(unitDir.strip());
    }
}

@(Command("status").Description("Report whether the background service is installed and its schedule. Works offline."))
struct StatusService
{
    @(NamedArgument("unit-dir").Description("Override the directory the unit is in (testing)."))
    string unitDir = null;

    int opCall()
    {
        return statusService(unitDir.strip());
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Absolute path to the currently running CLI binary; the unit invokes this.
private string currentExePath()
{
    return file.thisExePath();
}

/// Directory under the config path where the scheduled daemon writes its logs.
private string serviceLogDir()
{
    return systemConfigurationPath().buildPath("logs");
}

// ---------------------------------------------------------------------------
// Pure unit/command generators (unit-tested below)
// ---------------------------------------------------------------------------

/**
 * Builds a launchd LaunchAgent plist that runs `<exePath> daemon --once
 * [--no-notify]` every `interval` seconds, redirecting stdout/stderr to the
 * given log files.
 *
 * Pure: takes everything it needs as parameters so it can be unit-tested and
 * lint-checked without touching the filesystem.
 */
string launchdPlist(string exePath, uint interval, bool noNotify, string outLog, string errLog) pure @safe
{
    import std.array : appender;
    auto s = appender!string();
    s.put(`<?xml version="1.0" encoding="UTF-8"?>` ~ "\n");
    s.put(`<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">` ~ "\n");
    s.put(`<plist version="1.0">` ~ "\n");
    s.put("<dict>\n");
    s.put("    <key>Label</key>\n");
    s.put("    <string>" ~ xmlEscape(serviceLabel) ~ "</string>\n");
    s.put("    <key>ProgramArguments</key>\n");
    s.put("    <array>\n");
    s.put("        <string>" ~ xmlEscape(exePath) ~ "</string>\n");
    s.put("        <string>daemon</string>\n");
    s.put("        <string>--once</string>\n");
    if (noNotify)
        s.put("        <string>--no-notify</string>\n");
    s.put("    </array>\n");
    s.put("    <key>StartInterval</key>\n");
    s.put("    <integer>" ~ interval.to!string ~ "</integer>\n");
    // Don't fire a heavy refresh the instant the agent loads (e.g. at login);
    // wait for the first interval tick instead.
    s.put("    <key>RunAtLoad</key>\n");
    s.put("    <false/>\n");
    s.put("    <key>StandardOutPath</key>\n");
    s.put("    <string>" ~ xmlEscape(outLog) ~ "</string>\n");
    s.put("    <key>StandardErrorPath</key>\n");
    s.put("    <string>" ~ xmlEscape(errLog) ~ "</string>\n");
    s.put("    <key>ProcessType</key>\n");
    s.put("    <string>Background</string>\n");
    s.put("</dict>\n");
    s.put("</plist>\n");
    return s.data;
}

/**
 * Builds the systemd *user* `.service` unit (Type=oneshot) that runs
 * `<exePath> daemon --once [--no-notify]`.
 */
string systemdService(string exePath, bool noNotify) pure @safe
{
    string exec = systemdQuote(exePath) ~ " daemon --once";
    if (noNotify)
        exec ~= " --no-notify";
    return
        "[Unit]\n" ~
        "Description=Splice app refresh (re-sign apps before they expire)\n" ~
        "\n" ~
        "[Service]\n" ~
        "Type=oneshot\n" ~
        "ExecStart=" ~ exec ~ "\n";
}

/**
 * Builds the systemd *user* `.timer` unit that triggers the service every
 * `interval` seconds and shortly after boot.
 */
string systemdTimer(uint interval) pure @safe
{
    return
        "[Unit]\n" ~
        "Description=Periodic Splice app refresh\n" ~
        "\n" ~
        "[Timer]\n" ~
        "OnBootSec=120\n" ~
        "OnUnitActiveSec=" ~ interval.to!string ~ "\n" ~
        "Persistent=true\n" ~
        "\n" ~
        "[Install]\n" ~
        "WantedBy=timers.target\n";
}

/**
 * Builds the `schtasks /Create` argument vector that registers a Windows Task
 * Scheduler task running the exe daemon at the given interval (minutes,
 * rounded up to >=1). Returned as an argument array (no shell), so the exe path
 * and label need no manual quoting.
 */
string[] schtasksArgs(string exePath, uint interval, bool noNotify) pure @safe
{
    uint minutes = (interval + 59) / 60;
    if (minutes < 1) minutes = 1;
    // The task runs the exe with arguments; schtasks /TR takes a single command
    // string, so quote the path and append the daemon arguments.
    string tr = "\"" ~ exePath ~ "\" daemon --once" ~ (noNotify ? " --no-notify" : "");
    return [
        "schtasks", "/Create",
        "/TN", "Sideloader\\Refresh",
        "/TR", tr,
        "/SC", "MINUTE",
        "/MO", minutes.to!string,
        "/F",
    ];
}

/// Minimal XML-attribute/text escaping for plist string values.
string xmlEscape(string s) pure @safe
{
    import std.array : appender;
    auto sink = appender!string();
    foreach (dchar c; s)
    {
        switch (c)
        {
            case '&': sink.put("&amp;"); break;
            case '<': sink.put("&lt;"); break;
            case '>': sink.put("&gt;"); break;
            case '"': sink.put("&quot;"); break;
            case '\'': sink.put("&apos;"); break;
            default: sink.put(c); break;
        }
    }
    return sink.data;
}

/// Quotes a path for a systemd ExecStart= line if it contains whitespace.
string systemdQuote(string path) pure @safe
{
    import std.algorithm.searching : canFind;
    if (path.canFind(' ') || path.canFind('\t'))
        return "\"" ~ path ~ "\"";
    return path;
}

// ---------------------------------------------------------------------------
// Platform install/uninstall/status
// ---------------------------------------------------------------------------

version (OSX)
{
    /// Resolves the LaunchAgents directory: explicit override > env override >
    /// the real per-user `~/Library/LaunchAgents`.
    private string launchAgentsDir(string unitDirOverride)
    {
        if (unitDirOverride.length)
            return unitDirOverride;
        string env = environment.get("SIDELOADER_LAUNCH_AGENTS_DIR", "");
        if (env.length)
            return env;
        return "~/Library/LaunchAgents".expandTilde();
    }

    private string plistPath(string unitDirOverride)
    {
        return launchAgentsDir(unitDirOverride).buildPath(serviceLabel ~ ".plist");
    }

    private int installService(uint interval, bool noNotify, string unitDirOverride)
    {
        auto log = getLogger();
        string dir = launchAgentsDir(unitDirOverride);
        file.mkdirRecurse(dir);
        file.mkdirRecurse(serviceLogDir());

        string path = plistPath(unitDirOverride);
        string outLog = serviceLogDir().buildPath("daemon.out.log");
        string errLog = serviceLogDir().buildPath("daemon.err.log");
        string content = launchdPlist(currentExePath(), interval, noNotify, outLog, errLog);

        // If one is already loaded, unload it first so we cleanly replace it.
        bootout(path, silent: true);

        file.write(path, content);
        log.infoF!"Wrote launch agent to %s"(path);

        if (bootstrap(path))
            log.infoF!"Loaded launch agent %s (refreshes every %d seconds)."(serviceLabel, interval);
        else
            log.warnF!"Wrote the plist but could not load it automatically. Load it with: launchctl bootstrap gui/$(id -u) %s"(path);

        log.infoF!"Check it with: launchctl print gui/$(id -u)/%s  (logs: %s)"(serviceLabel, serviceLogDir());
        return 0;
    }

    private int uninstallService(string unitDirOverride)
    {
        auto log = getLogger();
        string path = plistPath(unitDirOverride);

        bootout(path, silent: false);

        if (file.exists(path))
        {
            file.remove(path);
            log.infoF!"Removed %s"(path);
        }
        else
        {
            log.info("No launch agent was installed; nothing to remove.");
        }
        return 0;
    }

    private int statusService(string unitDirOverride)
    {
        auto log = getLogger();
        string path = plistPath(unitDirOverride);

        if (!file.exists(path))
        {
            writeln("Splice background service: " ~ dot("not installed", Theme.warn));
            writefln!"  (expected unit at %s)"(path);
            return 0;
        }

        writeln("Splice background service: " ~ dot("installed", Theme.ok));
        writefln!"  Unit: %s"(path);

        // Best-effort: ask launchctl whether it's currently loaded.
        try
        {
            auto uid = getUid();
            auto res = execute(["launchctl", "print", "gui/" ~ uid ~ "/" ~ serviceLabel], null, Config.none);
            if (res.status == 0)
                writeln("  Loaded: yes (launchctl knows this label).");
            else
                writeln("  Loaded: no (the plist exists but is not currently loaded).");
        }
        catch (Exception e)
        {
            log.debugF!"launchctl print failed (ignored): %s"(e.msg);
            writeln("  Loaded: unknown (could not query launchctl).");
        }

        writefln!"  Logs: %s"(serviceLogDir());
        return 0;
    }

    private string getUid()
    {
        auto res = execute(["id", "-u"], null, Config.none);
        return res.output.strip();
    }

    /// `launchctl bootstrap gui/<uid> <plist>`. Returns true on success.
    private bool bootstrap(string path)
    {
        auto log = getLogger();
        try
        {
            string uid = getUid();
            auto res = execute(["launchctl", "bootstrap", "gui/" ~ uid, path], null, Config.none);
            if (res.status != 0)
                log.debugF!"launchctl bootstrap exited %d: %s"(res.status, res.output.strip());
            return res.status == 0;
        }
        catch (Exception e)
        {
            log.debugF!"launchctl bootstrap failed: %s"(e.msg);
            return false;
        }
    }

    /// `launchctl bootout gui/<uid> <plist>`. Idempotent; ignores "not loaded".
    private void bootout(string path, bool silent)
    {
        auto log = getLogger();
        try
        {
            string uid = getUid();
            auto res = execute(["launchctl", "bootout", "gui/" ~ uid, path], null, Config.none);
            if (res.status != 0 && !silent)
                log.debugF!"launchctl bootout exited %d (likely not loaded): %s"(res.status, res.output.strip());
        }
        catch (Exception e)
        {
            if (!silent)
                log.debugF!"launchctl bootout failed (ignored): %s"(e.msg);
        }
    }
}
else version (linux)
{
    private string systemdUserDir(string unitDirOverride)
    {
        if (unitDirOverride.length)
            return unitDirOverride;
        string env = environment.get("SIDELOADER_SYSTEMD_USER_DIR", "");
        if (env.length)
            return env;
        string xdg = environment.get("XDG_CONFIG_HOME", "");
        string base = xdg.length ? xdg : "~/.config".expandTilde();
        return base.buildPath("systemd", "user");
    }

    enum serviceUnitName = "sideloader-refresh.service";
    enum timerUnitName = "sideloader-refresh.timer";

    private int installService(uint interval, bool noNotify, string unitDirOverride)
    {
        auto log = getLogger();
        string dir = systemdUserDir(unitDirOverride);
        file.mkdirRecurse(dir);

        string servicePath = dir.buildPath(serviceUnitName);
        string timerPath = dir.buildPath(timerUnitName);

        file.write(servicePath, systemdService(currentExePath(), noNotify));
        file.write(timerPath, systemdTimer(interval));
        log.infoF!"Wrote %s and %s"(servicePath, timerPath);

        // Reload + enable (best effort; no-op if systemd isn't the init system).
        runSystemctl(["systemctl", "--user", "daemon-reload"]);
        if (runSystemctl(["systemctl", "--user", "enable", "--now", timerUnitName]))
            log.infoF!"Enabled %s (refreshes every %d seconds)."(timerUnitName, interval);
        else
            log.warnF!"Wrote the units but could not enable the timer automatically. Enable it with: systemctl --user enable --now %s"(timerUnitName);

        log.infoF!"Check it with: systemctl --user status %s"(timerUnitName);
        return 0;
    }

    private int uninstallService(string unitDirOverride)
    {
        auto log = getLogger();
        string dir = systemdUserDir(unitDirOverride);
        string servicePath = dir.buildPath(serviceUnitName);
        string timerPath = dir.buildPath(timerUnitName);

        runSystemctl(["systemctl", "--user", "disable", "--now", timerUnitName]);

        bool removed = false;
        foreach (p; [timerPath, servicePath])
        {
            if (file.exists(p)) { file.remove(p); removed = true; log.infoF!"Removed %s"(p); }
        }
        runSystemctl(["systemctl", "--user", "daemon-reload"]);
        if (!removed)
            log.info("No systemd units were installed; nothing to remove.");
        return 0;
    }

    private int statusService(string unitDirOverride)
    {
        string dir = systemdUserDir(unitDirOverride);
        string timerPath = dir.buildPath(timerUnitName);
        if (!file.exists(timerPath))
        {
            writeln("Splice background service: " ~ dot("not installed", Theme.warn));
            writefln!"  (expected unit at %s)"(timerPath);
            return 0;
        }
        writeln("Splice background service: " ~ dot("installed", Theme.ok));
        writefln!"  Units: %s"(dir);
        auto res = trySystemctl(["systemctl", "--user", "is-active", timerUnitName]);
        writefln!"  Timer active: %s"(res.length ? res : "unknown");
        return 0;
    }

    private bool runSystemctl(string[] args)
    {
        auto log = getLogger();
        try
        {
            auto res = execute(args, null, Config.none);
            if (res.status != 0)
                log.debugF!"%s exited %d: %s"(args[0], res.status, res.output.strip());
            return res.status == 0;
        }
        catch (Exception e)
        {
            log.debugF!"systemctl failed (ignored): %s"(e.msg);
            return false;
        }
    }

    private string trySystemctl(string[] args)
    {
        try { return execute(args, null, Config.none).output.strip(); }
        catch (Exception) { return ""; }
    }
}
else version (Windows)
{
    private int installService(uint interval, bool noNotify, string unitDirOverride)
    {
        auto log = getLogger();
        auto args = schtasksArgs(currentExePath(), interval, noNotify);
        try
        {
            auto res = execute(args, null, Config.none);
            if (res.status == 0)
                log.infoF!"Created scheduled task Sideloader\\Refresh (every ~%d minutes)."((interval + 59) / 60);
            else
            {
                log.errorF!"schtasks failed (%d): %s"(res.status, res.output.strip());
                return 1;
            }
        }
        catch (Exception e)
        {
            log.errorF!"Could not run schtasks: %s"(e.msg);
            return 1;
        }
        log.info("Check it with: schtasks /Query /TN Sideloader\\Refresh");
        return 0;
    }

    private int uninstallService(string unitDirOverride)
    {
        auto log = getLogger();
        try
        {
            auto res = execute(["schtasks", "/Delete", "/TN", "Sideloader\\Refresh", "/F"], null, Config.none);
            if (res.status == 0)
                log.info("Removed scheduled task Sideloader\\Refresh.");
            else
                log.info("No scheduled task was installed; nothing to remove.");
        }
        catch (Exception e)
        {
            log.debugF!"schtasks /Delete failed (ignored): %s"(e.msg);
        }
        return 0;
    }

    private int statusService(string unitDirOverride)
    {
        try
        {
            auto res = execute(["schtasks", "/Query", "/TN", "Sideloader\\Refresh"], null, Config.none);
            if (res.status == 0)
            {
                writeln("Splice background service: " ~ dot("installed", Theme.ok));
                writeln(res.output.strip());
            }
            else
                writeln("Splice background service: " ~ dot("not installed", Theme.warn));
        }
        catch (Exception)
        {
            writeln("Splice background service: " ~ dot("unknown", Theme.muted) ~ " (could not query schtasks).");
        }
        return 0;
    }
}
else
{
    private int installService(uint, bool, string) { getLogger().error("Background service is not supported on this platform."); return 1; }
    private int uninstallService(string) { getLogger().error("Background service is not supported on this platform."); return 1; }
    private int statusService(string) { writeln("Splice background service: " ~ dot("unsupported on this platform", Theme.muted)); return 0; }
}

import std.stdio : writeln, writefln;

// ---------------------------------------------------------------------------
// unittests: pure generators
// ---------------------------------------------------------------------------

unittest
{
    import std.algorithm.searching : canFind;
    auto plist = launchdPlist("/usr/local/bin/sideloader", 21600, false,
        "/tmp/out.log", "/tmp/err.log");
    assert(plist.canFind("<key>Label</key>"));
    assert(plist.canFind("<string>dev.dadoum.sideloader</string>"));
    assert(plist.canFind("<string>/usr/local/bin/sideloader</string>"));
    assert(plist.canFind("<string>daemon</string>"));
    assert(plist.canFind("<string>--once</string>"));
    assert(plist.canFind("<key>StartInterval</key>"));
    assert(plist.canFind("<integer>21600</integer>"));
    assert(plist.canFind("<key>StandardOutPath</key>"));
    assert(plist.canFind("/tmp/out.log"));
    assert(plist.canFind("/tmp/err.log"));
    // RunAtLoad is present and false.
    assert(plist.canFind("<key>RunAtLoad</key>"));
    // --no-notify only present when requested.
    assert(!plist.canFind("--no-notify"));
}

unittest
{
    import std.algorithm.searching : canFind;
    auto plist = launchdPlist("/opt/homebrew/bin/sideloader", 3600, true, "/o", "/e");
    assert(plist.canFind("<string>--no-notify</string>"));
    // Path with no special chars round-trips unescaped.
    assert(plist.canFind("/opt/homebrew/bin/sideloader"));
}

unittest
{
    // xmlEscape protects against an exe path containing XML metacharacters.
    import std.algorithm.searching : canFind;
    auto plist = launchdPlist("/Users/a&b/<x>/sideloader", 3600, false, "/o", "/e");
    assert(plist.canFind("/Users/a&amp;b/&lt;x&gt;/sideloader"));
    assert(!plist.canFind("/Users/a&b/<x>"));
}

unittest
{
    import std.algorithm.searching : canFind;
    auto svc = systemdService("/usr/bin/sideloader", false);
    assert(svc.canFind("Type=oneshot"));
    assert(svc.canFind("ExecStart=/usr/bin/sideloader daemon --once"));
    assert(!svc.canFind("--no-notify"));

    auto svc2 = systemdService("/usr/bin/sideloader", true);
    assert(svc2.canFind("ExecStart=/usr/bin/sideloader daemon --once --no-notify"));

    // A path with a space gets quoted.
    auto svc3 = systemdService("/opt/My Apps/sideloader", false);
    assert(svc3.canFind("ExecStart=\"/opt/My Apps/sideloader\" daemon --once"));
}

unittest
{
    import std.algorithm.searching : canFind;
    auto timer = systemdTimer(21600);
    assert(timer.canFind("[Timer]"));
    assert(timer.canFind("OnUnitActiveSec=21600"));
    assert(timer.canFind("WantedBy=timers.target"));
}

unittest
{
    auto args = schtasksArgs(`C:\Program Files\sideloader.exe`, 3600, false);
    assert(args[0] == "schtasks");
    assert(args[1] == "/Create");
    import std.algorithm.searching : canFind;
    assert(args.canFind("/SC"));
    assert(args.canFind("MINUTE"));
    assert(args.canFind("/MO"));
    // 3600s -> 60 minutes.
    assert(args.canFind("60"));
    // The /TR command string embeds the quoted exe + daemon --once.
    bool foundTr = false;
    foreach (a; args)
        if (a.canFind("daemon --once") && a.canFind("sideloader.exe"))
            foundTr = true;
    assert(foundTr);

    // Sub-minute interval rounds up to 1; --no-notify is appended.
    auto args2 = schtasksArgs("x.exe", 30, true);
    import std.algorithm.searching : canFind;
    assert(args2.canFind("1"));
    bool noNotify = false;
    foreach (a; args2) if (a.canFind("--no-notify")) noNotify = true;
    assert(noNotify);
}
