import AppKit
import SteamAuthKit
import SwiftUI

/// The menu bar title: the live code, or a lock when the store is locked.
struct MenuBarLabel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.lockState {
        case .unlocked where model.currentCode != "—":
            Text(model.currentCode)
                .font(.system(.body, design: .monospaced))
        case .locked:
            Image(systemName: "lock.shield.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        default:
            Image(systemName: "shield.lefthalf.filled")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var totalPending: Int {
        model.pendingCounts.values.reduce(0, +)
    }

    var body: some View {
        if model.lockState == .unlocked {
            if let account = model.selectedAccount {
                Text(account.accountName ?? "Account")

                Button("Copy \(model.currentCode)") {
                    model.copyCurrentCode()
                }
                .keyboardShortcut("c")

                Text("Changes in \(model.secondsRemaining)s")
            }

            Divider()

            if model.accounts.count > 1 {
                Menu("Switch Account") {
                    ForEach(model.accounts) { account in
                        Button {
                            model.selectedAccountID = account.id
                            model.updateCode()
                        } label: {
                            let pending = model.pendingCounts[account.id] ?? 0
                            Text(
                                (account.accountName ?? "Account")
                                    + (pending > 0 ? " (\(pending))" : "")
                            )
                        }
                    }
                }
            }

            Button(totalPending > 0 ? "Confirmations (\(totalPending))…" : "Confirmations…") {
                activateWindow()
                if let account = model.selectedAccount {
                    Task { await model.loadConfirmations(for: account) }
                }
            }
        } else if model.lockState == .locked {
            Text("Locked")
            Button("Unlock…") { activateWindow() }
        } else if case .failed = model.lockState {
            // Never the setup offer here: that links a new authenticator, and
            // the secrets this could not read are still on disk.
            Text("maFiles could not be read")
            Button("Show the Problem…") { activateWindow() }
        } else {
            Button("Set Up an Account…") { activateWindow() }
        }

        Divider()

        Button("Open Steam Desktop Authenticator") { activateWindow() }

        if model.isEncrypted, model.lockState == .unlocked {
            Button("Lock") { model.lock() }
        }

        Divider()

        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func activateWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
