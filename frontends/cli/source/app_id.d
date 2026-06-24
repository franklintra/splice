module app_id;

import std.algorithm;
import std.array;
import std.exception;
import std.format;
import file = std.file;
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

@(Command("app-id").Description("Manage App IDs."))
struct AppIdCommand
{
    int opCall()
    {
        return cmd.match!(
            (ListAppIds cmd) => cmd(),
            (AddAppId cmd) => cmd(),
            (DeleteAppId cmd) => cmd(),
            (DownloadProvision cmd) => cmd()
        );
    }

    @SubCommands
    SumType!(ListAppIds, AddAppId, DeleteAppId, DownloadProvision) cmd;
}

@(Command("list").Description("List App IDs."))
struct ListAppIds
{
    mixin LoginCommand;

    @(NamedArgument("team").Description("Team ID"))
    string teamId = null;

    int opCall()
    {
        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        auto team = selectTeamInteractive(session, teamId);

        auto appIds = appleAccount.listAppIds!iOS(team).unwrap();

        if (g_jsonOutput) {
            import app.persistence : appIdResetDate;

            JSONValue[] arr;
            foreach (appId; appIds.appIds) {
                arr ~= JSONValue([
                    "identifier":      JSONValue(appId.identifier),
                    "name":            JSONValue(appId.name),
                    "expirationDate":  JSONValue(appId.expirationDate.toISOExtString()),
                ]);
            }

            JSONValue[string] obj = [
                "maxQuantity":       JSONValue(appIds.maxQuantity),
                "availableQuantity": JSONValue(appIds.availableQuantity),
                "appIds":            JSONValue(arr),
            ];
            if (appIds.appIds.length) {
                auto resetDate = appIdResetDate(appIds.appIds.map!((appId) => appId.expirationDate).array());
                obj["nextSlotFreesUp"] = JSONValue(resetDate.toISOExtString());
            }
            printJson(JSONValue(obj));
            return 0;
        }

        note(format!"You have %d App ID%s available out of the %d you have at your disposal."(appIds.availableQuantity, appIds.availableQuantity == 1 ? "" : "s", appIds.maxQuantity));

        // Surface when the next App ID slot frees up (the earliest expiration
        // among the existing App IDs). Especially relevant when the quota is
        // exhausted, but always informative.
        if (appIds.appIds.length) {
            import app.persistence : appIdResetDate;
            auto resetDate = appIdResetDate(appIds.appIds.map!((appId) => appId.expirationDate).array());
            if (appIds.availableQuantity == 0) {
                warning(format!"Quota exhausted. The next App ID slot frees up on %s."(resetDate));
            } else {
                note(format!"The next App ID slot frees up on %s."(resetDate));
            }
        }

        header("Currently registered App IDs");
        Table table = Table([Column("Identifier"), Column("App"), Column("Expires")]);
        foreach (appId; appIds.appIds) {
            table.add(paint(appId.identifier, Theme.accent), appId.name, format!"%s"(appId.expirationDate));
        }
        table.render();

        return 0;
    }
}

@(Command("add").Description("Add a new App ID."))
struct AddAppId
{
    mixin LoginCommand;

    @(NamedArgument("team").Description("Team ID"))
    string teamId = null;

    @(PositionalArgument(0).Description("app name"))
    string name;

    @(PositionalArgument(1).Description("app identifier"))
    string identifier;

    int opCall()
    {
        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        auto team = selectTeamInteractive(session, teamId);

        appleAccount.addAppId!iOS(team, identifier, name).unwrap();

        log.info("Done.");

        return 0;
    }
}

@(Command("delete").Description("Delete an App ID (it won't let you create more App IDs though)."))
struct DeleteAppId
{
    mixin LoginCommand;

    @(NamedArgument("team").Description("Team ID"))
    string teamId = null;

    @(PositionalArgument(0).Description("app identifier"))
    string identifier;

    int opCall()
    {
        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        auto team = selectTeamInteractive(session, teamId);

        auto appIds = appleAccount.listAppIds!iOS(team).unwrap().appIds;
        auto matchingAppIds = appIds.filter!((appId) => appId.identifier == identifier).array();

        if (matchingAppIds.length == 0) {
            log.error("No matching App ID found.");
            return 1;
        }

        enforce(matchingAppIds.length == 1, "Multiple App ID matched?? To prevent any issue, ignoring the request.");
        appleAccount.deleteAppId!iOS(team, matchingAppIds[0]).unwrap();

        log.info("Done.");

        return 0;
    }
}

@(Command("download").Description("Download the provisioning profile for an App ID"))
struct DownloadProvision
{
    mixin LoginCommand;

    @(NamedArgument("team").Description("Team ID"))
    string teamId = null;

    @(NamedArgument("o", "output").Description("Output file").Required())
    string outputPath;

    @(PositionalArgument(0).Description("app identifier"))
    string identifier;

    int opCall()
    {
        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        // NOTE: this command historically used the message "No matching team
        // found" (no trailing period), so it keeps the inline filter rather than
        // session.selectTeam (which standardises on "No matching team found.").
        auto teams = appleAccount.listTeams().unwrap();

        string teamId = this.teamId;
        if (teamId != null) {
            teams = teams.filter!((elem) => elem.teamId == teamId).array();
        }
        enforce(teams.length > 0, "No matching team found");

        auto team = teams[0];

        auto appIds = appleAccount.listAppIds!iOS(team).unwrap().appIds;
        auto matchingAppIds = appIds.filter!((appId) => appId.identifier == identifier).array();

        if (matchingAppIds.length == 0) {
            log.error("No matching App ID found.");
            return 1;
        }

        enforce(matchingAppIds.length == 1, "Multiple App ID matched?? To prevent any issue, ignoring the request.");

        log.debug_("Downloading the profile...");
        file.write(outputPath, appleAccount.downloadTeamProvisioningProfile!iOS(team, matchingAppIds[0]).unwrap().encodedProfile);
        log.info("Done.");

        return 0;
    }
}

