import SteamAuthKit
import SwiftUI

struct AccountDetailView: View {
    @EnvironmentObject private var model: AppModel
    let account: SteamGuardAccount
    let onReauthenticate: (LoginSheet.Reason) -> Void

    @State private var showConfirmations = false
    @State private var showRevocation = false
    @State private var showDeactivate = false
    @State private var showForget = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                CodeCard(account: account)

                if account.fullyEnrolled == false {
                    CalloutBox(
                        kind: .warning,
                        title: "This authenticator was never finalized",
                        message:
                            "Steam has not activated it, so these codes will not work yet. "
                            + "Set the account up again to finish, or remove it."
                    )
                }

                if account.session?.isRefreshTokenExpired == true {
                    CalloutBox(
                        kind: .warning,
                        title: "Your Steam session has expired",
                        message: "Codes still work, but trade confirmations need a fresh login.",
                        actionTitle: "Log in again",
                        action: { onReauthenticate(.refresh(account)) }
                    )
                } else if account.session?.isRefreshTokenAboutToExpire == true {
                    CalloutBox(
                        kind: .info,
                        title: "Your Steam session expires within a day",
                        message: "Log in again to keep confirmations working.",
                        actionTitle: "Log in again",
                        action: { onReauthenticate(.refresh(account)) }
                    )
                }

                ConfirmationsPanel(account: account)

                AccountInfoPanel(
                    account: account,
                    showRevocation: $showRevocation,
                    onDeactivate: { showDeactivate = true },
                    onForget: { showForget = true },
                    onReauthenticate: { onReauthenticate(.refresh(account)) }
                )
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(account.accountName ?? "Account")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.copyCurrentCode()
                } label: {
                    Label("Copy Code", systemImage: "doc.on.doc")
                }
                .help("Copy the current Steam Guard code")
            }
        }
        .confirmationDialog(
            "Remove this account from this app?",
            isPresented: $showForget,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { model.forget(account) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The authenticator stays active on Steam, and this Mac will no longer have "
                + "its secrets. Make sure you have your revocation code and a backup first."
            )
        }
        .sheet(isPresented: $showDeactivate) {
            DeactivateSheet(account: account)
        }
    }
}

/// The main event: the current code, big, with the window countdown.
struct CodeCard: View {
    @EnvironmentObject private var model: AppModel
    let account: SteamGuardAccount

    private var progress: Double { Double(model.secondsRemaining) / 30.0 }

    var body: some View {
        VStack(spacing: 16) {
            Text("Steam Guard code")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 14) {
                Text(model.currentCode)
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .monospaced()
                    .kerning(6)
                    .contentTransition(.numericText())
                    .textSelection(.enabled)

                CountdownRing(progress: progress, seconds: model.secondsRemaining)
            }

            Button {
                model.copyCurrentCode()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .frame(width: 110)
            }
            .controlSize(.large)
            .disabled(model.currentCode == "—")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CountdownRing: View {
    let progress: Double
    let seconds: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 4)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    seconds <= 5 ? Color.orange : Color.accentColor,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)

            Text("\(seconds)")
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel("\(seconds) seconds until this code changes")
    }
}

struct ConfirmationsPanel: View {
    @EnvironmentObject private var model: AppModel
    let account: SteamGuardAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trade confirmations")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.loadConfirmations(for: account) }
                } label: {
                    if model.isLoadingConfirmations {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isLoadingConfirmations)
            }

            if account.session?.accessToken == nil {
                Text("Log in to this account to see confirmations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if model.confirmations.isEmpty {
                Text(
                    model.isLoadingConfirmations
                        ? "Checking…"
                        : "Nothing pending. Hit Refresh to check again."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ForEach(model.confirmations) { confirmation in
                    ConfirmationRow(confirmation: confirmation)
                    if confirmation.id != model.confirmations.last?.id { Divider() }
                }

                if model.confirmations.count > 1 {
                    HStack {
                        Spacer()
                        Button("Cancel All") { Task { await model.actOnAll(accept: false) } }
                        Button("Confirm All") { Task { await model.actOnAll(accept: true) } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ConfirmationRow: View {
    @EnvironmentObject private var model: AppModel
    let confirmation: Confirmation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: confirmation.type.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(confirmation.headline)
                    .font(.callout.weight(.medium))

                ForEach(confirmation.summary, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text(confirmation.typeName ?? confirmation.type.label)
                    if let created = confirmation.createdAt {
                        Text("·")
                        Text(created, style: .relative)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Button(confirmation.acceptLabel) {
                    Task { await model.act(on: confirmation, accept: true) }
                }
                .buttonStyle(.borderedProminent)

                Button(confirmation.cancelLabel) {
                    Task { await model.act(on: confirmation, accept: false) }
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.vertical, 6)
    }
}

struct AccountInfoPanel: View {
    @EnvironmentObject private var model: AppModel
    let account: SteamGuardAccount
    @Binding var showRevocation: Bool
    let onDeactivate: () -> Void
    let onForget: () -> Void
    let onReauthenticate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                InfoRow(label: "Account name", value: account.accountName ?? "—")

                if let steamID = account.session?.steamID, steamID != 0 {
                    InfoRow(label: "SteamID", value: String(steamID), selectable: true)
                }

                GridRow {
                    Text("Revocation code")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if showRevocation {
                            Text(account.revocationCode ?? "—")
                                .monospaced()
                                .textSelection(.enabled)
                        } else {
                            Text("•••••••")
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                        Button(showRevocation ? "Hide" : "Reveal") {
                            showRevocation.toggle()
                        }
                        .controlSize(.small)
                        .buttonStyle(.link)
                    }
                }

                InfoRow(
                    label: "Steam time offset",
                    value: "\(model.steamTimeOffset >= 0 ? "+" : "")\(model.steamTimeOffset)s"
                )
            }
            .font(.callout)

            Divider()
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                Button("Log In Again", action: onReauthenticate)

                Button("Force Session Refresh") {
                    Task { await model.forceRefreshSession(for: account) }
                }

                Spacer()

                Menu {
                    Button("Remove from This App…", action: onForget)
                    Divider()
                    Button("Deactivate Authenticator on Steam…", role: .destructive, action: onDeactivate)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var selectable = false

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            if selectable {
                Text(value).textSelection(.enabled)
            } else {
                Text(value)
            }
        }
    }
}

struct CalloutBox: View {
    enum Kind { case info, warning }

    let kind: Kind
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(kind == .warning ? .orange : .accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            (kind == .warning ? Color.orange : Color.accentColor).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}
