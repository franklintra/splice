module jsonout;

/**
 * Machine-readable (`--json`) output support for the CLI (issue #15).
 *
 * Two concerns live here:
 *
 *   1. `g_jsonOutput` / `printJson` — a tiny convention for commands to emit a
 *      single JSON document to stdout when the global `--json` flag is set, while
 *      keeping the human-readable `writeln`/`writefln` output for the default
 *      (no `--json`) case unchanged.
 *
 *   2. `StderrLogHandler` — an slf4d `LogHandler` that writes EVERY level to
 *      stderr (mirroring `DefaultLogHandler`'s formatting). The stock handler
 *      writes INFO/DEBUG/TRACE to stdout, which would pollute the JSON document.
 *      In `--json` mode `entryPoint` installs this handler so stdout carries ONLY
 *      the JSON document and logs remain visible on stderr for debugging.
 */

import std.json;
import std.stdio;

import slf4d;
import slf4d.handler;
import slf4d.level;
import slf4d.provider;
import slf4d.default_provider.factory;
import slf4d.default_provider.formatters;

/**
 * Whether the global `--json` flag was passed for this invocation. Set in
 * `entryPoint` (mirroring the existing `g_anisetteServer` / `g_selectedAccount`
 * package-globals), so commands can branch on it without the top-level
 * `Commands` struct being threaded through every call site.
 */
bool g_jsonOutput = false;

/**
 * Prints a JSON document to stdout (pretty-printed, trailing newline) — the
 * single JSON document a `--json` command emits. Logs go to stderr (see
 * `StderrLogHandler`), so stdout stays clean for piping into `jq`/`json.tool`.
 */
void printJson(JSONValue v) {
    writeln(toJSON(v, true));
    stdout.flush();
}

/**
 * Convenience for the handled-error path in `--json` mode: emits
 * `{"error": "<msg>"}` to stdout so scripts get a structured failure rather than
 * a half-written human string.
 */
void printJsonError(string msg) {
    printJson(JSONValue(["error": JSONValue(msg)]));
}

/**
 * An slf4d log handler that writes ALL levels to stderr, using the same
 * formatting as the default provider's handler. Used in `--json` mode so that
 * INFO/DEBUG/TRACE logs (which the stock handler sends to stdout) do not corrupt
 * the JSON document on stdout.
 */
class StderrLogHandler : LogHandler {
    private bool colored;

    public shared this(bool colored = false) {
        this.colored = colored;
    }

    public shared void handle(immutable LogMessage msg) {
        string logStr = formatLogMessage(msg, this.colored);
        stderr.writeln(logStr);
        stderr.flush();
    }
}

/**
 * Builds a logging provider for `--json` mode: an slf4d provider whose single
 * handler routes every level to stderr (via `StderrLogHandler`), at the given
 * root level. This keeps stdout reserved for the JSON document.
 */
shared(LoggingProvider) makeStderrProvider(Level rootLevel) {
    return new shared StderrOnlyProvider(rootLevel);
}

/// Minimal `LoggingProvider` whose factory's handler is a `StderrLogHandler`.
private class StderrOnlyProvider : LoggingProvider {
    private shared DefaultLoggerFactory loggerFactory;

    public shared this(Level rootLevel) {
        auto handler = new shared StderrLogHandler(false);
        this.loggerFactory = new shared DefaultLoggerFactory(handler, rootLevel);
    }

    public shared shared(DefaultLoggerFactory) getLoggerFactory() {
        return this.loggerFactory;
    }
}
