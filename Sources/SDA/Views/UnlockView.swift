import SwiftUI

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var passphrase = ""
    @State private var remember = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Unlock your maFiles")
                    .font(.title2.weight(.semibold))
                Text("Your account secrets are encrypted with a passphrase.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(attemptUnlock)

                Toggle("Remember in my keychain", isOn: $remember)
                    .controlSize(.small)

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
        .padding(40)
        .onAppear { focused = true }
    }

    private func attemptUnlock() {
        guard !passphrase.isEmpty else { return }
        if model.unlock(passphrase: passphrase, remember: remember) {
            failed = false
            passphrase = ""
        } else {
            failed = true
        }
    }
}
