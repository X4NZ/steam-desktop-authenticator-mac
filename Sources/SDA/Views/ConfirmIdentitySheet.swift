import SwiftUI

/// Stands between a stored secret and the pasteboard.
///
/// Unlocking the store happens once, at launch; the window then stays open for
/// as long as the Mac does. That is fine for reading a code, which expires in
/// thirty seconds, and not fine for handing out a secret that does not expire
/// at all. This asks again at the moment it matters, so an unlocked window left
/// on a desk is not the same as consent.
///
/// Two routes, because neither works everywhere: Touch ID — or the login
/// password on a Mac without it — proves the person is present without their
/// having to remember anything, and the store passphrase works when the Mac
/// cannot ask, or when they would rather type it.
struct ConfirmIdentitySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// What the person is about to let out, in a few words.
    let purpose: String
    let onConfirmed: () -> Void

    @State private var passphrase = ""
    @State private var showPassphraseEntry = !Keychain.canConfirmPresence
    @State private var running = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Confirm it is you").font(.headline)
                    Text(purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if showPassphraseEntry {
                    passphraseEntry
                } else {
                    presencePrompt
                }
            }
            .padding(20)

            Divider()

            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                if showPassphraseEntry {
                    Button("Confirm", action: confirmWithPassphrase)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(passphrase.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 420)
        .task {
            // Offer the system prompt straight away; the button is there to
            // ask again after a cancel or a finger it would not read.
            if !showPassphraseEntry { await confirmWithPresence() }
        }
    }

    private var presencePrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Confirm with \(Keychain.presenceLabel) to continue.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    Task { await confirmWithPresence() }
                } label: {
                    Label("Confirm with \(Keychain.presenceLabel)", systemImage: "touchid")
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)

                Button("Use Passphrase Instead") {
                    showPassphraseEntry = true
                    focused = true
                }
                .buttonStyle(.link)
            }
        }
    }

    private var passphraseEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter the passphrase your maFiles are encrypted with.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            // Spelled out rather than a labelled SecureField, which a grouped
            // layout renders without a border and so invisibly on dark.
            VStack(alignment: .leading, spacing: 4) {
                Text("Passphrase")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($focused)
                    .onSubmit(confirmWithPassphrase)
            }

            if failed {
                Label("That passphrase did not work.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func confirmWithPresence() async {
        guard !running else { return }
        running = true
        defer { running = false }

        switch await Keychain.confirmPresence(reason: purpose) {
        case .success:
            succeed()

        case .failure(let error):
            if let message = error.errorDescription { model.show(.error, message) }
            switch error {
            case .declined, .notFound, .unavailable:
                // The prompt's cancel button offers the passphrase, so it has
                // to actually lead there.
                showPassphraseEntry = true
                focused = true
            case .interrupted, .authenticationFailed:
                break // The button stays, so they can ask for the prompt again.
            }
        }
    }

    private func confirmWithPassphrase() {
        guard !passphrase.isEmpty else { return }

        guard model.verifyPassphrase(passphrase) else {
            failed = true
            return
        }
        passphrase = ""
        succeed()
    }

    private func succeed() {
        onConfirmed()
        dismiss()
    }
}
