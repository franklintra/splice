module clilog;

/**
 * Lean, themed logging for the human CLI.
 *
 * slf4d's stock handler prints `<padded logger name> <LEVEL> <ISO timestamp>
 * <message>` on every line, which is noisy for an interactive tool. This module
 * provides a handler that, in normal mode, renders each log line as a single
 * `ui`-style glyph + message (no logger name, level word, or timestamp) and
 * routes warnings/errors to stderr. Under `-d/--debug` (root level DEBUG/TRACE)
 * it falls back to slf4d's full default format so diagnostics keep their detail.
 *
 * The `--json` path keeps using `jsonout.makeStderrProvider` (all logs to
 * stderr) so stdout stays a clean JSON document.
 */

import std.stdio;

import slf4d;
import slf4d.handler;
import slf4d.level;
import slf4d.provider;
import slf4d.default_provider.factory;
import slf4d.default_provider.formatters;

import ui : Theme;

/// A themed slf4d handler that renders lean, ui-consistent log lines.
class CleanLogHandler : LogHandler
{
    private bool colored;
    private bool verbose;

    public shared this(bool colored, bool verbose)
    {
        this.colored = colored;
        this.verbose = verbose;
    }

    public shared void handle(immutable LogMessage msg)
    {
        // Warnings/errors → stderr; progress (info/debug/trace) → stdout so it
        // interleaves naturally with the command's own output.
        bool toErr = msg.level.value >= Levels.WARN.value;

        string line;
        if (verbose)
        {
            // Full default format (logger name + timestamp + level) for debugging.
            line = formatLogMessage(msg, colored);
        }
        else
        {
            string glyph, style;
            if (msg.level.value >= Levels.ERROR.value)     { glyph = "✗"; style = cast(string) Theme.danger; }
            else if (msg.level.value >= Levels.WARN.value) { glyph = "!"; style = cast(string) Theme.warn; }
            else                                           { glyph = "·"; style = cast(string) Theme.muted; }

            string g = colored ? style ~ glyph ~ cast(string) Theme.reset : glyph;
            line = g ~ " " ~ msg.message;
        }

        if (toErr) { stderr.writeln(line); stderr.flush(); }
        else       { stdout.writeln(line); stdout.flush(); }
    }
}

/// Builds a provider that installs a single `CleanLogHandler` at `rootLevel`.
/// `verbose` (full default format) is enabled when the root level is DEBUG/TRACE.
shared(LoggingProvider) makeCleanProvider(Level rootLevel, bool colored)
{
    bool verbose = rootLevel.value <= Levels.DEBUG.value;
    return new shared CleanProvider(rootLevel, colored, verbose);
}

private class CleanProvider : LoggingProvider
{
    private shared DefaultLoggerFactory loggerFactory;

    public shared this(Level rootLevel, bool colored, bool verbose)
    {
        auto handler = new shared CleanLogHandler(colored, verbose);
        this.loggerFactory = new shared DefaultLoggerFactory(handler, rootLevel);
    }

    public shared shared(DefaultLoggerFactory) getLoggerFactory()
    {
        return this.loggerFactory;
    }
}
