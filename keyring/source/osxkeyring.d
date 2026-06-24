module osxkeyring;

import keyring;

version (OSX):

import slf4d;

// ============================================================================
// CoreFoundation / Security.framework bindings
//
// Only the pieces we actually use for a generic-password item round-trip are
// declared here. The `kSec*` / `kCFTypeDictionary*` symbols are CFStringRef /
// CFType globals exported by the frameworks, so they are declared as
// `extern extern(C) const __gshared`.
// ============================================================================

private extern (C)
{

alias CFTypeRef = const(void)*;
alias CFStringRef = const(void)*;
alias CFDictionaryRef = const(void)*;
alias CFDataRef = const(void)*;
alias CFAllocatorRef = const(void)*;
alias CFIndex = long;
alias CFStringEncoding = uint;
alias OSStatus = int;
alias Boolean = ubyte;

enum CFStringEncoding kCFStringEncodingUTF8 = 0x08000100;

enum OSStatus errSecSuccess = 0;
enum OSStatus errSecItemNotFound = -25300;
enum OSStatus errSecDuplicateItem = -25299;

extern extern (C) const __gshared CFAllocatorRef kCFAllocatorDefault;

extern extern (C) const __gshared CFStringRef kSecClass;
extern extern (C) const __gshared CFStringRef kSecClassGenericPassword;
extern extern (C) const __gshared CFStringRef kSecAttrService;
extern extern (C) const __gshared CFStringRef kSecAttrAccount;
extern extern (C) const __gshared CFStringRef kSecValueData;
extern extern (C) const __gshared CFStringRef kSecReturnData;
extern extern (C) const __gshared CFStringRef kSecMatchLimit;
extern extern (C) const __gshared CFStringRef kSecMatchLimitOne;

extern extern (C) const __gshared CFBooleanRef_t kCFBooleanTrue;
alias CFBooleanRef_t = const(void)*;

// CoreFoundation
void CFRelease(CFTypeRef cf);
CFIndex CFDataGetLength(CFDataRef theData);
const(ubyte)* CFDataGetBytePtr(CFDataRef theData);
CFDataRef CFDataCreate(CFAllocatorRef allocator, const(ubyte)* bytes, CFIndex length);
CFStringRef CFStringCreateWithBytes(
    CFAllocatorRef alloc,
    const(ubyte)* bytes,
    CFIndex numBytes,
    CFStringEncoding encoding,
    Boolean isExternalRepresentation
);
CFDictionaryRef CFDictionaryCreate(
    CFAllocatorRef allocator,
    const(void)** keys,
    const(void)** values,
    CFIndex numValues,
    const(void)* keyCallBacks,
    const(void)* valueCallBacks
);

// Opaque callback-table structs; we only ever pass their address.
struct CFDictionaryKeyCallBacks { ubyte[56] _opaque; }
struct CFDictionaryValueCallBacks { ubyte[40] _opaque; }
extern extern (C) const __gshared CFDictionaryKeyCallBacks kCFTypeDictionaryKeyCallBacks;
extern extern (C) const __gshared CFDictionaryValueCallBacks kCFTypeDictionaryValueCallBacks;

// Security.framework
OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef* result);
OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef* result);
OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
OSStatus SecItemDelete(CFDictionaryRef query);

} // extern (C)

// ============================================================================

class OSXKeyring : KeyringImplementation
{
    // Service identifier shared with the other backends.
    private enum string service = "dev.dadoum.Sideloader";
    // Fixed account key — the keyring stores a single opaque blob.
    private enum string accountKey = "account";

    static OSXKeyring create()
    {
        return new OSXKeyring;
    }

    private static CFStringRef cfString(string str)
    {
        return CFStringCreateWithBytes(
            kCFAllocatorDefault,
            cast(const(ubyte)*) str.ptr,
            cast(CFIndex) str.length,
            kCFStringEncodingUTF8,
            0
        );
    }

    /// Build the {service, account} query dictionary common to every call.
    /// The caller owns the returned dictionary and the two CFStrings; release
    /// them via the returned cleanup helper.
    private static CFDictionaryRef baseQuery(out CFStringRef serviceRef, out CFStringRef accountRef)
    {
        serviceRef = cfString(service);
        accountRef = cfString(accountKey);

        const(void)*[3] keys = [kSecClass, kSecAttrService, kSecAttrAccount];
        const(void)*[3] values = [kSecClassGenericPassword, serviceRef, accountRef];

        return CFDictionaryCreate(
            kCFAllocatorDefault,
            keys.ptr,
            values.ptr,
            3,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );
    }

    void store(string account)
    {
        auto data = CFDataCreate(
            kCFAllocatorDefault,
            cast(const(ubyte)*) account.ptr,
            cast(CFIndex) account.length
        );
        scope (exit) CFRelease(data);

        CFStringRef serviceRef, accountRef;
        auto query = baseQuery(serviceRef, accountRef);
        scope (exit)
        {
            CFRelease(query);
            CFRelease(serviceRef);
            CFRelease(accountRef);
        }

        // Try to update an existing item first.
        const(void)*[1] updKeys = [kSecValueData];
        const(void)*[1] updValues = [data];
        auto updateDict = CFDictionaryCreate(
            kCFAllocatorDefault,
            updKeys.ptr,
            updValues.ptr,
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );
        scope (exit) CFRelease(updateDict);

        auto status = SecItemUpdate(query, updateDict);
        if (status == errSecSuccess)
            return;

        if (status != errSecItemNotFound)
        {
            getLogger.errorF!"Cannot update the account in the macOS Keychain (OSStatus %d)."(status);
            return;
        }

        // Item didn't exist — add it. Build {class, service, account, data}.
        const(void)*[4] addKeys = [kSecClass, kSecAttrService, kSecAttrAccount, kSecValueData];
        const(void)*[4] addValues = [kSecClassGenericPassword, serviceRef, accountRef, data];
        auto addDict = CFDictionaryCreate(
            kCFAllocatorDefault,
            addKeys.ptr,
            addValues.ptr,
            4,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );
        scope (exit) CFRelease(addDict);

        status = SecItemAdd(addDict, null);
        if (status != errSecSuccess)
            getLogger.errorF!"Cannot save the account in the macOS Keychain (OSStatus %d)."(status);
    }

    string lookup()
    {
        CFStringRef serviceRef, accountRef;

        // We need class + service + account + return-data + match-limit-one.
        serviceRef = cfString(service);
        accountRef = cfString(accountKey);
        scope (exit)
        {
            CFRelease(serviceRef);
            CFRelease(accountRef);
        }

        const(void)*[5] keys = [
            kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit
        ];
        const(void)*[5] values = [
            kSecClassGenericPassword, serviceRef, accountRef, kCFBooleanTrue, kSecMatchLimitOne
        ];
        auto query = CFDictionaryCreate(
            kCFAllocatorDefault,
            keys.ptr,
            values.ptr,
            5,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );
        scope (exit) CFRelease(query);

        CFTypeRef result;
        auto status = SecItemCopyMatching(query, &result);
        if (status == errSecItemNotFound)
            return null;
        if (status != errSecSuccess)
        {
            getLogger.errorF!"Cannot read the account from the macOS Keychain (OSStatus %d)."(status);
            return null;
        }

        // `result` is a CFDataRef we now own.
        CFDataRef data = cast(CFDataRef) result;
        scope (exit) CFRelease(data);

        auto length = CFDataGetLength(data);
        auto bytes = CFDataGetBytePtr(data);
        if (bytes is null || length <= 0)
            return null;

        // Copy out into GC memory so it outlives the CFData.
        return (cast(const(char)*) bytes)[0 .. cast(size_t) length].idup;
    }

    void clear()
    {
        CFStringRef serviceRef, accountRef;
        auto query = baseQuery(serviceRef, accountRef);
        scope (exit)
        {
            CFRelease(query);
            CFRelease(serviceRef);
            CFRelease(accountRef);
        }

        auto status = SecItemDelete(query);
        if (status != errSecSuccess && status != errSecItemNotFound)
            getLogger.warnF!"Cannot delete the account from the macOS Keychain (OSStatus %d)."(status);
    }
}
