module imobiledevice;

public import imobiledevice.afc;
public import imobiledevice.debugserver;
public import imobiledevice.house_arrest;
public import imobiledevice.installation_proxy;
public import imobiledevice.libimobiledevice;
public import imobiledevice.lockdown;
public import imobiledevice.misagent;

import core.memory;

import std.array;
import std.algorithm.iteration;
import std.format;
import std.string;
import std.traits;

import plist;
import plist.c;

class iMobileDeviceException(T): Exception {
    T underlyingError;

    this(T error, string file = __FILE__, int line = __LINE__) {
        super(format!"error %s"(error), file, line);
        underlyingError = error;
    }
}

void assertSuccess(T)(T err) {
    if (err != 0)
        throw new iMobileDeviceException!T(err);
}

/// Thrown when the device reports an error while uninstalling an application via
/// the installation proxy (see `InstallationProxyClient.uninstall`).
class AppUninstallationException: Exception {
    this(string error, string description, long detail, string file = __FILE__, int line = __LINE__) {
        super(format!"Cannot uninstall the application from the device! %s: %s (%d)"(error, description, detail), file, line);
    }
}

/// Ensures a C constructor that reported success actually produced a usable
/// handle. Some libimobiledevice entry points can return success while leaving
/// the out-handle null; proceeding with a null handle leads to a later crash, so
/// fail fast with a clear exception instead.
void assertHandle(T)(T handle, string what = "object") {
    if (!handle)
        throw new Exception(format!"Failed to create %s: the underlying handle is null."(what));
}

enum iDeviceEventType
{
    add = 1,
    remove = 2,
    paired = 3
}

enum iDeviceConnectionType
{
    usbmuxd = 1,
    network = 2
}

struct iDeviceEvent {
    iDeviceEventType event; /**< The event type. */
    string udid; /**< The device unique id. */
    iDeviceConnectionType connType; /**< The connection type. */
}

struct iDeviceInfo {
    string udid;
    iDeviceConnectionType connType;
}

/**
 * A device collapsed across transports.
 *
 * `iDevice.deviceList()` (via `idevice_get_device_list_extended`) returns ONE
 * `iDeviceInfo` per (udid, connection-type) pair, so a device that is reachable
 * both over USB and over the network (Wi-Fi sync, issue #13) appears TWICE with
 * the same `udid`. `dedupDevices` folds those into a single logical
 * `iDeviceEntry` that remembers which transports the device is reachable on, so
 * callers see one device and don't double-act on it.
 */
struct iDeviceEntry {
    string udid;
    bool overUsb;     /// reachable via usbmuxd (USB)
    bool overNetwork; /// reachable via the network (Wi-Fi)

    /// Whether the device is reachable over the network at all.
    bool reachableOverNetwork() const => overNetwork;

    /// A short, user-facing transport label: "USB", "Wi-Fi" or "USB+Wi-Fi".
    string transportLabel() const {
        if (overUsb && overNetwork)
            return "USB+Wi-Fi";
        if (overNetwork)
            return "Wi-Fi";
        return "USB";
    }
}

/**
 * How a command would like to pick a transport when a device is reachable both
 * over USB and over the network.
 *
 * The default is `preferUsb` because a cabled connection is more reliable; a
 * command can opt into `preferNetwork` (e.g. via a `--wifi` flag) to target the
 * Wi-Fi transport when both are available.
 */
enum TransportPreference {
    preferUsb,
    preferNetwork,
}

/**
 * Folds a raw `iDeviceInfo[]` (which lists a device once per transport) into one
 * `iDeviceEntry` per udid, recording whether each device is reachable over USB
 * and/or the network. Order is preserved by first appearance. PURE — no device
 * access — so it is unit-testable with synthetic lists.
 */
iDeviceEntry[] dedupDevices(const(iDeviceInfo)[] infos) {
    iDeviceEntry[] result;
    size_t[string] indexByUdid;

    foreach (info; infos) {
        size_t idx;
        if (auto existing = info.udid in indexByUdid) {
            idx = *existing;
        } else {
            idx = result.length;
            indexByUdid[info.udid] = idx;
            result ~= iDeviceEntry(info.udid);
        }
        final switch (info.connType) {
            case iDeviceConnectionType.usbmuxd:
                result[idx].overUsb = true;
                break;
            case iDeviceConnectionType.network:
                result[idx].overNetwork = true;
                break;
        }
    }

    return result;
}

/// Outcome category of `selectDevice`.
enum DeviceSelectionStatus {
    selected,   /// exactly one device was chosen (`device`/`connType` are valid)
    noDevice,   /// no (matching) device is connected
    ambiguous,  /// several devices are connected and no `--udid` was given
}

/// Result of resolving which connected device a command should act on.
struct DeviceSelection {
    DeviceSelectionStatus status;
    iDeviceEntry device;          /// valid only when `status == selected`
    iDeviceConnectionType connType; /// the transport chosen for `device`
}

/**
 * Resolves which deduped device a command should act on, PURELY over a list of
 * `iDeviceEntry`.
 *
 *  - `requestedUdid` (optional): when non-empty, only a device with that exact
 *    udid is eligible; a miss yields `noDevice`.
 *  - `preference`: when the chosen device is reachable both ways, picks the USB
 *    or the network transport accordingly.
 *
 * Returns `selected` with the chosen entry and the concrete transport, or
 * `noDevice` / `ambiguous` so the caller can print the right guidance. Pure and
 * offline, hence unit-testable.
 */
DeviceSelection selectDevice(const(iDeviceEntry)[] devices, string requestedUdid,
        TransportPreference preference = TransportPreference.preferUsb) {
    iDeviceConnectionType pickTransport(const ref iDeviceEntry d) {
        if (d.overUsb && d.overNetwork)
            return preference == TransportPreference.preferNetwork
                ? iDeviceConnectionType.network
                : iDeviceConnectionType.usbmuxd;
        return d.overNetwork ? iDeviceConnectionType.network : iDeviceConnectionType.usbmuxd;
    }

    if (requestedUdid.length) {
        foreach (d; devices) {
            if (d.udid == requestedUdid)
                return DeviceSelection(DeviceSelectionStatus.selected, d, pickTransport(d));
        }
        return DeviceSelection(DeviceSelectionStatus.noDevice);
    }

    if (devices.length == 0)
        return DeviceSelection(DeviceSelectionStatus.noDevice);

    if (devices.length > 1)
        return DeviceSelection(DeviceSelectionStatus.ambiguous);

    return DeviceSelection(DeviceSelectionStatus.selected, devices[0], pickTransport(devices[0]));
}

unittest {
    alias Info = iDeviceInfo;
    enum usb = iDeviceConnectionType.usbmuxd;
    enum net = iDeviceConnectionType.network;

    // --- dedupDevices ---

    // USB-only.
    {
        auto d = dedupDevices([Info("A", usb)]);
        assert(d.length == 1);
        assert(d[0].udid == "A" && d[0].overUsb && !d[0].overNetwork);
        assert(d[0].transportLabel == "USB");
    }

    // Wi-Fi-only.
    {
        auto d = dedupDevices([Info("A", net)]);
        assert(d.length == 1);
        assert(!d[0].overUsb && d[0].overNetwork);
        assert(d[0].transportLabel == "Wi-Fi");
    }

    // Same udid on both transports collapses into ONE entry.
    {
        auto d = dedupDevices([Info("A", usb), Info("A", net)]);
        assert(d.length == 1);
        assert(d[0].overUsb && d[0].overNetwork);
        assert(d[0].transportLabel == "USB+Wi-Fi");
    }

    // Order/independence: network seen first then USB still folds to one.
    {
        auto d = dedupDevices([Info("A", net), Info("A", usb)]);
        assert(d.length == 1 && d[0].overUsb && d[0].overNetwork);
    }

    // Distinct udids stay separate, first-appearance order preserved.
    {
        auto d = dedupDevices([Info("B", usb), Info("A", net), Info("A", usb)]);
        assert(d.length == 2);
        assert(d[0].udid == "B");
        assert(d[1].udid == "A" && d[1].overUsb && d[1].overNetwork);
    }

    // Empty -> empty.
    assert(dedupDevices([]).length == 0);

    // --- selectDevice ---

    // No devices -> noDevice.
    {
        auto s = selectDevice([], "");
        assert(s.status == DeviceSelectionStatus.noDevice);
    }

    // Exactly one (USB) -> selected silently over USB (no regression).
    {
        auto d = dedupDevices([Info("A", usb)]);
        auto s = selectDevice(d, "");
        assert(s.status == DeviceSelectionStatus.selected);
        assert(s.device.udid == "A" && s.connType == usb);
    }

    // Exactly one (Wi-Fi-only) -> selected over the network.
    {
        auto d = dedupDevices([Info("A", net)]);
        auto s = selectDevice(d, "");
        assert(s.status == DeviceSelectionStatus.selected && s.connType == net);
    }

    // Multiple distinct -> ambiguous (without a udid).
    {
        auto d = dedupDevices([Info("A", usb), Info("B", usb)]);
        auto s = selectDevice(d, "");
        assert(s.status == DeviceSelectionStatus.ambiguous);
    }

    // A device on BOTH transports is ONE device, so still selected silently.
    {
        auto d = dedupDevices([Info("A", usb), Info("A", net)]);
        auto s = selectDevice(d, "");
        assert(s.status == DeviceSelectionStatus.selected);
        // Default prefers USB when both are available.
        assert(s.connType == usb);
    }

    // --wifi / preferNetwork picks the network transport when both available.
    {
        auto d = dedupDevices([Info("A", usb), Info("A", net)]);
        auto s = selectDevice(d, "", TransportPreference.preferNetwork);
        assert(s.status == DeviceSelectionStatus.selected && s.connType == net);
    }

    // preferNetwork on a USB-only device still selects USB (it's all there is).
    {
        auto d = dedupDevices([Info("A", usb)]);
        auto s = selectDevice(d, "", TransportPreference.preferNetwork);
        assert(s.status == DeviceSelectionStatus.selected && s.connType == usb);
    }

    // udid filter hit -> selected, even amid several devices.
    {
        auto d = dedupDevices([Info("A", usb), Info("B", net)]);
        auto s = selectDevice(d, "B");
        assert(s.status == DeviceSelectionStatus.selected);
        assert(s.device.udid == "B" && s.connType == net);
    }

    // udid filter miss -> noDevice.
    {
        auto d = dedupDevices([Info("A", usb)]);
        auto s = selectDevice(d, "ZZZ");
        assert(s.status == DeviceSelectionStatus.noDevice);
    }
}

public class iDevice {
    alias iDeviceEventCallback = void delegate(ref const(iDeviceEvent) event);

    idevice_t handle;

    public static void subscribeEvent(iDeviceEventCallback callback) {
        struct UserData {
            iDeviceEventCallback callback;
        }

        extern(C) void func(const(idevice_event_t)* event, void* user_data) {
            auto del = cast(UserData*) user_data;
            iDeviceEvent eventD = {
                event: cast(iDeviceEventType) event.event,
                udid: cast(string) event.udid.fromStringz(),
                connType: cast(iDeviceConnectionType) event.conn_type,
            };
            del.callback(eventD);
        }

        auto userData = new UserData(callback);
        GC.addRoot(userData);
        idevice_event_subscribe(&func, userData).assertSuccess();
    }

    public static @property iDeviceInfo[] deviceList() {
        int len;
        idevice_info_t* names;
        auto res = idevice_get_device_list_extended(&names, &len);
        if (res == idevice_error_t.IDEVICE_E_NO_DEVICE) {
            return [];
        }
        res.assertSuccess();
        return names[0..len].map!((s) => iDeviceInfo(cast(string) s.udid.fromStringz, cast(iDeviceConnectionType) s.conn_type)).array;
    }

    public @property string udid() {
        char* udid;
        handle.idevice_get_udid(&udid).assertSuccess();
        return cast(string) udid.fromStringz();
    }

    public this(string udid) {
        idevice_new_with_options(&handle, udid.toStringz, idevice_options.IDEVICE_LOOKUP_USBMUX | idevice_options.IDEVICE_LOOKUP_NETWORK).assertSuccess();
        handle.assertHandle("iDevice");
    }

    /**
     * Constructs a device, optionally biasing the lookup toward the network
     * transport (issue #13). When `preferNetwork` is set we add
     * `IDEVICE_LOOKUP_PREFER_NETWORK` so that, for a device reachable both over
     * USB and over Wi-Fi, libimobiledevice opens the network connection. Both
     * USBMUX and NETWORK lookups stay enabled, so a Wi-Fi-only or USB-only device
     * still connects.
     */
    public this(string udid, TransportPreference preference) {
        auto options = idevice_options.IDEVICE_LOOKUP_USBMUX | idevice_options.IDEVICE_LOOKUP_NETWORK;
        if (preference == TransportPreference.preferNetwork)
            options |= idevice_options.IDEVICE_LOOKUP_PREFER_NETWORK;
        idevice_new_with_options(&handle, udid.toStringz, options).assertSuccess();
        handle.assertHandle("iDevice");
    }

    ~this() {
        if (handle) { // it could have been partially initialized
            idevice_free(handle).assertSuccess();
        }
    }
}

public class LockdowndClient {
    lockdownd_client_t handle;

    public this(iDevice device, string serviceName) {
        lockdownd_client_new_with_handshake(device.handle, &handle, cast(const(char)*) serviceName.toStringz).assertSuccess();
        handle.assertHandle("LockdowndClient");
    }

    public @property string deviceName() {
        char* name;
        lockdownd_get_device_name(handle, &name).assertSuccess();
        return cast(string) name.fromStringz;
    }

    public LockdowndServiceDescriptor startService(string identifier) {
        lockdownd_service_descriptor_t descriptor;
        lockdownd_start_service(handle, identifier.toStringz, &descriptor).assertSuccess();
        descriptor.assertHandle("lockdown service descriptor for " ~ identifier);
        return new LockdowndServiceDescriptor(descriptor);
    }

    public string startSession(string hostId) {
        char* sessionId;
        lockdownd_start_session(handle, hostId.toStringz(), &sessionId, null).assertSuccess();
        return cast(string) sessionId.fromStringz();
    }

    public void stopSession(string sessionId) {
        lockdownd_stop_session(handle, sessionId.toStringz()).assertSuccess();
    }

    public Plist opIndexAssign(Plist value, string domain, string key) {
        if (!value.owns) {
            value = value.copy();
        }
        lockdownd_set_value(handle, domain.toStringz(), key.toStringz(), value.handle).assertSuccess();
        value.owns = false;
        return value;
    }

    public Plist opIndex(string domain, string key) {
        plist_t ret;
        lockdownd_get_value(handle, domain ? domain.toStringz() : null, key ? key.toStringz() : null, &ret).assertSuccess();
        return Plist.wrap(ret);
    }

    public lockdownd_error_t pair() {
        return lockdownd_pair(handle, null); // note: the error is expected within the normal execution flow, so no throw
    }

    ~this() {
        if (handle) { // it may be null if an exception has been thrown TODO: switch from a constructor to a static function to fix that.
            lockdownd_client_free(handle).assertSuccess();
        }
    }
}

public class LockdowndServiceDescriptor {
    lockdownd_service_descriptor_t handle;
    alias handle this;

    this(lockdownd_service_descriptor_t handle) {
        this.handle = handle;
    }

    ~this() {
        lockdownd_service_descriptor_free(handle).assertSuccess();
    }
}

public class InstallationProxyClient {
    instproxy_client_t handle;

    public this(iDevice device, LockdowndServiceDescriptor service) {
        instproxy_client_new(device.handle, service, &handle).assertSuccess();
        handle.assertHandle("InstallationProxyClient");
    }

    alias StatusCallback = void delegate(Plist command, Plist status);
    public void install(string packagePath, Plist clientOptions, StatusCallback statusCallback) {
        struct CallbackC {
            StatusCallback cb;
        }

        auto cb = new CallbackC(statusCallback);
        GC.addRoot(cb);
        instproxy_install(handle, packagePath.toStringz(), clientOptions.handle, (command_c, status_c, data) {
            auto cb = (cast(CallbackC*) data);
            GC.removeRoot(cb);
            cb.cb(Plist.wrap(command_c, false), Plist.wrap(status_c, false));
        }, cb).assertSuccess();
    }

    Plist browse(Plist options = null) {
        plist_t result;
        instproxy_browse(handle, options ? options.handle : null, &result).assertSuccess();
        return Plist.wrap(result);
    }

    /**
     * Uninstalls the application with the given on-device application identifier.
     *
     * Mirrors the `install` wrapper: drives `instproxy_uninstall` in async mode
     * (a status callback) and blocks on a `std.concurrency` handshake until the
     * device reports either `Complete` or an error. `appId` is the identifier as
     * seen ON THE DEVICE; for a Sideloader-installed app this is the mangled
     * `<bundleId>.<teamId>` (see `sideloadFull`'s `mainAppIdStr`), not the
     * original registry bundle id — the caller is responsible for mangling.
     *
     * Throws `AppUninstallationException` on a device-reported error.
     */
    public void uninstall(string appId, Plist clientOptions = null) {
        import std.concurrency : Tid, thisTid, send, receive;

        static struct CallbackData {
            Tid parentTid;
        }

        auto data = new CallbackData(thisTid());
        GC.addRoot(data);
        scope(exit) GC.removeRoot(data);

        instproxy_uninstall(handle, appId.toStringz(), clientOptions ? clientOptions.handle : null,
            (command_c, status_c, userData) {
                auto cbData = cast(CallbackData*) userData;
                try {
                    auto statusPlist = Plist.wrap(status_c, false);
                    auto status = statusPlist.dict();
                    if (auto statusEntry = "Status" in status) {
                        if (statusEntry.str().native() == "Complete") {
                            cbData.parentTid.send(cast(immutable(Exception)) null);
                        }
                        // Intermediate progress statuses are ignored: uninstall is
                        // quick and the CLI does not need a progress bar for it.
                    } else {
                        auto errorPlist = "Error" in status;
                        auto descriptionPlist = "ErrorDescription" in status;
                        auto detailPlist = "ErrorDetail" in status;
                        throw new AppUninstallationException(
                            errorPlist ? errorPlist.str().native() : "(null)",
                            descriptionPlist ? descriptionPlist.str().native() : "(null)",
                            detailPlist ? cast(long) detailPlist.uinteger().native() : -1
                        );
                    }
                } catch (Exception e) {
                    cbData.parentTid.send(cast(immutable) e);
                }
            }, data).assertSuccess();

        receive(
            (immutable(Exception) e) { if (e !is null) throw cast() e; },
        );
    }

    ~this() {
        if (handle) { // it may be null if an exception has been thrown TODO: switch from a constructor to a static function to fix that.
            instproxy_client_free(handle).assertSuccess();
        }
    }
}

alias AFCError = afc_error_t;
alias AFCFileMode = afc_file_mode_t;

public class AFCClient {
    afc_client_t handle;

    public this(iDevice device, LockdowndServiceDescriptor service) {
        afc_client_new(device.handle, service, &handle).assertSuccess();
        handle.assertHandle("AFCClient");
    }

    public this(HouseArrestClient houseArrestClient) {
        afc_client_new_from_house_arrest_client(houseArrestClient.handle, &handle).assertSuccess();
        handle.assertHandle("AFCClient");
    }

    ~this() {
        if (handle) { // it may be null if an exception has been thrown TODO: switch from a constructor to a static function to fix that.
            afc_client_free(handle).assertSuccess();
        }
    }

    AFCError getFileInfo(string path, out string[] fileInfo) {
        char** fileInfoC;
        auto ret = afc_get_file_info(handle, path.toStringz(), &fileInfoC);

        if (fileInfoC) {
            while (*fileInfoC) {
                fileInfo ~= cast(string) (*fileInfoC).fromStringz().dup;
                ++fileInfoC;
            }
            afc_dictionary_free(fileInfoC - fileInfo.length);
        }
        return ret;
    }

    AFCError makeDirectory(string path) {
        return afc_make_directory(handle, path.toStringz());
    }

    ulong open(string path, AFCFileMode fileMode) {
        ulong fileHandle;
        afc_file_open(handle, path.toStringz(), fileMode, &fileHandle).assertSuccess();
        return fileHandle;
    }

    void close(ulong fileHandle) {
        afc_file_close(handle, fileHandle).assertSuccess();
    }

    uint write(ulong fileHandle, ubyte[] data) {
        uint ret;
        afc_file_write(handle, fileHandle, cast(const(char)*) data.ptr, cast(uint) data.length, &ret).assertSuccess();
        return ret;
    }

    void removePath(string path) {
        afc_remove_path(handle, path.toStringz()).assertSuccess();
    }

    void removePathAndContents(string path) {
        afc_remove_path_and_contents(handle, path.toStringz()).assertSuccess();
    }
}

public class MisagentClient {
    misagent_client_t handle;

    public this(iDevice device, LockdowndServiceDescriptor service) {
        misagent_client_new(device.handle, service, &handle).assertSuccess();
        handle.assertHandle("MisagentClient");
    }

    void install(Plist profile) {
        misagent_install(handle, profile.handle).assertSuccess();
    }

    ~this() {
        if (handle) { // it may be null if an exception has been thrown TODO: switch from a constructor to a static function to fix that.
            misagent_client_free(handle).assertSuccess();
        }
    }
}

public class HouseArrestClient {
    house_arrest_client_t handle;

    public this(iDevice device, LockdowndServiceDescriptor service) {
        house_arrest_client_new(device.handle, service, &handle).assertSuccess();
        handle.assertHandle("HouseArrestClient");
    }

    public this(iDevice device, string label = null) {
        house_arrest_client_start_service(device.handle, &handle, label.toStringz()).assertSuccess();
        handle.assertHandle("HouseArrestClient");
    }

    void sendCommand(string command, string appId) {
        house_arrest_send_command(handle, command.toStringz(), appId.toStringz()).assertSuccess();
    }

    Plist getResult() {
        plist_t ret;
        house_arrest_get_result(handle, &ret).assertSuccess();
        return Plist.wrap(ret);
    }

    ~this() {
        if (handle) { // it may be null if an exception has been thrown TODO: switch from a constructor to a static function to fix that.
            house_arrest_client_free(handle).assertSuccess();
        }
    }
}

/// Thrown when the on-device `com.apple.debugserver` service cannot be started.
///
/// This is the overwhelmingly common JIT failure: the service only exists once a
/// Developer Disk Image (DDI) is mounted / Developer Mode is enabled on the
/// device. The message spells out the remediation so the CLI can surface it
/// verbatim.
class DebugserverUnavailableException: Exception {
    this(string detail, string file = __FILE__, int line = __LINE__) {
        super(
            "Could not start the on-device debugserver. " ~
            "Enable Developer Mode (Settings > Privacy & Security > Developer Mode) and make sure a " ~
            "Developer Disk Image is mounted (connect the device to Xcode once, or run a tool that mounts " ~
            "the personalized DDI). " ~ detail,
            file, line);
    }
}

/**
 * Thin D wrapper over libimobiledevice's debugserver client (the GDB-remote /
 * RSP transport to the on-device `com.apple.debugserver`).
 *
 * Mirrors the other client wrappers: the constructor starts the service through
 * lockdownd and throws on failure; `~this` frees the handle. The extra surface
 * here is the RSP plumbing JIT enablement needs: `setAckMode` (to flip into
 * no-ack mode after `QStartNoAckMode`) and `sendCommand`, which builds a
 * `debugserver_command_t`, sends it, and returns the raw RSP response string.
 *
 * NOTE: starting `com.apple.debugserver` only succeeds when a Developer Disk
 * Image is mounted / Developer Mode is on; otherwise the constructor throws a
 * `DebugserverUnavailableException` with the remediation steps.
 */
public class DebugserverClient {
    debugserver_client_t handle;

    public this(iDevice device, string label = "sideloader.jit") {
        auto err = debugserver_client_start_service(device.handle, &handle, label.toStringz());
        if (err != debugserver_error_t.DEBUGSERVER_E_SUCCESS)
            throw new DebugserverUnavailableException(format!"(debugserver error %s)"(err));
        handle.assertHandle("DebugserverClient");
    }

    /**
     * Enables or disables libimobiledevice's internal ACK-mode handling. After
     * the target accepts `QStartNoAckMode`, both sides stop sending the `+`/`-`
     * acknowledgements, so we disable it here to keep the conversation in sync.
     */
    public void setAckMode(bool enabled) {
        debugserver_client_set_ack_mode(handle, enabled ? 1 : 0).assertSuccess();
    }

    /// Sets the receive timeout (ms) for subsequent receives; negative = default.
    public void setReceiveTimeout(int timeoutMs) {
        debugserver_client_set_receive_timeout(handle, timeoutMs).assertSuccess();
    }

    /**
     * Builds and sends one RSP command (`name` plus `args` tokens, which the
     * library frames with `$...#<checksum>`), then returns the raw response with
     * the framing already stripped by libimobiledevice. Throws on a transport
     * error; an empty/`null` response is returned as `""`.
     */
    public string sendCommand(string name, string[] args) {
        // libimobiledevice wants a NULL-terminated argv array of C strings.
        const(char)*[] argv;
        argv.reserve(args.length + 1);
        foreach (a; args)
            argv ~= a.toStringz();
        argv ~= null;

        debugserver_command_t command;
        debugserver_command_new(name.toStringz(), cast(int) args.length,
            args.length ? argv.ptr : null, &command).assertSuccess();
        scope(exit) debugserver_command_free(command).assertSuccess();

        char* response;
        size_t responseSize;
        debugserver_client_send_command(handle, command, &response, &responseSize).assertSuccess();
        if (!response)
            return "";
        return cast(string) response[0 .. responseSize].idup;
    }

    ~this() {
        if (handle) { // it may be null if an exception has been thrown TODO: switch from a constructor to a static function to fix that.
            debugserver_client_free(handle).assertSuccess();
        }
    }
}
