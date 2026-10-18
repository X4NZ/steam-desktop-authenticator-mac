import AppUpdater
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
    @Published var selectedAccountID: String? {
        didSet {
            guard oldValue != selectedAccountID else { return }
            // Both of these belong to the account being left behind. Acting on a
            // stale confirmation would send it under the newly selected account.
            confirmations = []
            isLoadingConfirmations = false
            updateCode()
        }
    }
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
    /// Set when a newer release is found, which presents the update sheet.
    @Published var availableUpdate: Updater.Release?
    @Published var isCheckingForUpdate = false

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
    /// When the Steam clock offset was last re-checked from the timer.
    private var lastAlignCheck = Date()
    /// Guards against a slow check still running when the timer fires again.
    private var isRunningPeriodicCheck = false
    /// Replaces the previous banner's dismissal task rather than stacking one
    /// sleeping task per banner.
    private var bannerDismissTask: Task<Void, Never>?

    var storeDirectory: URL { store.directory }
    var isEncrypted: Bool { store.isEncrypted }
    var currentPassphrase: String? { passphrase }

    init(store: AccountStore = AccountStore()) {
        self.store = store
    }

    deinit {
        codeTimer?.invalidate()
        checkTimer?.invalidate()
        bannerDismissTask?.cancel()
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
            // A plain keychain entry can open the store unattended. A Touch ID
            // protected one must not prompt behind the user's back, so that goes
            // through the unlock screen instead.
            if Keychain.storedProtection == .plain,
               let saved = Keychain.loadUnprotected(),
               unlock(passphrase: saved, remember: false) {
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

        await checkForUpdate(silently: true)
    }

    // MARK: - Updates

    /// A silent check runs at launch and says nothing unless there is an
    /// update; an explicit one reports "you are up to date" too.
    func checkForUpdate(silently: Bool) async {
        guard !isCheckingForUpdate else { return }
        if silently, !shouldAutoCheck() { return }

        isCheckingForUpdate = true
        defer { isCheckingForUpdate = false }

        do {
            let release = try await Updater.checkForUpdate()
            UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckKey)

            if let release {
                availableUpdate = release
            } else if !silently {
                show(.success, "You are on the latest version (\(Updater.currentVersion)).")
            }
        } catch {
            if !silently { show(.error, error.localizedDescription) }
        }
    }

    private static let lastUpdateCheckKey = "lastUpdateCheck"

    /// At most one automatic check a day, so launching repeatedly does not
    /// hammer the API and burn the unauthenticated rate limit.
    private func shouldAutoCheck() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.lastUpdateCheckKey) as? Date
        else { return true }
        return Date().timeIntervalSince(last) > 24 * 60 * 60
    }

    /// Loads and decrypts the accounts. Returns false on a wrong passphrase.
    @discardableResult
    func unlock(
        passphrase candidate: String?,
        remember: Bool,
        protection: Keychain.Protection = .plain
    ) -> Bool {
        do {
            accounts = try store.loadAccounts(passphrase: candidate)
            passphrase = candidate
            settings = store.manifest

            if selectedAccountID == nil { selectedAccountID = accounts.first?.id }
            if remember, let candidate {
                Keychain.save(passphrase: candidate, protection: protection)
            }

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

    /// Asks for Touch ID, then unlocks with the stored passphrase.
    ///
    /// Returns false when there is nothing stored or the user backed out, so the
    /// unlock screen can fall back to asking for the passphrase.
    func unlockWithBiometrics() async -> Bool {
        let result = await Keychain.load(
            reason: "unlock your Steam authenticator accounts"
        )

        switch result {
        case .success(let passphrase):
            if unlock(passphrase: passphrase, remember: false) {
                lockState = .unlocked
                return true
            }
            // The stored passphrase no longer matches the files.
            show(.error, "The saved passphrase did not unlock your maFiles.")
            return false

        case .failure(let error):
            if let message = error.errorDescription { show(.error, message) }
            return false
        }
    }

    /// Checks a passphrase against the stored files without changing anything.
    func verifyPassphrase(_ candidate: String) -> Bool {
        store.verify(passphrase: candidate)
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
            Task { @MainActor in
                guard let self else { return }
                self.updateCode()

                // The offset is measured at launch; re-check occasionally so a
                // long session or a sleep/wake cycle cannot drift out of the
                // 30-second window.
                if Date().timeIntervalSince(self.lastAlignCheck) > 300 {
                    self.lastAlignCheck = Date()
                    await SteamTime.shared.alignIfStale()
                    self.steamTimeOffset = await SteamTime.shared.currentOffset
                }
            }
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
        guard !isRunningPeriodicCheck else { return }
        isRunningPeriodicCheck = true
        defer { isRunningPeriodicCheck = false }

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
                // Forget ids that are no longer pending, so this set tracks
                // what is outstanding rather than growing without limit.
                let stillPending = Set(pending.map(\.id))
                notifiedConfirmationIDs.formIntersection(
                    stillPending.union(autoAccept.map(\.id))
                )
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

    func changeEncryption(
        current: String?,
        new: String?,
        remember: Bool,
        protection: Keychain.Protection = .plain
    ) -> Bool {
        do {
            try store.changeEncryption(currentPassphrase: current, newPassphrase: new)
            passphrase = new
            settings = store.manifest

            if let new, remember {
                Keychain.save(passphrase: new, protection: protection)
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

        bannerDismissTask?.cancel()
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            // Only clear it if nothing newer replaced it.
            if self?.banner?.id == shown { self?.banner = nil }
        }
    }
}
