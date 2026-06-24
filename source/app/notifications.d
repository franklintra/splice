module app.notifications;

/**
 * Cross-platform native desktop notifications for the background refresh
 * daemon/service (#11).
 *
 * The daemon runs unattended under launchd / systemd / Task Scheduler, so when
 * it refreshes an app (or fails to, or an app is about to expire with no device
 * connected) the only sensible way to surface that to the user is a native
 * desktop notification.
 *
 * Design goals:
 *   - Best effort and NON-FATAL: if the platform tool is missing (e.g. no
 *     `notify-send`, no `osascript`), we log at debug and return — never crash
 *     the daemon over a cosmetic notification.
 *   - Safe: notification text frequently contains user-controlled app names, so
 *     we pass them as discrete process arguments (`std.process.execute`) rather
 *     than building a shell command string. The one exception is macOS
 *     `osascript -e`, whose single script argument embeds the strings; there we
 *     escape backslashes and double-quotes (see `escapeAppleScriptString`).
 */

import std.process : execute, Config;

import slf4d;

/**
 * Shows a native desktop notification with the given `title` and `message`.
 *
 * Dispatches per platform:
 *   - macOS:   `osascript -e 'display notification "<msg>" with title "<title>"'`
 *   - Linux:   `notify-send <title> <message>`
 *   - Windows: a PowerShell toast (best effort).
 *
 * Always best effort: a missing tool or a non-zero exit is logged at debug/warn
 * and swallowed, so callers can fire notifications freely without guarding.
 */
void notify(string title, string message) nothrow
{
    try
    {
        version (OSX)
        {
            notifyMacOS(title, message);
        }
        else version (linux)
        {
            notifyLinux(title, message);
        }
        else version (Windows)
        {
            notifyWindows(title, message);
        }
        else
        {
            // Unknown platform: nothing to do.
        }
    }
    catch (Exception e)
    {
        // Notifications are cosmetic; never let them take down the daemon.
        try { getLogger().debugF!"Notification failed (ignored): %s"(e.msg); } catch (Exception) {}
    }
}

version (OSX)
private void notifyMacOS(string title, string message)
{
    // `osascript -e <script>` takes the whole AppleScript as ONE argument, so we
    // must embed the (possibly user-controlled) strings into the script and
    // escape them for AppleScript string literals.
    string script = "display notification \"" ~ escapeAppleScriptString(message)
        ~ "\" with title \"" ~ escapeAppleScriptString(title) ~ "\"";
    runNotifier(["osascript", "-e", script], "osascript");
}

version (linux)
private void notifyLinux(string title, string message)
{
    // notify-send takes title and body as separate arguments — no shell, no
    // escaping needed.
    runNotifier(["notify-send", "--app-name=Sideloader", title, message], "notify-send");
}

version (Windows)
private void notifyWindows(string title, string message)
{
    // Best-effort balloon/toast via PowerShell. Strings are passed inside a
    // PowerShell here-script argument; single-quote escaping (double the quote)
    // keeps them inert. Falls back silently if PowerShell is unavailable.
    string ps =
        "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms');" ~
        "$n = New-Object System.Windows.Forms.NotifyIcon;" ~
        "$n.Icon = [System.Drawing.SystemIcons]::Information;" ~
        "$n.BalloonTipTitle = '" ~ escapePowerShellSingleQuoted(title) ~ "';" ~
        "$n.BalloonTipText = '" ~ escapePowerShellSingleQuoted(message) ~ "';" ~
        "$n.Visible = $true; $n.ShowBalloonTip(5000); Start-Sleep -Seconds 6; $n.Dispose();";
    runNotifier(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps], "powershell");
}

/// Runs the notifier process, swallowing "tool not found" and non-zero exits.
private void runNotifier(string[] args, string toolName)
{
    auto log = getLogger();
    try
    {
        auto result = execute(args, null, Config.none);
        if (result.status != 0)
            log.debugF!"%s exited with status %d while notifying (ignored)."(toolName, result.status);
    }
    catch (Exception e)
    {
        // ProcessException when the binary is missing, etc.
        log.debugF!"Could not run %s for notifications (ignored): %s"(toolName, e.msg);
    }
}

/**
 * Escapes a string for embedding inside an AppleScript double-quoted string
 * literal. Backslashes must be doubled and double-quotes escaped; we also strip
 * raw newlines/CRs which would terminate the `-e` line.
 *
 * Pure so it can be unit-tested without spawning `osascript`.
 */
string escapeAppleScriptString(string s) pure @safe
{
    import std.array : appender;
    auto sink = appender!string();
    foreach (dchar c; s)
    {
        switch (c)
        {
            case '\\': sink.put("\\\\"); break;
            case '"':  sink.put("\\\""); break;
            case '\n': sink.put(' '); break;
            case '\r': break;
            default:   sink.put(c); break;
        }
    }
    return sink.data;
}

/**
 * Escapes a string for embedding inside a PowerShell single-quoted literal:
 * the only metacharacter is the single quote, escaped by doubling it. Raw
 * newlines are flattened to spaces.
 */
string escapePowerShellSingleQuoted(string s) pure @safe
{
    import std.array : appender;
    auto sink = appender!string();
    foreach (dchar c; s)
    {
        switch (c)
        {
            case '\'': sink.put("''"); break;
            case '\n':
            case '\r': sink.put(' '); break;
            default:   sink.put(c); break;
        }
    }
    return sink.data;
}

// ---------------------------------------------------------------------------
// unittests: pure escaping logic (no process spawned)
// ---------------------------------------------------------------------------

unittest
{
    // AppleScript escaping: backslash doubled, quote escaped, newline flattened.
    assert(escapeAppleScriptString(`hello`) == `hello`);
    assert(escapeAppleScriptString(`a"b`) == `a\"b`);
    assert(escapeAppleScriptString(`a\b`) == `a\\b`);
    assert(escapeAppleScriptString("a\nb") == "a b");
    assert(escapeAppleScriptString("a\r\nb") == "a b");
    // A classic injection attempt cannot break out of the string literal.
    auto evil = escapeAppleScriptString(`" & (do shell script "rm -rf /") & "`);
    assert(evil == `\" & (do shell script \"rm -rf /\") & \"`);
}

unittest
{
    // PowerShell single-quote escaping doubles the quote.
    assert(escapePowerShellSingleQuoted(`hello`) == `hello`);
    assert(escapePowerShellSingleQuoted(`it's`) == `it''s`);
    assert(escapePowerShellSingleQuoted("a\nb") == "a b");
}
