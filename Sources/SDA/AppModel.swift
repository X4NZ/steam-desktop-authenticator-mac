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
        /// The store exists but could not be read. Distinct from .empty on
        /// purpose: the welcome screen's main action links a new authenticator,
        /// which would invalidate the secrets sitting unreadable on disk.
        case failed(String)
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
    /// Manifest entries the last load could not turn into accounts. Published
    /// rather than read through to the store, which observes nothing, so the
    /// settings panel that offers to drop them cannot show a stale list.
    @Published var unreadableFiles: [String] = []

    struct Banner: Identifiable, Equatable {
        enum Kind { case info, success, warning, error }
        let id = UUID()
        var kind: Kind
        var message: String
    }

    // MARK: Internals

    private let store: AccountStore
    /// Not private: tests replace it to drive timing the live path cannot.
    var service: ConfirmationService
    /// Replaced in tests, which must not reach the real notification centre.
    var notifier: (@MainActor (String, String) async -> Void)?
    private var passphrase: String?
    private var codeTimer: Timer?
    private var checkTimer: Timer?
    /// Confirmation ids already surfaced, per account, so a notification fires
    /// only once. Keyed by account because one shared set meant each account's
    /// pruning pass threw away every other account's ids.
    private var notifiedConfirmationIDs: [String: Set<UInt64>] = [:]
    /// When the Steam clock offset was last re-checked from the timer.
    private var lastAlignCheck = Date()
    /// Guards against a slow check still running when the timer fires again.
    private var isRunningPeriodicCheck = false
    /// Why the last unlock attempt failed, for the failure screen.
    private var lastUnlockError: String?
    /// Replaces the previous banner's dismissal task rather than stacking one
    /// sleeping task per banner.
    private var bannerDismissTask: Task<Void, Never>?

    var storeDirectory: URL { store.directory }
    var isEncrypted: Bool { store.isEncrypted }
    var currentPassphrase: String? { passphrase }

    init(store: AccountStore = AccountStore(), service: ConfirmationService = .live) {
        self.store = store
        self.service = service
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
        } else if !unlock(passphrase: nil, remember: false) {
            // unlock() sets the state itself when it works. Forcing .unlocked
            // regardless used to paper over a failed load; sending it to .empty
            // instead offered to set up a new account over the top of it.
            lockState = .failed(lastUnlockError ?? "Your maFiles could not be read.")
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

            unreadableFiles = store.unreadableFiles
            if !unreadableFiles.isEmpty {
                let unreadable = unreadableFiles
                let names = unreadable.prefix(3).joined(separator: ", ")
                let extra = unreadable.count > 3 ? " and \(unreadable.count - 3) more" : ""
                show(
                    .warning,
                    "\(names)\(extra) could not be read, so those accounts are not shown. "
                        + "The rest loaded normally."
                )
            }
            return true
        } catch {
            lastUnlockError = error.localizedDescription
            unreadableFiles = store.unreadableFiles

            // A wrong or absent passphrase is reported inline by the unlock
            // screen. Everything else used to vanish entirely.
            if case CryptoError.wrongPassword = error {
                return false
            }
            if case StoreError.passphraseRequired = error {
                return false
            }
            show(.error, error.localizedDescription)
            return false
        }
    }

    /// What the unlock screen should do after a biometric attempt.
    enum BiometricOutcome {
        case unlocked
        /// Offer the passphrase field: either the user asked for it, or
        /// biometrics cannot serve here at all.
        case needsPassphrase
        /// Leave the prompt on offer so they can try again.
        case retry
    }

    /// Asks for Touch ID, then unlocks with the stored passphrase.
    func unlockWithBiometrics() async -> BiometricOutcome {
        let result = await Keychain.load(
            reason: "unlock your Steam authenticator accounts"
        )

        switch result {
        case .success(let passphrase):
            if unlock(passphrase: passphrase, remember: false) {
                lockState = .unlocked
                return .unlocked
            }
            // The stored passphrase no longer matches the files, so biometrics
            // cannot open them however many times it is tried.
            show(.error, "The saved passphrase did not unlock your maFiles.")
            return .needsPassphrase

        case .failure(let error):
            if let message = error.errorDescription { show(.error, message) }

            switch error {
            case .declined, .notFound, .unavailable:
                return .needsPassphrase
            case .interrupted, .authenticationFailed:
                return .retry
            }
        }
    }

    /// Checks a passphrase against the stored files without changing anything.
    func verifyPassphrase(_ candidate: String) -> Bool {
        let verified = store.verify(passphrase: candidate)
        // verify() runs a whole load, so the store's diagnostics moved. Only
        // a successful one is worth publishing: a typo clears the damage list
        // without repopulating it, which would hide the panel that offers the
        // only route to dropping a damaged entry.
        if verified { unreadableFiles = store.unreadableFiles }
        return verified
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

    /// True while the account this work was started for is still the one on
    /// screen. Clearing the list on a switch is not enough on its own: a fetch
    /// already in flight would otherwise write the old account's confirmations
    /// back into the list, under the new account's name and key.
    private func isStillSelected(_ id: String) -> Bool {
        selectedAccount?.id == id
    }

    func loadConfirmations(for account: SteamGuardAccount) async {
        let requested = account.id
        isLoadingConfirmations = true
        defer { if isStillSelected(requested) { isLoadingConfirmations = false } }

        await refreshSessionsIfNeeded()
        guard isStillSelected(requested) else { return }
        let current = accounts.first { $0.id == requested } ?? account

        do {
            let fetched = try await service.fetch(current)
            pendingCounts[requested] = fetched.count
            guard isStillSelected(requested) else { return }
            confirmations = fetched
        } catch {
            guard isStillSelected(requested) else { return }
            confirmations = []
            show(.error, error.localizedDescription)
        }
    }

    func act(on confirmation: Confirmation, accept: Bool) async {
        guard let account = selectedAccount else { return }
        let owner = account.id
        do {
            try await service.send(account, [confirmation], accept)
            if isStillSelected(owner) {
                confirmations.removeAll { $0.id == confirmation.id }
                pendingCounts[owner] = confirmations.count
                show(.success, accept ? "Confirmed." : "Cancelled.")
            } else {
                // Steam accepted it even though the user has moved on, so the
                // badge must stop advertising it. Only the visible list and the
                // banner depend on what is selected.
                pendingCounts[owner] = max(0, (pendingCounts[owner] ?? 1) - 1)
            }
        } catch {
            // Worth surfacing only while they are still looking at it.
            if isStillSelected(owner) { show(.error, error.localizedDescription) }
        }
    }

    func actOnAll(accept: Bool) async {
        guard let account = selectedAccount, !confirmations.isEmpty else { return }
        let owner = account.id
        let all = confirmations
        do {
            try await service.send(account, all, accept)
            // Owner-keyed, so it holds whether or not the selection moved.
            pendingCounts[owner] = 0
            guard isStillSelected(owner) else { return }
            confirmations = []
            show(.success, accept ? "Confirmed \(all.count)." : "Cancelled \(all.count).")
        } catch {
            if isStillSelected(owner) { show(.error, error.localizedDescription) }
        }
    }

    // MARK: - Periodic checking

    func restartCheckTimer() {
        checkTimer?.invalidate()
        guard settings.periodicChecking else { return }

        let interval = TimeInterval(max(10, settings.periodicCheckingInterval))
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runPeriodicCheck() }
        }
    }

    /// Polls for confirmations in the background, auto-accepting the categories
    /// the user opted into and notifying about the rest.
    /// Not private so tests can run a cycle without waiting on the timer.
    func runPeriodicCheck() async {
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
                let pending = try await service.fetch(account)
                guard !pending.isEmpty else {
                    pendingCounts[account.id] = 0
                    continue
                }

                let autoAccept = pending.filter { confirmation in
                    switch confirmation.type {
                    case .trade: return settings.autoConfirmTrades
                    case .marketListing: return settings.autoConfirmMarketTransactions
                    default: return false
                    }
                }

                if !autoAccept.isEmpty {
                    try await service.send(account, autoAccept, true)
                    await notify(
                        title: "Auto-confirmed \(autoAccept.count) item\(autoAccept.count == 1 ? "" : "s")",
                        body: account.accountName ?? ""
                    )
                    for confirmation in autoAccept {
                        notifiedConfirmationIDs[account.id, default: []].insert(confirmation.id)
                    }
                }

                var notified = notifiedConfirmationIDs[account.id] ?? []

                let remaining = pending.filter { confirmation in
                    !autoAccept.contains { $0.id == confirmation.id }
                        && !notified.contains(confirmation.id)
                }

                for confirmation in remaining {
                    notified.insert(confirmation.id)
                    await notify(
                        title: confirmation.headline,
                        body: ([account.accountName ?? ""] + confirmation.summary)
                            .filter { !$0.isEmpty }
                            .joined(separator: " — ")
                    )
                }

                let outstanding = pending.filter { pendingItem in
                    !autoAccept.contains { $0.id == pendingItem.id }
                }
                // Counted after auto-accept, not before: the badge used to keep
                // advertising items this pass had already confirmed.
                pendingCounts[account.id] = outstanding.count

                if account.id == selectedAccount?.id {
                    confirmations = outstanding
                }
                // Forget ids that are no longer pending, so this set tracks
                // what is outstanding rather than growing without limit. Scoped
                // to this account: pruning the shared set inside the loop used
                // to drop the other accounts' ids and re-notify them next pass.
                let stillPending = Set(pending.map(\.id))
                notifiedConfirmationIDs[account.id] = notified.intersection(
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

    /// Drops manifest entries for files that could not be read.
    ///
    /// Without this a permanently lost maFile blocks every passphrase change,
    /// with an error telling the user to restore a file that is gone.
    func forgetUnreadableEntries() {
        do {
            let dropped = try store.forgetUnreadableEntries()
            guard !dropped.isEmpty else { return }
            settings = store.manifest
            unreadableFiles = store.unreadableFiles

            // The point of this is to rescue a store that would not load, so
            // the lock state has to be re-examined. Leaving it alone kept the
            // unlock screen asking for a passphrase to open entries that are
            // no longer there.
            if store.manifest.entries.isEmpty {
                accounts = []
                confirmations = []
                passphrase = nil
                selectedAccountID = nil
                lockState = .empty
            } else if case .failed = lockState {
                _ = unlock(passphrase: nil, remember: false)
            }

            show(.info, "Removed \(dropped.count) unreadable entr\(dropped.count == 1 ? "y" : "ies") "
                + "from manifest.json. The files themselves were left alone, and "
                + "manifest.json.bak holds the previous version.")
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
            // Otherwise its badge count kept inflating the menu bar total for
            // the rest of the session.
            pendingCounts.removeValue(forKey: account.id)
            notifiedConfirmationIDs.removeValue(forKey: account.id)
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
        if let notifier {
            await notifier(title, body)
            return
        }
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

/// The Steam side of confirmations, behind a seam.
///
/// Injected so tests can drive the timing these methods exist to get right: a
/// fetch still in flight when the user switches account, and notifications
/// that must fire once per account rather than once per polling cycle. Neither
/// is reachable through the live implementation without a Steam session.
struct ConfirmationService {
    var fetch: (SteamGuardAccount) async throws -> [Confirmation]
    var send: (SteamGuardAccount, [Confirmation], Bool) async throws -> Void

    static let live = ConfirmationService(
        fetch: { try await $0.fetchConfirmations() },
        send: { account, items, accept in
            if accept {
                try await account.accept(items)
            } else {
                try await account.deny(items)
            }
        }
    )
}
