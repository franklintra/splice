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
                (ListTeams cmd) => cmd()
        );
    }

    @SubCommands
    SumType!(ListTeams) cmd;
}

@(Command("list").Description("List teams."))
struct ListTeams
{
    mixin LoginCommand;

    int opCall()
    {
        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        writeln("Teams:");
        auto teams = appleAccount.listTeams().unwrap();
        foreach (team; teams) {
            writefln!" - `%s`, with ID `%s`."(team.name, team.teamId);
        }

        return 0;
    }
}
