module keyring;

import libsecretkeyring;
import osxkeyring;
import windowskeyring;
import memorykeyring;

interface KeyringImplementation
{
    void store(string account);
    string lookup();
    void clear();
}

struct Keyring
{
    KeyringImplementation backend;

    void store(string account)
    {
        if (backend)
            backend.store(account);
    }

    string lookup()
    {
        if (backend)
            return backend.lookup();
        return null;
    }

    void clear()
    {
        if (backend)
            backend.clear();
    }
}

Keyring makeKeyring()
{
    version (Windows)
    {
        if (auto keyring = WindowsKeyring.create())
        {
            return Keyring(keyring);
        }
    }
    else version (OSX)
    {
        if (auto keyring = OSXKeyring.create())
        {
            return Keyring(keyring);
        }
    }
    else version (LibSecret)
    {
        if (auto keyring = LibSecretKeyring.create())
        {
            return Keyring(keyring);
        }
    }

    return Keyring(new MemoryKeyring());
}

/// Serialize Apple credentials into the opaque blob stored by the keyring.
/// The blob is a small JSON object so a future login can re-authenticate
/// silently. This intentionally only carries `appleId` + `password`; richer
/// token/session storage is out of scope here (#6).
string serializeCredentials(string appleId, string password)
{
    import std.json;
    JSONValue value = [
        "appleId": JSONValue(appleId),
        "password": JSONValue(password),
    ];
    return value.toJSON();
}

/// Parse a blob produced by `serializeCredentials`. Returns `false` if the
/// blob is empty or malformed; `appleId`/`password` are set on success.
///
/// Backward-compatible: it also accepts the multi-account blob produced by
/// `serializeAccounts`, returning the credentials for the default account (or
/// the first stored account when no default is recorded).
bool deserializeCredentials(string blob, out string appleId, out string password)
{
    import std.json;

    if (blob.length == 0)
        return false;

    try
    {
        JSONValue value = parseJSON(blob);
        if (value.type != JSONType.object)
            return false;

        // Multi-account blob (has an "accounts" array): pick the default.
        if ("accounts" in value.object)
        {
            StoredAccount[] accounts;
            string defaultAccount;
            if (!deserializeAccounts(blob, accounts, defaultAccount) || accounts.length == 0)
                return false;
            auto chosen = pickAccount(accounts, defaultAccount);
            appleId = chosen.appleId;
            password = chosen.password;
            return true;
        }

        // Legacy single-credential blob.
        auto idPtr = "appleId" in value.object;
        auto pwPtr = "password" in value.object;
        if (idPtr is null || pwPtr is null)
            return false;
        if (idPtr.type != JSONType.string || pwPtr.type != JSONType.string)
            return false;

        appleId = idPtr.str;
        password = pwPtr.str;
        return true;
    }
    catch (JSONException)
    {
        return false;
    }
}

/// One stored Apple account (credentials kept in the keyring blob).
struct StoredAccount
{
    string appleId;
    string password;
}

/// Serialize a set of Apple accounts plus a chosen default into the opaque
/// keyring blob. The format is:
/// `{ "accounts": [ {"appleId": ..., "password": ...}, ... ], "defaultAccount": ... }`.
string serializeAccounts(StoredAccount[] accounts, string defaultAccount)
{
    import std.json;
    JSONValue[] arr;
    foreach (acc; accounts)
    {
        arr ~= JSONValue([
            "appleId": JSONValue(acc.appleId),
            "password": JSONValue(acc.password),
        ]);
    }
    JSONValue value = [
        "accounts": JSONValue(arr),
        "defaultAccount": JSONValue(defaultAccount),
    ];
    return value.toJSON();
}

/// Parse a blob into the stored accounts and default. Returns `false` when the
/// blob is empty or malformed.
///
/// Backward-compatible: a legacy single-credential blob produced by
/// `serializeCredentials` is migrated transparently into a one-element account
/// list (its `appleId` becoming the default).
bool deserializeAccounts(string blob, out StoredAccount[] accounts, out string defaultAccount)
{
    import std.json;

    if (blob.length == 0)
        return false;

    try
    {
        JSONValue value = parseJSON(blob);
        if (value.type != JSONType.object)
            return false;

        // Multi-account blob.
        if (auto accPtr = "accounts" in value.object)
        {
            if (accPtr.type != JSONType.array)
                return false;
            foreach (entry; accPtr.array)
            {
                if (entry.type != JSONType.object)
                    continue;
                auto idPtr = "appleId" in entry.object;
                auto pwPtr = "password" in entry.object;
                if (idPtr is null || pwPtr is null)
                    continue;
                if (idPtr.type != JSONType.string || pwPtr.type != JSONType.string)
                    continue;
                accounts ~= StoredAccount(idPtr.str, pwPtr.str);
            }
            if (auto dfltPtr = "defaultAccount" in value.object)
            {
                if (dfltPtr.type == JSONType.string)
                    defaultAccount = dfltPtr.str;
            }
            return accounts.length != 0;
        }

        // Legacy single-credential blob -> migrate to a one-element list.
        string id, pw;
        if (deserializeCredentials(blob, id, pw))
        {
            accounts = [StoredAccount(id, pw)];
            defaultAccount = id;
            return true;
        }
        return false;
    }
    catch (JSONException)
    {
        return false;
    }
}

/// Returns the account matching `defaultAccount` (by Apple ID), or the first
/// account when no match is found. `accounts` must be non-empty.
StoredAccount pickAccount(StoredAccount[] accounts, string defaultAccount)
{
    assert(accounts.length != 0, "pickAccount requires at least one account");
    if (defaultAccount.length)
    {
        foreach (acc; accounts)
        {
            if (acc.appleId == defaultAccount)
                return acc;
        }
    }
    return accounts[0];
}

/// Inserts or updates `account` in `accounts` (keyed by Apple ID), returning the
/// updated list. Existing passwords are replaced on a match.
StoredAccount[] upsertAccount(StoredAccount[] accounts, StoredAccount account)
{
    foreach (ref acc; accounts)
    {
        if (acc.appleId == account.appleId)
        {
            acc.password = account.password;
            return accounts;
        }
    }
    return accounts ~ account;
}

/// Removes the account with the given Apple ID, returning the filtered list.
StoredAccount[] removeAccount(StoredAccount[] accounts, string appleId)
{
    StoredAccount[] kept;
    foreach (acc; accounts)
    {
        if (acc.appleId != appleId)
            kept ~= acc;
    }
    return kept;
}

unittest
{
    // Multi-account round-trip.
    StoredAccount[] accounts = [
        StoredAccount("alice@example.com", "pw1"),
        StoredAccount("bob@example.com", "pw2"),
    ];
    auto blob = serializeAccounts(accounts, "bob@example.com");

    StoredAccount[] parsed;
    string dflt;
    assert(deserializeAccounts(blob, parsed, dflt));
    assert(parsed.length == 2);
    assert(dflt == "bob@example.com");
    assert(parsed[0].appleId == "alice@example.com" && parsed[0].password == "pw1");

    // pickAccount honours the default, falls back to the first.
    assert(pickAccount(parsed, "bob@example.com").appleId == "bob@example.com");
    assert(pickAccount(parsed, "nope@example.com").appleId == "alice@example.com");
    assert(pickAccount(parsed, "").appleId == "alice@example.com");

    // deserializeCredentials picks the default account from a multi-account blob.
    string id, pw;
    assert(deserializeCredentials(blob, id, pw));
    assert(id == "bob@example.com" && pw == "pw2");

    // upsert / remove.
    auto updated = upsertAccount(accounts, StoredAccount("alice@example.com", "newpw"));
    assert(updated.length == 2);
    assert(pickAccount(updated, "alice@example.com").password == "newpw");
    auto added = upsertAccount(updated, StoredAccount("carol@example.com", "pw3"));
    assert(added.length == 3);
    auto removed = removeAccount(added, "bob@example.com");
    assert(removed.length == 2);
    assert(removeAccount(removed, "alice@example.com").length == 1);
}

unittest
{
    // Legacy single-credential blob migrates into a one-element account list.
    auto legacy = serializeCredentials("legacy@example.com", "legacypw");

    StoredAccount[] parsed;
    string dflt;
    assert(deserializeAccounts(legacy, parsed, dflt));
    assert(parsed.length == 1);
    assert(parsed[0].appleId == "legacy@example.com");
    assert(parsed[0].password == "legacypw");
    assert(dflt == "legacy@example.com");

    // And the legacy reader still works on the legacy blob.
    string id, pw;
    assert(deserializeCredentials(legacy, id, pw));
    assert(id == "legacy@example.com" && pw == "legacypw");

    // Empty / malformed blobs are rejected.
    StoredAccount[] none;
    string nd;
    assert(!deserializeAccounts("", none, nd));
    assert(!deserializeAccounts("not json", none, nd));
}
