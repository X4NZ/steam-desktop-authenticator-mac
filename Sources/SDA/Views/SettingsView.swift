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
    @State private var useBiometrics = Keychain.storedProtection == .biometric
    @State private var showRemoveConfirmation = false
    @State private var biometricPassphrase = ""
    @State private var showBiometricPrompt = false

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

            if model.isEncrypted, Keychain.biometryAvailable {
                Section {
                    Toggle(
                        "Unlock with \(Keychain.biometryLabel)",
                        isOn: Binding(
                            get: { Keychain.storedProtection == .biometric },
                            set: { wanted in
                                if wanted {
                                    // The passphrase has to be re-entered once to
                                    // store it under the new protection.
                                    showBiometricPrompt = true
                                } else {
                                    Keychain.delete()
                                    useBiometrics = false
                                    remember = false
                                    model.show(.info, "\(Keychain.biometryLabel) unlock turned off.")
                                }
                            }
                        )
                    )

                    if showBiometricPrompt {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Enter your passphrase once to store it behind \(Keychain.biometryLabel).")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            SecureField("Passphrase", text: $biometricPassphrase)
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .onSubmit { enableBiometrics() }

                            HStack {
                                Spacer()
                                Button("Cancel") {
                                    showBiometricPrompt = false
                                    biometricPassphrase = ""
                                }
                                Button("Enable") { enableBiometrics() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(biometricPassphrase.isEmpty)
                            }
                            .controlSize(.small)
                        }
                    }
                } header: {
                    Text(Keychain.biometryLabel)
                } footer: {
                    Text(
                        "Your passphrase is kept in your login keychain, and the app asks for "
                        + "\(Keychain.biometryLabel) before using it. Your Mac's login password "
                        + "works as a fallback, and other apps cannot read the item without macOS "
                        + "asking you first."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section(model.isEncrypted ? "Change passphrase" : "Set a passphrase") {
                if model.isEncrypted {
                    passphraseField("Current passphrase", text: $currentPassphrase)
                }
                passphraseField("New passphrase", text: $newPassphrase)
                passphraseField("Repeat new passphrase", text: $confirmPassphrase) {
                    if canApply { apply() }
                }

                if !confirmPassphrase.isEmpty, newPassphrase != confirmPassphrase {
                    Text("Those do not match.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle("Remember in my keychain", isOn: $remember)

                if remember, Keychain.biometryAvailable {
                    Toggle("Require \(Keychain.biometryLabel) to unlock", isOn: $useBiometrics)
                }

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
                        // It needs the current passphrase from the field above,
                        // which nothing said: an empty field used to produce a
                        // vague failure after the confirmation dialog.
                        .disabled(currentPassphrase.isEmpty)
                    }
                } footer: {
                    if currentPassphrase.isEmpty {
                        Text("Enter your current passphrase above to remove encryption.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    /// A labelled, bordered secure field.
    ///
    /// Written out rather than using a bare SecureField because a grouped Form
    /// gives those no border, which leaves them invisible on a dark background.
    @ViewBuilder
    private func passphraseField(
        _ label: String,
        text: Binding<String>,
        onSubmit: @escaping () -> Void = {}
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(onSubmit)
        }
        .padding(.vertical, 2)
    }

    private func apply() {
        let current = model.isEncrypted ? currentPassphrase : model.currentPassphrase
        if model.changeEncryption(
            current: current,
            new: newPassphrase,
            remember: remember,
            protection: (remember && useBiometrics) ? .biometric : .plain
        ) {
            reset()
        }
    }

    /// Verifies the passphrase actually opens the store before storing it, so a
    /// typo cannot leave Touch ID handing back something that does not work.
    private func enableBiometrics() {
        guard !biometricPassphrase.isEmpty else { return }

        guard model.verifyPassphrase(biometricPassphrase) else {
            model.show(.error, "That passphrase does not match your maFiles.")
            return
        }

        if Keychain.save(passphrase: biometricPassphrase, protection: .biometric) {
            useBiometrics = true
            remember = true
            model.show(.success, "\(Keychain.biometryLabel) unlock is on.")
        } else {
            model.show(.error, "Could not save the passphrase to your keychain.")
        }

        biometricPassphrase = ""
        showBiometricPrompt = false
    }

    private func reset() {
        currentPassphrase = ""
        newPassphrase = ""
        confirmPassphrase = ""
    }
}
