module account;

import std.algorithm;
import std.array;
import std.exception;
import std.format;
import std.stdio;
import std.sumtype;
import std.typecons;

import slf4d;
import slf4d.default_provider;

import argparse;

import keyring;

import server.developersession;

import cli_frontend;
import ui;

@(Command("login").Description("Log in to your Apple account."))
struct LoginAccountCommand
{
    mixin LoginCommand;

    @(NamedArgument("force", "relogin").Description("Clear any stored credentials first so you can re-authenticate with a different account."))
    bool force = false;

    int opCall()
    {
        auto log = getLogger();

        // An explicit `login` should always be interactive: prompt for the
        // Apple ID / password when nothing is stored, and run the 2FA flow.
        interactive = true;

        if (force) {
            log.debug_("Clearing stored credentials before logging in...");
            makeKeyring().clear();
        }

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        success(format!"You are now logged in as `%s`."(appleAccount.appleId));

        auto teams = appleAccount.listTeams().unwrap();
        if (teams.length) {
            header("Teams");
            Table table = Table([Column("Name"), Column("Team ID")]);
            foreach (team; teams) {
                table.add(paint(team.name, Theme.accent), team.teamId);
            }
            table.render();
        }

        return 0;
    }
}

@(Command("logout").Description("Log out and clear stored credentials (all accounts, or one with --account)."))
struct LogoutCommand
{
    @(NamedArgument("account").Description("Apple ID of a single stored account to remove (default: clear all)."))
    string account = null;

    int opCall()
    {
        import app.persistence : loadState, saveState;

        auto log = getLogger();

        auto kr = makeKeyring();
        string blob = kr.lookup();

        if (blob.length == 0) {
            log.info("You were not logged in; no stored credentials to clear.");
            return 0;
        }

        // Clearing a single account (network-free): rewrite the blob without it.
        if (account.length) {
            StoredAccount[] accounts;
            string defaultAccount;
            if (!deserializeAccounts(blob, accounts, defaultAccount)) {
                log.warn("Stored credentials could not be parsed; clearing everything.");
                kr.clear();
                return 0;
            }

            if (!accounts.canFind!((a) => a.appleId == account)) {
                log.errorF!"No stored account matches `%s`."(account);
                return 1;
            }

            accounts = removeAccount(accounts, account);

            string configurationPath = systemConfigurationPath();
            auto state = loadState(configurationPath);

            if (accounts.length == 0) {
                kr.clear();
                state.defaultAccount = "";
            } else {
                if (defaultAccount == account)
                    defaultAccount = accounts[0].appleId;
                kr.store(serializeAccounts(accounts, defaultAccount));
                if (state.defaultAccount == account)
                    state.defaultAccount = defaultAccount;
            }
            saveState(configurationPath, state);

            log.infoF!"Removed stored credentials for `%s`."(account);
            return 0;
        }

        // Default: clear everything.
        kr.clear();
        auto state = loadState(systemConfigurationPath());
        if (state.defaultAccount.length) {
            state.defaultAccount = "";
            saveState(systemConfigurationPath(), state);
        }
        log.info("Logged out. Stored credentials have been cleared.");

        return 0;
    }
}
