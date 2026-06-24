module device;

import std.algorithm;
import std.array;
import std.exception;
import std.format;
import std.stdio;
import std.sumtype;
import std.typecons;

import slf4d;
import slf4d.default_provider;

import botan.cert.x509.pkcs10;
import botan.filters.data_src;

import argparse;

import std.json : JSONValue;

import server.developersession;

import cli_frontend;
import jsonout;
import ui;

@(Command("device").Description("Manage registered devices."))
struct DeviceCommand
{
    int opCall()
    {
        return cmd.match!(
                (ListDevices cmd) => cmd(),
                (AddDevice cmd) => cmd(),
                (DeleteDevice cmd) => cmd()
        );
    }

    @SubCommands
    SumType!(ListDevices, AddDevice, DeleteDevice) cmd;
}

@(Command("list").Description("List registered devices."))
struct ListDevices
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

        auto devices = appleAccount.listDevices!iOS(team).unwrap();

        if (g_jsonOutput) {
            JSONValue[] arr;
            foreach (device; devices) {
                arr ~= JSONValue([
                    "name": JSONValue(device.name),
                    "udid": JSONValue(device.deviceNumber),
                    "id":   JSONValue(device.deviceId),
                ]);
            }
            printJson(JSONValue(["devices": JSONValue(arr)]));
            return 0;
        }

        note(format!"You have %d device%s registered."(devices.length, devices.length == 1 ? "" : "s"));

        header("Currently registered devices");
        Table table = Table([Column("Name"), Column("UDID"), Column("Identifier")]);
        foreach (device; devices) {
            table.add(paint(device.name, Theme.accent), device.deviceNumber, device.deviceId);
        }
        table.render();

        return 0;
    }
}

@(Command("add").Description("Register device."))
struct AddDevice
{
    mixin LoginCommand;

    @(NamedArgument("team").Description("Team ID"))
    string teamId = null;

    @(PositionalArgument(0).Description("Device name"))
    string name = void;

    @(PositionalArgument(1).Description("Device UDID"))
    string udid = void;

    int opCall()
    {
        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        auto team = selectTeamInteractive(session, teamId);

        auto devices = appleAccount.addDevice!iOS(team, name, udid).unwrap();
        log.info("Success!");

        return 0;
    }
}

@(Command("delete").Description("Unregister device."))
struct DeleteDevice
{
    mixin LoginCommand;

    @(NamedArgument("team").Description("Team ID"))
    string teamId = null;

    @(PositionalArgument(0).Description("Apple device's identifier (not UDID, check device list)."))
    string deviceId = void;

    int opCall()
    {
        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        auto team = selectTeamInteractive(session, teamId);

        auto devices = appleAccount.deleteDevice!iOS(team, deviceId).unwrap();
        log.info("Success!");

        return 0;
    }
}

