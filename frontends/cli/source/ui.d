module ui;

/**
 * ui — a small "Rich-style" terminal-output toolkit for the Splice CLI.
 *
 * This is the D analog of Python's Rich, scoped to what the CLI actually needs:
 * a restrained colour theme, styled text spans, section headers/rules, a
 * box-drawing table, status dots and semantic line helpers (success / warning /
 * error / info). Every command draws from the same `Theme` so the whole CLI
 * stays visually coherent.
 *
 * Colour discipline (so we never corrupt machine-readable output):
 *   - Colour is GLOBALLY off unless `setColor(true)` is called, AND it is forced
 *     off whenever `g_jsonOutput` is set (the `--json` document must stay clean).
 *   - `entryPoint` decides the initial state from `isatty(stdout)`, the
 *     `NO_COLOR` convention, and the global `--no-color` flag.
 *   - When colour is off, every helper degrades to plain ASCII-safe text, so
 *     piped output and `--json` are byte-stable.
 *
 * Human-readable text goes to stdout via these helpers; structured `--json`
 * output continues to use `jsonout.printJson`. The two never mix in one command.
 */

import std.array : replicate;
import std.algorithm : max;
import std.conv : to;
import std.process : environment;
import std.stdio;
import std.string : leftJustify;

import jsonout : g_jsonOutput;

// Cross-platform "is stdout a terminal?". POSIX uses isatty(STDOUT_FILENO);
// Windows has no posix.unistd, so go through the CRT's _isatty/_fileno.
version (Windows)
{
    import core.stdc.stdio : FILE, stdout;
    private extern(C) int _isatty(int fd) @nogc nothrow;
    private extern(C) int _fileno(FILE* stream) @nogc nothrow;
    private bool stdoutIsTty() { return _isatty(_fileno(stdout)) != 0; }
}
else
{
    import core.sys.posix.unistd : isatty;
    private bool stdoutIsTty() { return isatty(1) != 0; }
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

/// The CLI's colour palette (256-colour ANSI). One accent, semantic statuses,
/// muted secondary text — deliberately small so output stays calm and coherent.
enum Theme : string
{
    accent = "\033[38;5;39m",   // bright blue   — headers, primary names
    muted  = "\033[38;5;245m",  // grey          — secondary metadata
    ok     = "\033[38;5;42m",   // green         — healthy / success
    warn   = "\033[38;5;214m",  // amber         — caution / expiring soon
    danger = "\033[38;5;203m",  // red           — error / expired / disabled
    bold   = "\033[1m",
    dim    = "\033[2m",
    reset  = "\033[0m",
}

// ---------------------------------------------------------------------------
// Colour state
// ---------------------------------------------------------------------------

private bool g_color = false;

/**
 * Decide and store whether colour should be emitted this run. Call once from
 * `entryPoint` AFTER `g_jsonOutput` is set. `userDisabled` is the global
 * `--no-color` flag. Colour is enabled only when: not `--json`, not `--no-color`,
 * `NO_COLOR` is unset, and stdout is a TTY.
 */
void initColor(bool userDisabled)
{
    // NO_COLOR convention: any non-empty value disables colour.
    if (g_jsonOutput || userDisabled || environment.get("NO_COLOR", "").length > 0)
    {
        g_color = false;
        return;
    }
    g_color = stdoutIsTty();
}

/// Force colour on/off (tests, demos, an explicit `--color`). Honors `--json`.
void setColor(bool on) { g_color = on && !g_jsonOutput; }

/// Whether colour is currently active.
bool colorEnabled() { return g_color; }

// ---------------------------------------------------------------------------
// Spans
// ---------------------------------------------------------------------------

/// Wrap `text` in one or more styles (auto-reset), or return it bare when colour
/// is off. Pass styles via the `Theme` enum: `paint("hi", Theme.accent)`.
string paint(string text, Theme[] styles...)
{
    if (!g_color || styles.length == 0)
        return text;
    string opened;
    foreach (s; styles)
        opened ~= cast(string) s;
    return opened ~ text ~ cast(string) Theme.reset;
}

// ---------------------------------------------------------------------------
// Structure: headers, rules, status dots
// ---------------------------------------------------------------------------

/// A section header: accent bar + bold title (Rich's rule/panel title), with a
/// leading blank line for breathing room.
void header(string title)
{
    writeln();
    writeln(paint("▌ ", Theme.accent) ~ paint(title, Theme.bold));
}

/// Repeat a (possibly multibyte) glyph `n` times.
string hline(size_t n, string glyph = "─")
{
    string s;
    foreach (_; 0 .. n) s ~= glyph;
    return s;
}

/// A faint horizontal rule spanning `width` columns.
void rule(size_t width = 56)
{
    writeln(paint(hline(width), Theme.dim));
}

/// A status dot (●) + label in one colour — the building block for summaries.
string dot(string label, Theme colour)
{
    return paint("●", colour) ~ " " ~ paint(label, colour);
}

// ---------------------------------------------------------------------------
// Semantic lines
// ---------------------------------------------------------------------------

/// `✓ ...` success line (green).
void success(string msg) { writeln(paint("✓", Theme.ok) ~ " " ~ msg); }
/// `! ...` warning line (amber).
void warning(string msg) { writeln(paint("!", Theme.warn) ~ " " ~ msg); }
/// `✗ ...` error line (red).
void failure(string msg) { writeln(paint("✗", Theme.danger) ~ " " ~ msg); }
/// `· ...` informational line (muted). Named `note` (not `info`) to avoid
/// clashing with slf4d's global `info` log function.
void note(string msg)    { writeln(paint("·", Theme.muted) ~ " " ~ msg); }

/// A `key: value` row with a muted key — for compact detail blocks.
void field(string key, string value, size_t keyWidth = 0)
{
    string k = keyWidth ? leftJustify(key, keyWidth) : key;
    writeln("  " ~ paint(k, Theme.muted) ~ "  " ~ value);
}

// ---------------------------------------------------------------------------
// Table
// ---------------------------------------------------------------------------

/// A table column header (the accent/bold styling is applied by `Table`).
struct Column { string title; }

/// A minimal box-drawing table: accent bold headers, a dim underline, and
/// ANSI-aware column padding so coloured cells still align. Two-space gutters,
/// left-aligned. Scoped-down equivalent of Rich's `Table`.
struct Table
{
    Column[] columns;
    private string[][] rows;

    void add(string[] cells...) { rows ~= cells.dup; }

    void render()
    {
        auto widths = new size_t[columns.length];
        foreach (i, col; columns) widths[i] = col.title.length;
        foreach (row; rows)
            foreach (i, cell; row)
                if (i < widths.length)
                    widths[i] = max(widths[i], visibleLen(cell));

        // Header.
        string head;
        foreach (i, col; columns)
            head ~= paint(leftJustify(col.title, widths[i]), Theme.bold, Theme.accent) ~ "  ";
        writeln("  " ~ head);

        // Underline.
        string under;
        foreach (i, _; columns)
            under ~= paint(hline(widths[i]), Theme.dim) ~ "  ";
        writeln("  " ~ under);

        // Body.
        foreach (row; rows)
        {
            string line;
            foreach (i, cell; row)
                line ~= padAnsi(cell, i < widths.length ? widths[i] : 0) ~ "  ";
            writeln("  " ~ line);
        }
    }
}

// ---------------------------------------------------------------------------
// ANSI-aware width helpers
// ---------------------------------------------------------------------------

/// Visible length of `s`, ignoring ANSI escape sequences (`\033[...m`) so that
/// padding/alignment is computed on what the user actually sees.
size_t visibleLen(string s)
{
    size_t n;
    bool inEsc;
    foreach (dchar c; s)
    {
        if (inEsc) { if (c == 'm') inEsc = false; continue; }
        if (c == '\033') { inEsc = true; continue; }
        n++;
    }
    return n;
}

/// Right-pad `s` to a visible width of `w`, accounting for embedded ANSI.
private string padAnsi(string s, size_t w)
{
    auto vis = visibleLen(s);
    return vis >= w ? s : s ~ " ".replicate(w - vis);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest
{
    // With colour off, paint() is a no-op and widths are measured plainly.
    setColor(false);
    assert(paint("hi", Theme.accent) == "hi");
    assert(visibleLen("hi") == 2);

    // visibleLen ignores escape sequences regardless of colour state.
    assert(visibleLen("\033[1mhi\033[0m") == 2);

    // hline counts glyphs, not bytes (─ is 3 bytes in UTF-8).
    assert(visibleLen(hline(4)) == 4);

    // With colour on, paint() wraps and resets.
    setColor(true);
    assert(paint("x", Theme.ok) == "\033[38;5;42mx\033[0m");
    setColor(false);
}
