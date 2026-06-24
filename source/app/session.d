module app.session;

import std.algorithm;
import std.array;
import std.exception;
import std.path;
import std.process;

import provision;

import server.developersession;

import app;
import utils;

/**
 * Resolves the configuration directory shared by every Sideloader frontend.
 *
 * Honours the `SIDELOADER_CONFIG_DIR` environment override and otherwise falls
 * back to the per-OS default location. This is the single source of truth for
 * the configuration path: frontends must use it instead of recomputing the
 * logic locally.
 */
string systemConfigurationPath()
{
    return environment.get("SIDELOADER_CONFIG_DIR").orDefault(defaultConfigurationPath());
}

/// ditto
string defaultConfigurationPath()
{
    version (Windows) {
        string configurationPath = environment["AppData"];
    } else version (OSX) {
        string configurationPath = "~/Library/Preferences/".expandTilde();
    } else {
        string configurationPath = environment.get("XDG_CONFIG_DIR")
            .orDefault("~/.config")
            .expandTilde();
    }
    return configurationPath.buildPath("Sideloader");
}

/**
 * Login strategy used by `SideloaderSession.ensureLoggedIn`.
 *
 * The actual credential prompting (Apple ID / password / 2FA over stdin for the
 * CLI, or a dialog for the GUIs) is frontend-specific, so it is injected here.
 * The delegate receives the provisioned `Device` and `ADI` and returns a logged
 * in `DeveloperSession`, or `null` on failure/cancellation.
 */
alias LoginStrategy = DeveloperSession delegate(Device device, ADI adi);

/**
 * Shared bootstrap state for every Sideloader frontend.
 *
 * Owns the resolved configuration path, the ADI provisioning (`Device` + `ADI`)
 * and, once logged in, the `DeveloperSession`. It also provides the team
 * selection helper that every command used to duplicate.
 *
 * Frontends construct it, provision it (via `provision` or by handing over an
 * already-built `ProvisioningData`), log in with their own `LoginStrategy`, and
 * then use `developerSession` / `selectTeam`.
 */
class SideloaderSession
{
    /// Resolved configuration directory (see `systemConfigurationPath`).
    string configurationPath;

    /// The provisioned authentication device. Available after provisioning.
    Device device;

    /// The provisioned ADI instance. Available after provisioning.
    ADI adi;

    /// The logged-in Apple developer account, or `null` until `ensureLoggedIn`.
    DeveloperSession developerSession;

    /**
     * Creates a session for the given configuration path, defaulting to
     * `systemConfigurationPath()` when none is supplied.
     */
    this(string configurationPath = systemConfigurationPath())
    {
        this.configurationPath = configurationPath;
    }

    /**
     * Creates a session from an already-built `ProvisioningData`, e.g. when the
     * frontend performs the (download + provisioning) bootstrap itself.
     */
    this(string configurationPath, ProvisioningData provisioningData)
    {
        this.configurationPath = configurationPath;
        this.device = provisioningData.device;
        this.adi = provisioningData.adi;
    }

    /**
     * Provisions `device` + `adi` from the configuration path if not already
     * done. Assumes the ADI native libraries are present; frontends that need to
     * download them first should do so before calling this (or pass a
     * pre-built `ProvisioningData` to the constructor).
     */
    ProvisioningData provision()
    {
        if (adi is null) {
            scope provisioningData = app.initializeADI(configurationPath);
            device = provisioningData.device;
            adi = provisioningData.adi;
        }
        return ProvisioningData(device, adi);
    }

    /**
     * Runs the supplied `LoginStrategy` (unless already logged in) and stores
     * the resulting `DeveloperSession`. Provisions on demand if needed.
     *
     * Returns the logged-in `DeveloperSession`, or `null` when login failed.
     */
    DeveloperSession ensureLoggedIn(scope LoginStrategy loginStrategy)
    {
        if (developerSession) return developerSession;
        provision();
        developerSession = loginStrategy(device, adi);
        return developerSession;
    }

    /**
     * Selects a developer team, replicating the historical per-command
     * behaviour: optionally filter by `teamId`, enforce that at least one team
     * matches, then take the first.
     *
     * Requires `developerSession` to be set (call `ensureLoggedIn` first).
     */
    DeveloperTeam selectTeam(string teamId = null)
    {
        assert(developerSession !is null, "selectTeam requires a logged-in session");
        auto teams = developerSession.listTeams().unwrap();

        if (teamId != null) {
            teams = teams.filter!((elem) => elem.teamId == teamId).array();
        }
        enforce(teams.length > 0, "No matching team found.");

        return teams[0];
    }

    /// Lists the logged-in account's developer teams.
    /// Requires `developerSession` to be set (call `ensureLoggedIn` first).
    DeveloperTeam[] listTeams()
    {
        assert(developerSession !is null, "listTeams requires a logged-in session");
        return developerSession.listTeams().unwrap();
    }

    /**
     * Resolves a developer team without any interactive prompting, returning the
     * unambiguous choice and reporting via `ambiguous` when a decision needs the
     * user.
     *
     * Resolution order:
     *   1. an explicit `teamId` (must match, else throws);
     *   2. a persisted `defaultTeamId` that still matches an available team;
     *   3. the single team, when the account has exactly one;
     *   4. otherwise leave `ambiguous` true and return the available teams in
     *      `teams` so a frontend can present a picker.
     *
     * This keeps all network/policy logic in the core; the interactive picker
     * (stdin for the CLI, a dialog for the GUIs) lives in the frontend.
     */
    DeveloperTeam resolveTeam(string teamId, string defaultTeamId, out bool ambiguous, out DeveloperTeam[] teams)
    {
        assert(developerSession !is null, "resolveTeam requires a logged-in session");
        ambiguous = false;
        teams = developerSession.listTeams().unwrap();

        if (teamId != null) {
            auto matching = teams.filter!((elem) => elem.teamId == teamId).array();
            enforce(matching.length > 0, "No matching team found.");
            return matching[0];
        }

        if (defaultTeamId.length) {
            auto matching = teams.filter!((elem) => elem.teamId == defaultTeamId).array();
            if (matching.length > 0)
                return matching[0];
        }

        enforce(teams.length > 0, "No matching team found.");
        if (teams.length == 1)
            return teams[0];

        ambiguous = true;
        return DeveloperTeam.init;
    }
}
