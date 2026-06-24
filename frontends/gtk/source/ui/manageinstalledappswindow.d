module ui.manageinstalledappswindow;

/**
 * App-management UI (#14): an installed-apps list with an expiry countdown and
 * one-click refresh / uninstall / auto-refresh toggle.
 *
 * Structure mirrors `ManageCertificatesWindow`: a `Dialog` with a `ListBox`
 * inside a `ScrolledWindow`, populated from a background `Thread` (the registry
 * read is local I/O), widgets only ever mutated back on the UI thread via
 * `runInUIThread`. Each installed app is an `ExpanderRow` whose child rows drive
 * the actions.
 *
 * The countdown uses the shared core helper `app.timeutil.formatExpiryCountdown`
 * (the same one the CLI `list` command uses). Refresh re-uses the existing GUI
 * login + sideload flow (`AuthenticationAssistant.authenticate` ->
 * `SideloadProgressWindow.sideload` of the cached IPA). Uninstall talks to the
 * device over `InstallationProxyClient`, then drops the registry record.
 */

import core.thread;

import std.datetime : Clock;
import std.format;
import file = std.file;

import adw.ActionRow;
import adw.ExpanderRow;

import gdk.Cursor;

import gtk.Dialog;
import gtk.ListBox;
import gtk.MessageDialog;
import gtk.ScrolledWindow;
import gtk.Window;

import slf4d;

import imobiledevice;

import app.persistence;
import app.session : systemConfigurationPath;
import app.timeutil : formatExpiryCountdown, parseExpiry;

import sideload;

import ui.authentication.authenticationassistant;
import ui.sideloadergtkapplication;
import ui.sideloadprogresswindow;
import ui.utils;

class ManageInstalledAppsWindow: Dialog {
    iDevice device;
    SideloaderGtkApplication app;

    ListBox appListBox;

    Cursor defaultCursor;
    Cursor waitCursor;

    this(Window mainWindow, iDevice device, SideloaderGtkApplication app) {
        this.device = device;
        this.app = app;

        this.setTitle("Manage installed apps");
        this.setTransientFor(mainWindow);
        this.setDefaultSize(500, 300);
        this.setModal(true);

        defaultCursor = this.getCursor();
        waitCursor = new Cursor("wait", defaultCursor);

        auto scroll = new ScrolledWindow();
        appListBox = new ListBox(); {
            setBusy(true);
            new Thread({
                string configurationPath = systemConfigurationPath();
                auto registry = loadInstalledRegistry(configurationPath);
                runInUIThread({
                    foreach (installedApp; registry.apps) {
                        appListBox.append(new InstalledAppRow(this, configurationPath, installedApp));
                    }
                    setBusy(false);
                });
            }).start();
        }
        scroll.setChild(appListBox);
        this.setChild(scroll);
    }

    void setBusy(bool val) {
        this.setSensitive(!val);
        this.setCursor(val ? waitCursor : defaultCursor);
    }

    void showError(string message) {
        auto errorDialog = new MessageDialog(this, DialogFlags.DESTROY_WITH_PARENT | DialogFlags.MODAL | DialogFlags.USE_HEADER_BAR, MessageType.ERROR, ButtonsType.CLOSE, message);
        errorDialog.addOnResponse((_, __) {
            errorDialog.close();
        });
        errorDialog.show();
    }

    class InstalledAppRow: ExpanderRow {
        string configurationPath;
        InstalledApp installedApp;

        ActionRow autoRefreshRow;

        this(ManageInstalledAppsWindow window, string configPath, InstalledApp app_) {
            // Store both on the row so the activation lambdas mutate/read the same
            // canonical copy (D resolves an unqualified `installedApp` to a local
            // parameter, so we deliberately keep no same-named parameter around).
            this.configurationPath = configPath;
            this.installedApp = app_;

            string name = installedApp.appName.length ? installedApp.appName : installedApp.bundleId;
            this.setTitle(name);

            this.setSubtitle(subtitleText());

            // "Refresh now": re-sideload the cached IPA through the existing GUI
            // login + progress flow.
            ActionRow refreshRow = new ActionRow();
            refreshRow.setTitle("Refresh now");
            refreshRow.setActivatable(true);
            refreshRow.addOnActivated((_) {
                if (installedApp.sourceIpaPath.length == 0 || !file.exists(installedApp.sourceIpaPath)) {
                    window.showError(format!"Cannot refresh %s: the source IPA is not available."(name));
                    return;
                }
                try {
                    Application iosApp = new Application(installedApp.sourceIpaPath);
                    AuthenticationAssistant.authenticate(window.app, (developer) {
                        SideloadProgressWindow.sideload(window.app, developer, iosApp, window.device);
                    });
                } catch (Exception ex) {
                    getLogger().errorF!"Cannot refresh application: %s"(ex);
                    window.showError(format!"Refresh failed: %s"(ex.msg));
                }
            });
            this.addRow(refreshRow);

            // "Uninstall": remove from the device (on-device id is mangled as
            // <bundleId>.<teamId>, see sideloadFull / the CLI uninstall command),
            // then drop the registry record and the row.
            ActionRow uninstallRow = new ActionRow();
            uninstallRow.setTitle("Uninstall");
            uninstallRow.setActivatable(true);
            uninstallRow.addOnActivated((_) {
                string onDeviceId = installedApp.teamId.length
                    ? installedApp.bundleId ~ "." ~ installedApp.teamId
                    : installedApp.bundleId;
                window.setBusy(true);
                new Thread({
                    try {
                        scope lockdown = new LockdowndClient(window.device, "sideloader.uninstall");
                        scope service = lockdown.startService("com.apple.mobile.installation_proxy");
                        scope client = new InstallationProxyClient(window.device, service);
                        client.uninstall(onDeviceId);

                        auto registry = loadInstalledRegistry(this.configurationPath);
                        registry.remove(installedApp.bundleId);
                        saveInstalledRegistry(this.configurationPath, registry);

                        runInUIThread({
                            window.setBusy(false);
                            this.unparent();
                        });
                    } catch (Exception ex) {
                        getLogger().errorF!"Failed to uninstall %s: %s"(onDeviceId, ex);
                        runInUIThread({
                            window.setBusy(false);
                            window.showError(format!"Uninstall failed: %s"(ex.msg));
                        });
                    }
                }).start();
            });
            this.addRow(uninstallRow);

            // "Auto-refresh" toggle: flips the registry's `enabled` flag and
            // persists it, updating its own title to reflect the new state.
            autoRefreshRow = new ActionRow();
            autoRefreshRow.setTitle(autoRefreshTitle());
            autoRefreshRow.setActivatable(true);
            autoRefreshRow.addOnActivated((_) {
                installedApp.enabled = !installedApp.enabled;
                autoRefreshRow.setTitle(autoRefreshTitle());
                // Reflect the new disabled/enabled marker in the expander subtitle.
                this.setSubtitle(subtitleText());

                window.setBusy(true);
                new Thread({
                    try {
                        auto registry = loadInstalledRegistry(this.configurationPath);
                        registry.upsert(installedApp);
                        saveInstalledRegistry(this.configurationPath, registry);
                        runInUIThread({ window.setBusy(false); });
                    } catch (Exception ex) {
                        getLogger().errorF!"Failed to persist auto-refresh state: %s"(ex);
                        runInUIThread({
                            window.setBusy(false);
                            window.showError(format!"Could not save the setting: %s"(ex.msg));
                        });
                    }
                }).start();
            });
            this.addRow(autoRefreshRow);
        }

        private string autoRefreshTitle() {
            return installedApp.enabled ? "Auto-refresh: on" : "Auto-refresh: off";
        }

        private string subtitleText() {
            string subtitle = formatExpiryCountdown(parseExpiry(installedApp.expiryDate), Clock.currTime());
            if (!installedApp.enabled)
                subtitle ~= " [disabled]";
            return subtitle;
        }
    }
}

// NOTE(#14): surfacing the background auto-refresh service status here would
// require the CLI's `service.d` logic (or new cross-frontend plumbing); that is
// intentionally deferred so this window stays free of CLI-only dependencies.
