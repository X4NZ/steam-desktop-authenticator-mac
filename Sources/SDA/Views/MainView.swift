import SteamAuthKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLogin = false
    @State private var showImport = false
    @State private var loginReason: LoginSheet.Reason = .setup

    var body: some View {
        NavigationSplitView {
            AccountSidebar(
                onAddAccount: {
                    loginReason = .setup
                    showLogin = true
                },
                onImport: { showImport = true }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            if let account = model.selectedAccount {
                AccountDetailView(account: account, onReauthenticate: { reason in
                    loginReason = reason
                    showLogin = true
                })
            } else {
                ContentUnavailableView(
                    "No account selected",
                    systemImage: "person.crop.circle",
                    description: Text("Choose an account from the list.")
                )
            }
        }
        .sheet(isPresented: $showLogin) { LoginSheet(reason: loginReason) }
        .sheet(isPresented: $showImport) { ImportSheet() }
    }
}

struct AccountSidebar: View {
    @EnvironmentObject private var model: AppModel
    let onAddAccount: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedAccountID) {
                ForEach(model.filteredAccounts) { account in
                    AccountRow(account: account, pending: model.pendingCounts[account.id] ?? 0)
                        .tag(account.id)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 4) {
                Button(action: onAddAccount) {
                    Image(systemName: "plus")
                }
                .help("Set up a new account")

                Button(action: onImport) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import maFiles")

                Spacer()

                if model.isEncrypted {
                    Button {
                        model.lock()
                    } label: {
                        Image(systemName: "lock")
                    }
                    .help("Lock")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Filter accounts")
    }
}

struct AccountRow: View {
    let account: SteamGuardAccount
    let pending: Int

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(account.accountName ?? "Unknown account")
                    .lineLimit(1)

                if account.fullyEnrolled == false {
                    Text("Not finalized")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if account.session?.refreshToken == nil {
                    Text("No session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if account.session?.isRefreshTokenExpired == true {
                    Text("Login expired")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)

            if pending > 0 {
                Text("\(pending)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }
}
