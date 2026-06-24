module account;

import std.array;
import std.exception;
import std.stdio;
import std.sumtype;
import std.typecons;

import slf4d;
import slf4d.default_provider;

import argparse;

import keyring;

import server.developersession;

import cli_frontend;

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
            log.info("Clearing stored credentials before logging in...");
            makeKeyring().clear();
        }

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        writefln!"You are now logged in as `%s`."(appleAccount.appleId);

        auto teams = appleAccount.listTeams().unwrap();
        if (teams.length) {
            writeln("Teams:");
            foreach (team; teams) {
                writefln!" - `%s`, with ID `%s`."(team.name, team.teamId);
            }
        }

        return 0;
    }
}

@(Command("logout").Description("Log out and clear stored credentials."))
struct LogoutCommand
{
    int opCall()
    {
        auto log = getLogger();

        auto kr = makeKeyring();
        bool hadCredentials = kr.lookup().length != 0;
        kr.clear();

        if (hadCredentials) {
            log.info("Logged out. Stored credentials have been cleared.");
        } else {
            log.info("You were not logged in; no stored credentials to clear.");
        }

        return 0;
    }
}
