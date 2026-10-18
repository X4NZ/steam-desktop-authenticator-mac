import AppUpdater
import AppKit
import SteamAuthKit
import SwiftUI

@main
struct SDAApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Steam Desktop Authenticator", id: "main") {
            RootView()
                .environmentObject(model)
                .sheet(item: $model.availableUpdate) { release in
                    UpdateSheet(release: release)
                        .environmentObject(model)
                }
                .frame(minWidth: 820, minHeight: 540)
                .task { await model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        // A menu bar extra is the point of an app like this on macOS: the code
        // is one click away without bringing a window forward.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar when the window is closed.
        false
    }
}

/// Menu bar commands, mirroring SDA's menus.
struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { await model.checkForUpdate(silently: false) }
            }
            .disabled(model.isCheckingForUpdate)
        }

        CommandGroup(after: .newItem) {
            Button("Copy Steam Guard Code") { model.copyCurrentCode() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selectedAccount == nil)

            Divider()

            Button("Lock") { model.lock() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(!model.isEncrypted || model.lockState != .unlocked)
        }

        CommandMenu("Account") {
            Button("Refresh Confirmations") {
                if let account = model.selectedAccount {
                    Task { await model.loadConfirmations(for: account) }
                }
            }
            .keyboardShortcut("r")
            .disabled(model.selectedAccount == nil)

            Button("Force Session Refresh") {
                if let account = model.selectedAccount {
                    Task { await model.forceRefreshSession(for: account) }
                }
            }
            .disabled(model.selectedAccount == nil)
        }
    }
}
