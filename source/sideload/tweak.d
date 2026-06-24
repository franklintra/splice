module sideload.tweak;

import std.algorithm;
import std.array;
import std.exception;
import file = std.file;
import std.format;
import std.path;
import std.process;
import std.string;
import std.uuid;

import slf4d;

import sideload.application;
import sideload.macho;

/**
 * Injects one or more tweaks (`.dylib` files or `.deb` packages) into an
 * application bundle, before the bundle is signed.
 *
 * For every tweak path:
 *   - a `.dylib` is copied into `<App.app>/Frameworks/` and an `LC_LOAD_DYLIB`
 *     load command pointing at `@executable_path/Frameworks/<name>.dylib` is
 *     inserted into the app's main executable;
 *   - a `.deb` is extracted (an `ar` archive containing `control.tar.*` and
 *     `data.tar.*`); every `.dylib` found inside `data.tar` is treated like a
 *     standalone dylib (copied into Frameworks and injected).
 *
 * The main executable is resolved from the bundle's `Info.plist`
 * (`CFBundleExecutable`) and rewritten in place. The subsequent signing pass
 * (`sideload.sign`) then signs the bundle including the freshly injected
 * dylibs, so no manual signing of the tweaks is required here.
 *
 * Substrate-based tweaks additionally need a substrate runtime
 * (CydiaSubstrate / ElleKit) present at runtime; this is NOT vendored. When an
 * injected dylib depends on such a runtime that is not bundled, a warning is
 * logged — the injection is still performed (best effort).
 */
void injectTweaks(Application app, string[] tweakPaths) {
    auto log = getLogger();

    string bundleDir = app.bundleDir;
    string executableName = app.appInfo["CFBundleExecutable"].str().native();
    string executablePath = bundleDir.buildPath(executableName);
    enforce(file.exists(executablePath),
        format!"Main executable `%s` not found in the bundle."(executablePath));

    string frameworksDir = bundleDir.buildPath("Frameworks");
    if (!file.exists(frameworksDir)) {
        file.mkdirRecurse(frameworksDir);
    }

    // Collect the install names to inject after gathering all the dylibs, so a
    // single .deb contributing several dylibs is handled uniformly.
    string[] dylibsToInject; // absolute source paths of dylibs to copy + inject

    foreach (tweakPath; tweakPaths) {
        enforce(file.exists(tweakPath),
            format!"Tweak `%s` does not exist."(tweakPath));

        switch (tweakPath.extension().toLower()) {
            case ".dylib":
                dylibsToInject ~= tweakPath;
                break;
            case ".deb":
                log.debugF!"Extracting tweak package `%s`..."(baseName(tweakPath));
                dylibsToInject ~= extractDebDylibs(tweakPath);
                break;
            default:
                throw new Exception(
                    format!"Unsupported tweak `%s`: only .dylib and .deb are supported."(tweakPath));
        }
    }

    if (dylibsToInject.length == 0) {
        log.warn("No dylibs found in the provided tweaks; nothing to inject.");
        return;
    }

    // Copy every dylib into Frameworks/ and remember the install names.
    string[] installNames;
    foreach (dylibSource; dylibsToInject) {
        string dylibName = baseName(dylibSource);
        string destination = frameworksDir.buildPath(dylibName);
        if (file.exists(destination)) {
            log.warnF!"`%s` already exists in Frameworks, overwriting."(dylibName);
        }
        file.copy(dylibSource, destination);
        string installName = "@executable_path/Frameworks/" ~ dylibName;
        installNames ~= installName;
        log.debugF!"Bundled tweak dylib `%s` (install name `%s`)."(dylibName, installName);

        warnAboutSubstrateDependency(destination, frameworksDir, log);
    }

    // Patch the main executable: inject an LC_LOAD_DYLIB per dylib, into every
    // architecture slice of the (possibly fat) executable.
    ubyte[] executableData = cast(ubyte[]) file.read(executablePath);
    MachO[] machOs = MachO.parse(executableData);
    foreach (ref machO; machOs) {
        foreach (installName; installNames) {
            machO.addLoadDylib(installName);
        }
    }
    file.write(executablePath, makeMachO(machOs));

    log.infoF!"Injected %d dylib(s) into `%s`."(installNames.length, executableName);
}

/**
 * Extracts the dylibs contained in a `.deb` tweak package and returns the
 * absolute paths to the extracted `.dylib` files (in a fresh temp directory).
 *
 * A `.deb` is an `ar` archive holding `control.tar.*` and `data.tar.*`. The
 * dylibs live in `data.tar.*` (typically under
 * `/Library/MobileSubstrate/DynamicLibraries/*.dylib` or `/usr/lib/*.dylib`).
 * The system `ar` and `tar` tools are used to unpack it.
 */
private string[] extractDebDylibs(string debPath) {
    auto log = getLogger();

    string workDir = file.tempDir().buildPath("Sideloader-deb-" ~ randomUUID().toString());
    file.mkdirRecurse(workDir);

    // 1. Unpack the ar archive to get data.tar.*
    auto arResult = execute(["ar", "x", debPath.absolutePath()], null, Config.none, size_t.max, workDir);
    enforce(arResult.status == 0,
        format!"`ar` failed to extract `%s`: %s"(baseName(debPath), arResult.output));

    auto dataArchives = file.dirEntries(workDir, "data.tar*", file.SpanMode.shallow).array();
    enforce(dataArchives.length > 0,
        format!"No data.tar archive found inside `%s`."(baseName(debPath)));

    // 2. Extract data.tar.* into a sub-directory. tar autodetects the
    //    compression (gz/xz/bz2/lzma) from the contents.
    string dataDir = workDir.buildPath("data");
    file.mkdirRecurse(dataDir);
    auto tarResult = execute(["tar", "xf", dataArchives[0].name, "-C", dataDir]);
    enforce(tarResult.status == 0,
        format!"`tar` failed to extract `%s`: %s"(baseName(dataArchives[0].name), tarResult.output));

    // 3. Find every .dylib in the extracted tree.
    auto dylibs = file.dirEntries(dataDir, file.SpanMode.breadth)
        .filter!((f) => f.isFile && f.name.toLower().endsWith(".dylib"))
        .map!((f) => f.name)
        .array();

    if (dylibs.length == 0) {
        log.warnF!"No dylibs found in `%s` (looked under data.tar)."(baseName(debPath));
    } else {
        log.debugF!"Found %d dylib(s) in `%s`."(dylibs.length, baseName(debPath));
    }

    return dylibs;
}

/**
 * Best-effort heuristic warning: if an injected dylib links against a substrate
 * runtime (CydiaSubstrate / libsubstrate / ElleKit) that is not also bundled in
 * Frameworks/, warn the user that the tweak will not load without one present.
 * Uses `otool -L` when available; failure to inspect is non-fatal.
 */
private void warnAboutSubstrateDependency(string dylibPath, string frameworksDir, Logger log) {
    string[] deps;
    try {
        auto otool = execute(["otool", "-L", dylibPath]);
        if (otool.status != 0)
            return;
        deps = otool.output.lineSplitter().map!((l) => l.strip()).array();
    } catch (Exception) {
        return; // otool not available (e.g. non-macOS host) — skip the check.
    }

    static immutable substrateMarkers = [
        "CydiaSubstrate", "libsubstrate", "MobileSubstrate", "ellekit", "ElleKit",
    ];

    foreach (dep; deps) {
        foreach (marker; substrateMarkers) {
            if (dep.canFind(marker)) {
                // Extract the leaf name to check whether we bundled it too.
                string depName = baseName(dep.split(" ")[0]);
                if (!file.exists(frameworksDir.buildPath(depName))) {
                    log.warnF!(
                        "`%s` depends on a substrate runtime (`%s`) that is not bundled. "
                        ~ "The tweak will need CydiaSubstrate/ElleKit present on the device to load.")(
                        baseName(dylibPath), dep);
                }
                return;
            }
        }
    }
}
