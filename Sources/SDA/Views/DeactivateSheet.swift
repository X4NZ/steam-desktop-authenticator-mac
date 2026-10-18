import SteamAuthKit
import SwiftUI

/// Removes the authenticator from the Steam account.
///
/// Deliberately awkward: it needs the revocation code typed out, because getting
/// this wrong locks the user out of their own account.
struct DeactivateSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let account: SteamGuardAccount

    @State private var typedCode = ""
    @State private var scheme = 1
    @State private var busy = false

    private var codeMatches: Bool {
        guard let expected = account.revocationCode else { return false }
        return typedCode.trimmingCharacters(in: .whitespaces).uppercased() == expected.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Deactivate authenticator").font(.headline)
                    Text(account.accountName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "This removes Steam Guard's authenticator from your Steam account and deletes "
                    + "it from this Mac. Trading will be restricted for a few days afterwards."
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

                Picker("Afterwards", selection: $scheme) {
                    Text("Send Steam Guard codes by email").tag(1)
                    Text("Turn Steam Guard off entirely").tag(2)
                }
                .pickerStyle(.radioGroup)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Type your revocation code to confirm:")
                        .font(.callout)
                    TextField("R#####", text: $typedCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 180)
                }

                if scheme == 2 {
                    CalloutBox(
                        kind: .warning,
                        title: "Turning Steam Guard off is risky",
                        message: "Your account will have no second factor at all."
                    )
                }
            }
            .padding(20)

            Divider()

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Deactivate") {
                    Task {
                        busy = true
                        let removed = await model.deactivate(account, scheme: scheme)
                        busy = false
                        if removed { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(busy || !codeMatches)
            }
            .padding(16)
        }
        .frame(width: 460)
    }
}
