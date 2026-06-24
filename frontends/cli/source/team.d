module team;

import std.algorithm;
import std.array;
import std.exception;
import std.stdio;
import std.sumtype;
import std.typecons;

import slf4d;
import slf4d.default_provider;

import argparse;

import server.developersession;

import cli_frontend;

@(Command("team").Description("Manage teams."))
struct TeamCommand
{
    int opCall()
    {
        return cmd.match!(
                (ListTeams cmd) => cmd(),
                (DefaultTeam cmd) => cmd()
        );
    }

    @SubCommands
    SumType!(ListTeams, DefaultTeam) cmd;
}

@(Command("list").Description("List teams (the default team is marked)."))
struct ListTeams
{
    mixin LoginCommand;

    int opCall()
    {
        import app.persistence : loadState;

        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        auto state = loadState(session.configurationPath);

        writeln("Teams:");
        auto teams = appleAccount.listTeams().unwrap();
        foreach (team; teams) {
            bool isDefault = state.defaultTeamId.length && team.teamId == state.defaultTeamId;
            writefln!" - `%s`, with ID `%s`.%s"(team.name, team.teamId, isDefault ? " (default)" : "");
        }

        return 0;
    }
}

@(Command("default").Description("Set the default team used when --team is not given."))
struct DefaultTeam
{
    mixin LoginCommand;

    @(PositionalArgument(0).Description("Team ID to set as default."))
    string teamId;

    int opCall()
    {
        import app.persistence : loadState, saveState;

        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        auto teams = appleAccount.listTeams().unwrap();
        auto matching = teams.filter!((t) => t.teamId == teamId).array();
        if (matching.length == 0) {
            log.error("No matching team found.");
            return 1;
        }

        auto state = loadState(session.configurationPath);
        state.defaultTeamId = teamId;
        saveState(session.configurationPath, state);

        writefln!"Default team set to `%s` (ID: %s)."(matching[0].name, teamId);
        return 0;
    }
}
