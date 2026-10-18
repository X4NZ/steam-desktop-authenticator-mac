import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLogin = false
    @State private var showImport = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 22) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("Steam Desktop Authenticator")
                        .font(.title.weight(.semibold))
                    Text("Steam Guard codes and trade confirmations on your Mac.")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        showImport = true
                    } label: {
                        Label("Import maFiles", systemImage: "square.and.arrow.down")
                            .frame(width: 150)
                    }
                    .controlSize(.large)

                    Button {
                        showLogin = true
                    } label: {
                        Label("Set Up New Account", systemImage: "plus")
                            .frame(width: 170)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }

                WarningBox()
                    .frame(maxWidth: 520)
            }

            Spacer()
        }
        .padding(40)
        .sheet(isPresented: $showLogin) { LoginSheet(reason: .setup) }
        .sheet(isPresented: $showImport) { ImportSheet() }
    }
}

/// The honest version of SDA's README warnings, shown where it matters.
struct WarningBox: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Read this first", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            Text(
                """
                Keeping your authenticator on the same machine you trade from removes much \
                of the protection two-factor authentication gives you. If this Mac is \
                compromised, so is your Steam account.

                Write down your revocation code (the R##### string) and back up your \
                maFiles folder. Without them, losing this Mac means losing the account.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
