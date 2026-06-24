module team;

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

import std.json : JSONValue;

import server.developersession;

import cli_frontend;
import jsonout;
import ui;

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

        auto teams = appleAccount.listTeams().unwrap();

        if (g_jsonOutput) {
            JSONValue[] arr;
            foreach (team; teams) {
                bool isDefault = state.defaultTeamId.length && team.teamId == state.defaultTeamId;
                arr ~= JSONValue([
                    "teamId":  JSONValue(team.teamId),
                    "name":    JSONValue(team.name),
                    "default": JSONValue(isDefault),
                ]);
            }
            printJson(JSONValue(["teams": JSONValue(arr)]));
            return 0;
        }

        header("Teams");
        auto table = Table([Column("NAME"), Column("ID"), Column("")]);
        foreach (team; teams) {
            bool isDefault = state.defaultTeamId.length && team.teamId == state.defaultTeamId;
            table.add(
                paint(team.name, Theme.accent),
                paint(team.teamId, Theme.muted),
                isDefault ? dot("default", Theme.ok) : "");
        }
        table.render();

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

        success(format!"Default team set to %s (ID: %s)."(paint(matching[0].name, Theme.accent), paint(teamId, Theme.muted)));
        return 0;
    }
}
