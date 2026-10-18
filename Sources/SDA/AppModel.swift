import AppKit
import Foundation
import SteamAuthKit
import SwiftUI
import UserNotifications

/// Everything the UI observes: the unlocked accounts, the live code, pending
/// confirmations and the background checking timer.
@MainActor
final class AppModel: ObservableObject {

    enum LockState: Equatable {
        case loading
        case locked
        case unlocked
        /// No accounts yet, so there is nothing to unlock.
        case empty
    }

    // MARK: Published state

    @Published var lockState: LockState = .loading
    @Published var accounts: [SteamGuardAccount] = []
    @Published var selectedAccountID: String?
    @Published var currentCode: String = "—"
    @Published var secondsRemaining: Int = 30
    @Published var confirmations: [Confirmation] = []
    @Published var isLoadingConfirmations = false
    @Published var banner: Banner?
    @Published var settings = Manifest()
    @Published var searchText: String = ""
    @Published var steamTimeOffset: Int64 = 0
    /// Per-account pending confirmation counts, for the sidebar badges.
    @Published var pendingCounts: [String: Int] = [:]

    struct Banner: Identifiable, Equatable {
        enum Kind { case info, success, warning, error }
        let id = UUID()
        var kind: Kind
        var message: String
    }

    // MARK: Internals

    private let store: AccountStore
    private var passphrase: String?
    private var codeTimer: Timer?
    private var checkTimer: Timer?
    /// Confirmation ids already surfaced, so a notification fires only once.
    private var notifiedConfirmationIDs = Set<UInt64>()

    var storeDirectory: URL { store.directory }
    var isEncrypted: Bool { store.isEncrypted }
    var currentPassphrase: String? { passphrase }

    init(store: AccountStore = AccountStore()) {
        self.store = store
    }

    var selectedAccount: SteamGuardAccount? {
        guard let selectedAccountID else { return accounts.first }
        return accounts.first { $0.id == selectedAccountID } ?? accounts.first
    }

    var filteredAccounts: [SteamGuardAccount] {
        guard !searchText.isEmpty else { return accounts }
        return accounts.filter {
            ($0.accountName ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Startup

    func start() async {
        do {
            try store.loadManifest()
            settings = store.manifest
        } catch {
            show(.error, error.localizedDescription)
        }

        if store.manifest.entries.isEmpty {
            lockState = .empty
        } else if store.isEncrypted {
            // Try the keychain first so an encrypted store can open unattended.
            if let saved = Keychain.load(), unlock(passphrase: saved, remember: false) {
                lockState = .unlocked
            } else {
                lockState = .locked
            }
        } else {
            _ = unlock(passphrase: nil, remember: false)
            lockState = .unlocked
        }

        startCodeTimer()
        await alignTime()
        restartCheckTimer()
        await requestNotificationPermission()

        if lockState == .unlocked {
            await refreshSessionsIfNeeded()
        }
    }

    /// Loads and decrypts the accounts. Returns false on a wrong passphrase.
    @discardableResult
    func unlock(passphrase candidate: String?, remember: Bool) -> Bool {
        do {
            accounts = try store.loadAccounts(passphrase: candidate)
            passphrase = candidate
            settings = store.manifest

            if selectedAccountID == nil { selectedAccountID = accounts.first?.id }
            if remember, let candidate { _ = Keychain.save(passphrase: candidate) }

            lockState = accounts.isEmpty ? .empty : .unlocked
            updateCode()
            return true
        } catch {
            if case StoreError.accountFileMissing = error {
                show(.error, error.localizedDescription)
            }
            return false
        }
    }

    func lock() {
        accounts = []
        confirmations = []
        passphrase = nil
        currentCode = "—"
        lockState = .locked
    }

    // MARK: - Codes

    private func startCodeTimer() {
        codeTimer?.invalidate()
        // A one-second tick is enough: codes change on 30-second boundaries.
        codeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCode() }
        }
        updateCode()
    }

    func updateCode() {
        guard let account = selectedAccount else {
            currentCode = "—"
            return
        }
        let time = Int64(Date().timeIntervalSince1970) + steamTimeOffset
        currentCode = account.generateCode(forTime: time) ?? "—"
        secondsRemaining = 30 - Int(time % 30)
    }

    func copyCurrentCode() {
        guard currentCode != "—" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentCode, forType: .string)
        show(.success, "Code \(currentCode) copied.")
    }

    private func alignTime() async {
        await SteamTime.shared.align()
        steamTimeOffset = await SteamTime.shared.currentOffset
        updateCode()

        if abs(steamTimeOffset) > 30 {
            show(
                .warning,
                "Your clock is \(abs(steamTimeOffset))s off Steam's. Codes are corrected for this, "
                    + "but enabling automatic time sync in System Settings is worth doing."
            )
        }
    }

    // MARK: - Sessions

    /// Refreshes any access token that has expired, and warns when a refresh
    /// token is close to running out (at which point a full login is needed).
    func refreshSessionsIfNeeded() async {
        for index in accounts.indices {
            guard let session = accounts[index].session else { continue }
            guard session.isAccessTokenExpired, !session.isRefreshTokenExpired else { continue }

            do {
                let refreshed = try await SteamLogin.refreshAccessToken(
                    session: session,
                    allowRenewal: session.isRefreshTokenAboutToExpire
                )
                accounts[index].session = refreshed
                try store.save(accounts[index], passphrase: passphrase)
            } catch {
                show(
                    .warning,
                    "Could not refresh the session for \(accounts[index].accountName ?? "an account"). "
                        + "Use Account ▸ Log in again."
                )
            }
        }
    }

    /// Forces a token refresh for one account, the equivalent of SDA's
    /// "Force session refresh".
    func forceRefreshSession(for account: SteamGuardAccount) async {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }),
              let session = accounts[index].session
        else { return }

        do {
            let refreshed = try await SteamLogin.refreshAccessToken(session: session, allowRenewal: true)
            accounts[index].session = refreshed
            try store.save(accounts[index], passphrase: passphrase)
            show(.success, "Session refreshed.")
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    // MARK: - Confirmations

    func loadConfirmations(for account: SteamGuardAccount) async {
        isLoadingConfirmations = true
        defer { isLoadingConfirmations = false }

        await refreshSessionsIfNeeded()
        let current = accounts.first { $0.id == account.id } ?? account

        do {
            confirmations = try await current.fetchConfirmations()
            pendingCounts[current.id] = confirmations.count
        } catch {
            confirmations = []
            show(.error, error.localizedDescription)
        }
    }

    func act(on confirmation: Confirmation, accept: Bool) async {
        guard let account = selectedAccount else { return }
        do {
            if accept {
                try await account.accept(confirmation)
            } else {
                try await account.deny(confirmation)
            }
            confirmations.removeAll { $0.id == confirmation.id }
            pendingCounts[account.id] = confirmations.count
            show(.success, accept ? "Confirmed." : "Cancelled.")
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func actOnAll(accept: Bool) async {
        guard let account = selectedAccount, !confirmations.isEmpty else { return }
        let all = confirmations
        do {
            if accept {
                try await account.accept(all)
            } else {
                try await account.deny(all)
            }
            confirmations = []
            pendingCounts[account.id] = 0
            show(.success, accept ? "Confirmed \(all.count)." : "Cancelled \(all.count).")
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    // MARK: - Periodic checking

    func restartCheckTimer() {
        checkTimer?.invalidate()
        guard settings.periodicChecking else { return }

        let interval = TimeInterval(max(5, settings.periodicCheckingInterval))
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runPeriodicCheck() }
        }
    }

    /// Polls for confirmations in the background, auto-accepting the categories
    /// the user opted into and notifying about the rest.
    private func runPeriodicCheck() async {
        guard lockState == .unlocked else { return }

        let targets = settings.checkAllAccounts
            ? accounts
            : [selectedAccount].compactMap { $0 }

        for account in targets {
            guard account.session != nil else { continue }

            do {
                let pending = try await account.fetchConfirmations()
                pendingCounts[account.id] = pending.count
                guard !pending.isEmpty else { continue }

                let autoAccept = pending.filter { confirmation in
                    switch confirmation.type {
                    case .trade: return settings.autoConfirmTrades
                    case .marketListing: return settings.autoConfirmMarketTransactions
                    default: return false
                    }
                }

                if !autoAccept.isEmpty {
                    try await account.accept(autoAccept)
                    await notify(
                        title: "Auto-confirmed \(autoAccept.count) item\(autoAccept.count == 1 ? "" : "s")",
                        body: account.accountName ?? ""
                    )
                    for confirmation in autoAccept { notifiedConfirmationIDs.insert(confirmation.id) }
                }

                let remaining = pending.filter { confirmation in
                    !autoAccept.contains { $0.id == confirmation.id }
                        && !notifiedConfirmationIDs.contains(confirmation.id)
                }

                for confirmation in remaining {
                    notifiedConfirmationIDs.insert(confirmation.id)
                    await notify(
                        title: confirmation.headline,
                        body: ([account.accountName ?? ""] + confirmation.summary)
                            .filter { !$0.isEmpty }
                            .joined(separator: " — ")
                    )
                }

                if account.id == selectedAccount?.id {
                    confirmations = pending.filter { pendingItem in
                        !autoAccept.contains { $0.id == pendingItem.id }
                    }
                }
            } catch {
                // Background polling stays quiet: a transient failure here should
                // not interrupt whatever the user is doing.
                continue
            }
        }
    }

    // MARK: - Settings

    func updateSettings(_ mutate: (inout Manifest) -> Void) {
        do {
            try store.updateSettings(mutate)
            settings = store.manifest
            restartCheckTimer()
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    // MARK: - Account management

    /// Saves a freshly linked or re-authenticated account.
    func save(_ account: SteamGuardAccount) {
        do {
            try store.save(account, passphrase: passphrase)
            if let index = accounts.firstIndex(where: { $0.session?.steamID == account.session?.steamID }) {
                accounts[index] = account
            } else {
                accounts.append(account)
            }
            settings = store.manifest
            selectedAccountID = account.id
            lockState = .unlocked
            updateCode()
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    /// Removes the account from this app only; Steam still has the authenticator.
    func forget(_ account: SteamGuardAccount) {
        guard let steamID = account.session?.steamID else { return }
        do {
            try store.forget(steamID: steamID)
            accounts.removeAll { $0.id == account.id }
            settings = store.manifest
            selectedAccountID = accounts.first?.id
            if accounts.isEmpty { lockState = .empty }
            updateCode()
            show(.info, "Removed from this app. Steam still has the authenticator active.")
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    /// Removes the authenticator from the Steam account itself.
    func deactivate(_ account: SteamGuardAccount, scheme: Int) async -> Bool {
        do {
            let removed = try await AuthenticatorLinker.deactivate(account: account, scheme: scheme)
            if removed {
                forget(account)
                show(.success, "Authenticator removed from Steam.")
            } else {
                show(.error, "Steam did not remove the authenticator.")
            }
            return removed
        } catch {
            show(.error, error.localizedDescription)
            return false
        }
    }

    func changeEncryption(current: String?, new: String?, remember: Bool) -> Bool {
        do {
            try store.changeEncryption(currentPassphrase: current, newPassphrase: new)
            passphrase = new
            settings = store.manifest

            if let new, remember {
                _ = Keychain.save(passphrase: new)
            } else {
                Keychain.delete()
            }

            show(.success, new == nil ? "Encryption removed." : "Encryption updated.")
            return true
        } catch {
            show(.error, error.localizedDescription)
            return false
        }
    }

    func importMaFile(at url: URL, sourcePassphrase: String?, salt: String?, iv: String?) {
        do {
            let account = try store.importMaFile(
                at: url,
                sourcePassphrase: sourcePassphrase,
                sourceSalt: salt,
                sourceIV: iv,
                storePassphrase: passphrase
            )
            accounts = try store.loadAccounts(passphrase: passphrase)
            settings = store.manifest
            selectedAccountID = account.id
            lockState = .unlocked
            updateCode()
            show(.success, "Imported \(account.accountName ?? "account").")
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    func importFolder(at url: URL, sourcePassphrase: String?) {
        do {
            let summary = try store.importFolder(
                at: url,
                sourcePassphrase: sourcePassphrase,
                storePassphrase: passphrase
            )
            accounts = try store.loadAccounts(passphrase: passphrase)
            settings = store.manifest
            selectedAccountID = accounts.first?.id
            lockState = accounts.isEmpty ? .empty : .unlocked
            updateCode()

            let count = summary.imported.count
            var message = "Imported \(count) account\(count == 1 ? "" : "s")."

            if !summary.skipped.isEmpty {
                // Name what was left behind, so a partial import is never silent.
                let names = summary.skipped.prefix(3).map(\.filename).joined(separator: ", ")
                let extra = summary.skipped.count > 3 ? " and \(summary.skipped.count - 3) more" : ""
                message += " Skipped \(names)\(extra): \(summary.skipped[0].reason)."
                show(.warning, message)
            } else {
                show(.success, message)
            }
        } catch {
            show(.error, error.localizedDescription)
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() async {
        // Only works from a signed bundle; ignore failures when run loose.
        guard Bundle.main.bundleIdentifier != nil else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    private func notify(title: String, body: String) async {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Banner

    func show(_ kind: Banner.Kind, _ message: String) {
        banner = Banner(kind: kind, message: message)
        let shown = banner?.id

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await MainActor.run {
                // Only clear it if nothing newer replaced it.
                if self?.banner?.id == shown { self?.banner = nil }
            }
        }
    }
}
