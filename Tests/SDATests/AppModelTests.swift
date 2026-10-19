import Foundation
import SteamAuthKit
import Testing

@testable import SDA

/// Covers the AppModel defects from the review passes, which until now had no
/// test because the app target was not in any test target.
@MainActor
struct AppModelTests {

    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sda-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ directory: URL, accounts: UInt64) throws -> AccountStore {
        let store = AccountStore(directory: directory)
        try store.loadManifest()
        for steamID in 1 ... accounts {
            var account = SteamGuardAccount()
            account.accountName = "account\(steamID)"
            account.sharedSecret = "zvIayp3JPvtvX/QGHqsqKBk/44s="
            account.session = SessionData(
                steamID: steamID,
                accessToken: "token",
                refreshToken: "refresh"
            )
            try store.save(account, passphrase: nil)
        }
        return store
    }

    private func confirmation(id: UInt64, type: Int = 2) throws -> SteamAuthKit.Confirmation {
        let json = """
        {"id":"\(id)","nonce":"\(id)","creator_id":"1","headline":"Trade",
         "summary":["an item"],"accept":"Confirm","cancel":"Cancel","type":\(type)}
        """
        return try JSONDecoder().decode(SteamAuthKit.Confirmation.self, from: Data(json.utf8))
    }

    /// Loads a model straight from a store, without start()'s network work.
    private func unlockedModel(
        _ store: AccountStore,
        service: ConfirmationService = .live
    ) -> AppModel {
        let model = AppModel(store: store, service: service)
        #expect(model.unlock(passphrase: nil, remember: false))
        return model
    }

    // MARK: - Confirmations belonging to the account that asked for them

    @Test("A fetch that lands after the user switches account is dropped")
    func staleConfirmationsAreNotShownUnderAnotherAccount() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try self.store(directory, accounts: 2)

        let model = unlockedModel(store)
        let first = model.accounts[0]
        let second = model.accounts[1]
        model.selectedAccountID = first.id

        // The switch happens while the fetch is in flight, which is the whole
        // point: clearing the list on the switch alone let this result land
        // afterwards, under the other account's name and signing key.
        model.service = ConfirmationService(
            fetch: { [weak model] _ in
                model?.selectedAccountID = second.id
                return [try self.confirmation(id: 99)]
            },
            send: { _, _, _ in }
        )

        await model.loadConfirmations(for: first)

        #expect(model.selectedAccountID == second.id)
        #expect(model.confirmations.isEmpty, "these belong to the account left behind")
        // The count is keyed by owner, so it is still worth recording.
        #expect(model.pendingCounts[first.id] == 1)
    }

    @Test("A fetch for the account still on screen is shown")
    func freshConfirmationsAreShown() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try self.store(directory, accounts: 2)

        let model = unlockedModel(store)
        let first = model.accounts[0]
        model.selectedAccountID = first.id
        model.service = ConfirmationService(
            fetch: { _ in [try self.confirmation(id: 7)] },
            send: { _, _, _ in }
        )

        await model.loadConfirmations(for: first)
        #expect(model.confirmations.map(\.id) == [7])
        #expect(model.pendingCounts[first.id] == 1)
    }

    @Test("An accepted confirmation still clears its badge after a switch")
    func actingUpdatesTheOwnersBadgeEvenAfterASwitch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try self.store(directory, accounts: 2)

        let model = unlockedModel(store)
        let first = model.accounts[0]
        let second = model.accounts[1]
        model.selectedAccountID = first.id
        model.confirmations = [try confirmation(id: 5)]
        model.pendingCounts[first.id] = 1

        model.service = ConfirmationService(
            fetch: { _ in [] },
            send: { [weak model] _, _, _ in
                // Steam accepted it; the user has already moved on.
                model?.selectedAccountID = second.id
            }
        )

        await model.act(on: try confirmation(id: 5), accept: true)

        // It went through, so the badge must stop advertising it even though
        // the list on screen now belongs to someone else.
        #expect(model.pendingCounts[first.id] == 0)
    }

    // MARK: - Notifications remembered per account

    @Test("A pending confirmation is notified once, not once per cycle")
    func notificationsAreRememberedPerAccount() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try self.store(directory, accounts: 2)

        let model = unlockedModel(store)
        model.updateSettings { $0.checkAllAccounts = true }

        // One outstanding item each. A single shared set was pruned inside the
        // loop over accounts, so each account threw away the other's ids and
        // both were announced again on every pass.
        let perAccount: [String: [SteamAuthKit.Confirmation]] = [
            model.accounts[0].id: [try confirmation(id: 1)],
            model.accounts[1].id: [try confirmation(id: 2)],
        ]
        model.service = ConfirmationService(
            fetch: { perAccount[$0.id] ?? [] },
            send: { _, _, _ in }
        )

        var announced: [String] = []
        model.notifier = { title, _ in announced.append(title) }

        await model.runPeriodicCheck()
        #expect(announced.count == 2, "one per account")

        announced.removeAll()
        await model.runPeriodicCheck()
        #expect(announced.isEmpty, "nothing new is pending")

        announced.removeAll()
        await model.runPeriodicCheck()
        #expect(announced.isEmpty)
    }

    @Test("Badges count what is still outstanding after auto-accept")
    func badgeExcludesWhatWasJustAutoConfirmed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try self.store(directory, accounts: 1)

        let model = unlockedModel(store)
        model.updateSettings { $0.autoConfirmTrades = true }
        let account = model.accounts[0]
        model.selectedAccountID = account.id

        // A trade, which is auto-confirmed, and a market listing, which is not.
        model.service = ConfirmationService(
            fetch: { _ in [try self.confirmation(id: 1, type: 2), try self.confirmation(id: 2, type: 3)] },
            send: { _, _, _ in }
        )
        model.notifier = { _, _ in }

        await model.runPeriodicCheck()

        // Counted before auto-accept, this used to keep advertising the trade
        // the same pass had already confirmed.
        #expect(model.pendingCounts[account.id] == 1)
        #expect(model.confirmations.map(\.id) == [2])
    }

    // MARK: - Lock state

    @Test("A store that cannot be read does not look like an empty one")
    func unreadableStoreReportsItself() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try self.store(directory, accounts: 1)

        // Corrupt the only account's file, unencrypted.
        try Data("not json".utf8).write(to: directory.appendingPathComponent("1.maFile"))

        let reopened = AccountStore(directory: directory)
        let model = AppModel(store: reopened)
        await model.start()

        // Forcing .unlocked used to show an empty main window; sending it to
        // .empty offered to set up a new account over the top of secrets that
        // are still on disk, which would replace the authenticator on Steam.
        guard case .failed(let message) = model.lockState else {
            Issue.record("expected .failed, got \(model.lockState)")
            return
        }
        #expect(message.contains("1.maFile"))
        #expect(model.unreadableFiles == ["1.maFile"])
    }

    @Test("Forgetting an account takes its badge with it")
    func forgettingClearsTheBadge() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try self.store(directory, accounts: 2)

        let model = unlockedModel(store)
        let doomed = model.accounts[0]
        model.pendingCounts[doomed.id] = 3

        model.forget(doomed)

        // It used to linger and keep inflating the menu bar total.
        #expect(model.pendingCounts[doomed.id] == nil)
        #expect(model.accounts.count == 1)
    }
}
