import SwiftUI

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel

    @State private var passphrase = ""
    @State private var remember = false
    @State private var useBiometrics = Keychain.biometryAvailable
    @State private var failed = false
    @State private var biometricsRunning = false
    @State private var showPassphraseEntry = false
    @FocusState private var focused: Bool

    /// True when a Touch ID protected passphrase is waiting to be used.
    private var canUseBiometrics: Bool {
        Keychain.storedProtection == .biometric && Keychain.biometryAvailable
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: canUseBiometrics ? "touchid" : "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(canUseBiometrics ? Color.red : Color.accentColor)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 6) {
                Text("Unlock your maFiles")
                    .font(.title2.weight(.semibold))
                Text(
                    canUseBiometrics && !showPassphraseEntry
                        ? "Confirm with \(Keychain.biometryLabel) to see your codes."
                        : "Your account secrets are encrypted with a passphrase."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            if canUseBiometrics && !showPassphraseEntry {
                VStack(spacing: 12) {
                    Button {
                        Task { await authenticate() }
                    } label: {
                        Label(
                            "Unlock with \(Keychain.biometryLabel)",
                            systemImage: "touchid"
                        )
                        .frame(width: 220)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(biometricsRunning)

                    Button("Use Passphrase Instead") {
                        showPassphraseEntry = true
                        focused = true
                    }
                    .buttonStyle(.link)
                }
            } else {
                passphraseEntry
            }
        }
        .padding(40)
        .task {
            // Offer the prompt straight away; the button is there to retry.
            if canUseBiometrics { await authenticate() }
            else { focused = true }
        }
    }

    private var passphraseEntry: some View {
        VStack(spacing: 12) {
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(attemptUnlock)

            Toggle("Remember in my keychain", isOn: $remember)
                .controlSize(.small)

            if remember, Keychain.biometryAvailable {
                Toggle("Require \(Keychain.biometryLabel) to unlock", isOn: $useBiometrics)
                    .controlSize(.small)
            }

            if failed {
                Label("That passphrase did not work.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button("Unlock", action: attemptUnlock)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(passphrase.isEmpty)
        }
        .frame(width: 300)
    }

    private func authenticate() async {
        guard !biometricsRunning else { return }
        biometricsRunning = true
        defer { biometricsRunning = false }

        switch await model.unlockWithBiometrics() {
        case .unlocked:
            break
        case .needsPassphrase:
            // The prompt's cancel button says "Enter Passphrase", so it has to
            // actually get them there.
            showPassphraseEntry = true
            focused = true
        case .retry:
            break // The button stays, so they can ask for the prompt again.
        }
    }

    private func attemptUnlock() {
        guard !passphrase.isEmpty else { return }

        if model.unlock(
            passphrase: passphrase,
            remember: remember,
            protection: (remember && useBiometrics) ? .biometric : .plain
        ) {
            failed = false
            passphrase = ""
        } else {
            failed = true
        }
    }
}
