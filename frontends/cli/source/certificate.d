module certificate;

import std.algorithm;
import std.array;
import std.exception;
import std.format;
import std.json : JSONValue;
import std.stdio;
import std.sumtype;
import std.typecons;

import slf4d;
import slf4d.default_provider;

import botan.cert.x509.pkcs10;
import botan.filters.data_src;

import argparse;

import server.developersession;

import cli_frontend;
import jsonout;
import ui;

@(Command("cert").Description("Manage certificates."))
struct CertificateCommand
{
    int opCall()
    {
        return cmd.match!(
                (ListCerts cmd) => cmd(),
                (SubmitCert cmd) => cmd(),
                (RevokeCert cmd) => cmd()
        );
    }

    @SubCommands
    SumType!(ListCerts, SubmitCert, RevokeCert) cmd;
}

@(Command("list").Description("List certificates."))
struct ListCerts
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

        auto certificates = appleAccount.listAllDevelopmentCerts!iOS(team).unwrap();

        if (g_jsonOutput) {
            JSONValue[] arr;
            foreach (certificate; certificates) {
                arr ~= JSONValue([
                    "name":         JSONValue(certificate.name),
                    "serialNumber": JSONValue(certificate.serialNumber),
                    "machineName":  JSONValue(certificate.machineName),
                ]);
            }
            printJson(JSONValue(["certificates": JSONValue(arr)]));
            return 0;
        }

        note(format!"You have %d certificate%s registered."(certificates.length, certificates.length == 1 ? "" : "s"));

        header("Currently registered certificates");
        Table table = Table([Column("Name"), Column("Serial number"), Column("Machine")]);
        foreach (certificate; certificates) {
            table.add(paint(certificate.name, Theme.accent), certificate.serialNumber, certificate.machineName);
        }
        table.render();

        return 0;
    }
}

// @(Command("register").Description("Register a certificate for Splice if we don't already have one."))

@(Command("submit").Description("Submit a certificate signing request to Apple servers."))
struct SubmitCert
{
    mixin LoginCommand;

    @(NamedArgument("team").Description("Team ID"))
    string teamId = null;

    @(PositionalArgument(0).Description("CSR file"))
    string certificatePath;

    int opCall()
    {
        ubyte[] certificateData = readFile(certificatePath);
        auto cert = PKCS10Request(DataSourceMemory(certificateData.ptr, certificateData.length));

        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        auto team = selectTeamInteractive(session, teamId);

        appleAccount.submitDevelopmentCSR!iOS(team, cast(string) cert.PEM_encode()).unwrap();

        return 0;
    }
}

@(Command("revoke").Description("Revoke a certificate."))
struct RevokeCert
{
    mixin LoginCommand;

    @(NamedArgument("team").Description("Team ID"))
    string teamId = null;

    @(PositionalArgument(0).Description("certificate serial number"))
    string serialNumber;

    int opCall()
    {
        auto log = getLogger();

        auto session = makeSession();
        if (!session) {
            return 1;
        }
        auto appleAccount = session.developerSession;

        auto team = selectTeamInteractive(session, teamId);

        auto certificates = appleAccount.listAllDevelopmentCerts!iOS(team).unwrap();
        auto matchingCerts = certificates.filter!((cert) => cert.serialNumber == serialNumber).array();

        if (matchingCerts.length == 0) {
            log.error("No matching certificate found.");
            return 1;
        }

        enforce(matchingCerts.length == 1, "Multiple certificate matched?? To prevent any issue, ignoring the request.");

        appleAccount.revokeDevelopmentCert!iOS(team, matchingCerts[0]).unwrap();

        return 0;
    }
}
