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
