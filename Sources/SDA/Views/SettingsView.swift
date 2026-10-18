import AppKit
import SteamAuthKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ConfirmationSettings()
                .tabItem { Label("Confirmations", systemImage: "checklist") }
            EncryptionSettings()
                .tabItem { Label("Encryption", systemImage: "lock") }
        }
        .frame(width: 480)
        .padding(20)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("maFiles folder") {
                    HStack(spacing: 8) {
                        Text(model.storeDirectory.path)
                            .font(.callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Reveal") {
                            NSWorkspace.shared.selectFile(
                                nil,
                                inFileViewerRootedAtPath: model.storeDirectory.path
                            )
                        }
                        .controlSize(.small)
                    }
                }

                LabeledContent("Steam time offset") {
                    Text("\(model.steamTimeOffset >= 0 ? "+" : "")\(model.steamTimeOffset) seconds")
                        .font(.callout)
                }
            } footer: {
                Text(
                    "Back up this folder. Without it, and without your revocation codes, "
                    + "a lost Mac means lost Steam accounts."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ConfirmationSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Check for confirmations in the background",
                    isOn: Binding(
                        get: { model.settings.periodicChecking },
                        set: { value in model.updateSettings { $0.periodicChecking = value } }
                    )
                )

                if model.settings.periodicChecking {
                    Picker(
                        "Check every",
                        selection: Binding(
                            get: { model.settings.periodicCheckingInterval },
                            set: { value in model.updateSettings { $0.periodicCheckingInterval = value } }
                        )
                    ) {
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                    }

                    Toggle(
                        "Check every account, not just the selected one",
                        isOn: Binding(
                            get: { model.settings.checkAllAccounts },
                            set: { value in model.updateSettings { $0.checkAllAccounts = value } }
                        )
                    )
                }
            } header: {
                Text("Background checking")
            } footer: {
                Text("You will get a notification when something is waiting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Automatically confirm trades",
                    isOn: Binding(
                        get: { model.settings.autoConfirmTrades },
                        set: { value in model.updateSettings { $0.autoConfirmTrades = value } }
                    )
                )
                Toggle(
                    "Automatically confirm market listings",
                    isOn: Binding(
                        get: { model.settings.autoConfirmMarketTransactions },
                        set: { value in
                            model.updateSettings { $0.autoConfirmMarketTransactions = value }
                        }
                    )
                )
            } header: {
                Text("Auto-confirm")
            } footer: {
                Text(
                    "Auto-confirming accepts trades without asking you. Anything that can reach "
                    + "your Steam account can then move your items while this app runs. "
                    + "Leave these off unless you specifically need them."
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }
}

struct EncryptionSettings: View {
    @EnvironmentObject private var model: AppModel

    @State private var currentPassphrase = ""
    @State private var newPassphrase = ""
    @State private var confirmPassphrase = ""
    @State private var remember = Keychain.hasStoredPassphrase
    @State private var showRemoveConfirmation = false

    private var canApply: Bool {
        guard !newPassphrase.isEmpty else { return false }
        guard newPassphrase == confirmPassphrase else { return false }
        if model.isEncrypted { return !currentPassphrase.isEmpty }
        return true
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    if model.isEncrypted {
                        Label("Encrypted", systemImage: "lock.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not encrypted", systemImage: "lock.open")
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                if !model.isEncrypted {
                    Text(
                        "Without encryption, anything that can read your home folder can take "
                        + "your Steam accounts."
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section(model.isEncrypted ? "Change passphrase" : "Set a passphrase") {
                if model.isEncrypted {
                    SecureField("Current passphrase", text: $currentPassphrase)
                }
                SecureField("New passphrase", text: $newPassphrase)
                SecureField("Repeat new passphrase", text: $confirmPassphrase)

                if !confirmPassphrase.isEmpty, newPassphrase != confirmPassphrase {
                    Text("Those do not match.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle("Remember in my keychain", isOn: $remember)

                HStack {
                    Spacer()
                    Button(model.isEncrypted ? "Change Passphrase" : "Encrypt maFiles") {
                        apply()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)
                }
            }

            if model.isEncrypted {
                Section {
                    HStack {
                        Spacer()
                        Button("Remove Encryption…", role: .destructive) {
                            showRemoveConfirmation = true
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove encryption from your maFiles?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Encryption", role: .destructive) {
                if model.changeEncryption(current: currentPassphrase, new: nil, remember: false) {
                    reset()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account secrets will be stored as plain text in your home folder.")
        }
    }

    private func apply() {
        let current = model.isEncrypted ? currentPassphrase : model.currentPassphrase
        if model.changeEncryption(current: current, new: newPassphrase, remember: remember) {
            reset()
        }
    }

    private func reset() {
        currentPassphrase = ""
        newPassphrase = ""
        confirmPassphrase = ""
    }
}
