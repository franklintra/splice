module main;

import core.stdc.signal;

import file = std.file;
import std.traits;

import glib.MessageLog;

import slf4d;
import slf4d.default_provider;
import slf4d.provider;

import app.session : systemConfigurationPath;

import constants;
import utils;

import ui.sideloadergtkapplication;

int main(string[] args) {
    version (linux) {
        import core.stdc.locale;
        setlocale(LC_ALL, "");
    }

    debug {
        Level level = Levels.TRACE;
    } else {
        Level level = Levels.INFO;
    }

    signal(SIGSEGV, cast(Parameters!signal[1]) &SIGSEGV_trace);
    configureLoggingProvider(new shared DefaultProvider(true, level));

    MessageLog.logSetHandler(null, GLogLevelFlags.LEVEL_MASK | GLogLevelFlags.FLAG_FATAL | GLogLevelFlags.FLAG_RECURSION,
        (logDomainC, logLevel, messageC, userData) {
        auto logger = getLogger();
        Levels level;
        with (GLogLevelFlags) switch (logLevel) {
            case LEVEL_DEBUG:
                level = Levels.DEBUG;
                break;
            case LEVEL_INFO:
            case LEVEL_MESSAGE:
                level = Levels.INFO;
                break;
            case LEVEL_WARNING:
            case LEVEL_CRITICAL:
                level = Levels.WARN;
                break;
            default:
                level = Levels.ERROR;
                break;
        }
        import std.string;
        logger.log(level, cast(string) messageC.fromStringz(), null, cast(string) logDomainC.fromStringz(), "");
    }, null);

    // Resolved via the shared core helper (single source of truth, also honours
    // the SIDELOADER_CONFIG_DIR override).
    string configurationPath = systemConfigurationPath();

    auto log = getLogger();
    log.info(versionStr);
    log.infoF!"Configuration path: %s"(configurationPath);
    if (!file.exists(configurationPath)) {
        file.mkdirRecurse(configurationPath);
    }

    return new SideloaderGtkApplication(configurationPath).run(args);
}

private class SegmentationFault: Throwable /+ Throwable since it should not be caught +/ {
    this(string file = __FILE__, size_t line = __LINE__) {
        super("Segmentation fault.", file, line);
    }
}

extern(C) void SIGSEGV_trace(int) @system {
    throw new SegmentationFault();
}
