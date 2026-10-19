import SteamAuthKit
import SwiftUI

/// Steam login, and the full authenticator-linking wizard that follows it.
///
/// The ordering here matters for safety: once `addAuthenticator` returns, Steam
/// has already issued the secrets, so they are written to disk and the
/// revocation code is shown *before* finalization is attempted. Losing them
/// between those two steps would mean losing the account.
struct LoginSheet: View {
    enum Reason: Equatable {
        /// Link a new authenticator to an account.
        case setup
        /// Re-authenticate an account already in the list.
        case refresh(SteamGuardAccount)

        var existingAccount: SteamGuardAccount? {
            if case .refresh(let account) = self { return account }
            return nil
        }
    }

    enum Step: Equatable {
        case credentials
        case guardCode(SteamLogin.Challenge, SteamLogin.GuardType)
        case awaitingApproval(SteamLogin.Challenge)
        case phoneNumber
        case emailConfirmation(address: String?)
        case verifyPhoneSMS
        case revocationCode(String?)
        case finalize
        case finished

        static func == (lhs: Step, rhs: Step) -> Bool {
            String(describing: lhs) == String(describing: rhs)
        }
    }

    let reason: Reason

    init(reason: Reason) {
        self.reason = reason
        // Seeded here rather than in onAppear: relying on that fired after the
        // field had already been rendered, and could leave it empty.
        _username = State(initialValue: reason.existingAccount?.accountName ?? "")
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .credentials
    @State private var username: String
    @State private var password = ""
    @State private var code = ""
    @State private var phoneNumber = ""
    @State private var smsCode = ""
    @State private var revocationAcknowledged = false
    @State private var busy = false
    @State private var errorMessage: String?

    @State private var linker: AuthenticatorLinker?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            Divider()

            footer
        }
        .frame(width: 460)
        .frame(minHeight: 300)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.badge.key")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button(step == .finished ? "Done" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            primaryButton
        }
        .padding(16)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .credentials:
            Button("Log In") { Task { await beginLogin() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || username.isEmpty || password.isEmpty)

        case .guardCode(let challenge, let type):
            Button("Continue") { Task { await submitGuardCode(challenge, type) } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || code.count < 5)

        case .awaitingApproval:
            EmptyView()

        case .phoneNumber:
            Button("Add Phone Number") { Task { await addPhone() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || phoneNumber.count < 7)

        case .emailConfirmation:
            Button("I Clicked the Link") { Task { await afterEmailConfirmation() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)

        case .verifyPhoneSMS:
            Button("Verify Phone") { Task { await verifyPhone() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || smsCode.isEmpty)

        case .revocationCode:
            Button("I Have Saved It") { step = .finalize }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!revocationAcknowledged)

        case .finalize:
            Button("Finish Setup") { Task { await finalize() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || smsCode.isEmpty)

        case .finished:
            EmptyView()
        }
    }

    private var title: String {
        switch step {
        case .credentials:
            return reason.existingAccount == nil ? "Set up a new account" : "Log in again"
        case .guardCode, .awaitingApproval: return "Steam Guard"
        case .phoneNumber, .emailConfirmation, .verifyPhoneSMS: return "Phone verification"
        case .revocationCode: return "Save your revocation code"
        case .finalize: return "Finish setup"
        case .finished: return "All set"
        }
    }

    private var subtitle: String {
        switch step {
        case .credentials:
            return "Your password is encrypted with Steam's key and never stored."
        case .guardCode: return "Steam wants a second factor."
        case .awaitingApproval: return "Waiting for you to approve on your phone."
        case .phoneNumber: return "Steam requires a phone number before linking."
        case .emailConfirmation: return "Steam sent you a confirmation email."
        case .verifyPhoneSMS: return "Enter the code Steam texted you."
        case .revocationCode: return "This is the only way back if you lose this Mac."
        case .finalize: return "Enter the SMS code to activate the authenticator."
        case .finished: return ""
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .credentials:
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Account name") {
                    TextField("", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .disabled(lockedToStoredAccount)
                }
                LabeledContent("Password") {
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await beginLogin() } }
                }

                if reason.existingAccount == nil {
                    WarningBox().padding(.top, 6)
                }
            }

        case .guardCode(_, let type):
            VStack(alignment: .leading, spacing: 10) {
                Text(guardPrompt(for: type))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .monospaced))
                    .frame(width: 160)
            }

        case .awaitingApproval:
            HStack(spacing: 12) {
                ProgressView()
                Text("Approve the login in your Steam mobile app.")
                    .font(.callout)
            }

        case .phoneNumber:
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Steam will only add an authenticator to an account with a verified phone "
                    + "number. Enter it in international format."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                TextField("+15551234567", text: $phoneNumber)
                    .textFieldStyle(.roundedBorder)
            }

        case .emailConfirmation(let address):
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    address.map { "Steam sent a confirmation link to \($0)." }
                        ?? "Steam sent you a confirmation link."
                )
                .font(.callout)
                Text("Click that link, then continue here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .verifyPhoneSMS:
            VStack(alignment: .leading, spacing: 10) {
                Text("Enter the code Steam texted to your phone.")
                    .font(.callout)
                TextField("SMS code", text: $smsCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }

        case .revocationCode(let revocationCode):
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Write this down somewhere off this computer. If you lose your maFiles, "
                    + "this code is the only way to remove the authenticator and recover the account."
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

                Text(revocationCode ?? "—")
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

                Toggle("I have written down my revocation code", isOn: $revocationAcknowledged)

                Text("Your account has already been saved to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .finalize:
            VStack(alignment: .leading, spacing: 10) {
                Text("Steam texted an activation code to your phone. Enter it to switch your account over.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("SMS code", text: $smsCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)

                CalloutBox(
                    kind: .info,
                    title: "Trading will pause for a few days",
                    message: "Steam restricts trades for a while after an authenticator moves devices."
                )
            }

        case .finished:
            VStack(alignment: .leading, spacing: 10) {
                Label("Your authenticator is active on this Mac.", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                Text("Back up your maFiles folder and keep your revocation code safe.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func guardPrompt(for type: SteamLogin.GuardType) -> String {
        switch type {
        case .emailCode:
            return "Steam emailed you a code. Enter it below."
        case .deviceCode:
            return "Enter the current code from your existing Steam authenticator."
        default:
            return "Enter your Steam Guard code."
        }
    }

    // MARK: - Actions

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        errorMessage = nil
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }

    /// True only when the account name is known, and therefore not editable.
    private var lockedToStoredAccount: Bool {
        reason.existingAccount?.accountName?.isEmpty == false
    }

    private func beginLogin() async {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            errorMessage = "Enter your Steam account name."
            return
        }
        guard !password.isEmpty else {
            errorMessage = "Enter your Steam password."
            return
        }

        await run {
            let challenge = try await SteamLogin.begin(accountName: name, password: password)
            // The password is no longer needed; drop it from memory.
            password = ""

            switch challenge.requiredGuard {
            case .deviceCode where reason.existingAccount != nil:
                // We hold this account's secret, so the code can be supplied
                // automatically rather than asking the user to read it back.
                if let account = reason.existingAccount,
                   let generated = await account.generateCode() {
                    try await SteamLogin.submitGuardCode(
                        challenge: challenge, code: generated, type: .deviceCode
                    )
                    try await completeLogin(challenge: challenge)
                } else {
                    step = .guardCode(challenge, .deviceCode)
                }

            case .deviceCode:
                step = .guardCode(challenge, .deviceCode)

            case .emailCode:
                step = .guardCode(challenge, .emailCode)

            case .deviceConfirmation, .emailConfirmation:
                // No nested run{}: the outer one already owns busy and the error
                // message for the whole attempt.
                step = .awaitingApproval(challenge)
                let credentials = try await SteamLogin.pollUntilConfirmed(challenge: challenge)
                try await proceed(with: credentials)

            case .none, .unknown, .machineToken, .legacyMachineAuth:
                try await completeLogin(challenge: challenge)
            }
        }
    }

    private func submitGuardCode(_ challenge: SteamLogin.Challenge, _ type: SteamLogin.GuardType) async {
        await run {
            try await SteamLogin.submitGuardCode(challenge: challenge, code: code, type: type)
            code = ""
            try await completeLogin(challenge: challenge)
        }
    }

    private func completeLogin(challenge: SteamLogin.Challenge) async throws {
        let credentials = try await SteamLogin.pollUntilConfirmed(challenge: challenge, timeout: 30)
        try await proceed(with: credentials)
    }

    /// Branches between simply refreshing an existing account's session and
    /// starting the link flow for a brand-new one.
    private func proceed(with credentials: SteamLogin.Credentials) async throws {
        var newSession = SessionData(
            steamID: credentials.steamID,
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken
        )
        if newSession.accessToken?.isEmpty != false {
            newSession = try await SteamLogin.refreshAccessToken(session: newSession)
        }

        if var account = reason.existingAccount {
            account.session = newSession
            model.save(account)
            step = .finished
            model.show(.success, "Logged back in as \(account.accountName ?? username).")
            return
        }

        let newLinker = AuthenticatorLinker(session: newSession)
        linker = newLinker

        let status = try await newLinker.phoneStatus()
        if status.verified {
            try await addAuthenticator()
        } else {
            step = .phoneNumber
        }
    }

    private func addPhone() async {
        guard let linker else { return }
        await run {
            let result = try await linker.addPhoneNumber(phoneNumber)
            switch result {
            case .ready:
                try await addAuthenticator()
            case .needsEmailConfirmation(let address):
                step = .emailConfirmation(address: address)
            case .needsSMSCode:
                step = .verifyPhoneSMS
            case .needsPhoneNumber:
                errorMessage = "Steam would not accept that phone number."
            }
        }
    }

    private func afterEmailConfirmation() async {
        guard let linker else { return }
        await run {
            let result = try await linker.continueAfterEmailConfirmation()
            switch result {
            case .needsSMSCode:
                smsCode = ""
                step = .verifyPhoneSMS
            case .needsEmailConfirmation(let address):
                step = .emailConfirmation(address: address)
                errorMessage = "Steam is still waiting on that email confirmation."
            case .ready:
                try await addAuthenticator()
            case .needsPhoneNumber:
                step = .phoneNumber
            }
        }
    }

    private func verifyPhone() async {
        guard let linker else { return }
        await run {
            _ = try await linker.verifyPhone(code: smsCode)
            smsCode = ""
            try await addAuthenticator()
        }
    }

    /// Asks Steam for the secrets, then saves them immediately.
    private func addAuthenticator() async throws {
        guard let linker else { return }

        let result = try await linker.addAuthenticator()
        switch result {
        case .needsPhoneNumber:
            step = .phoneNumber

        case .authenticatorAlreadyPresent:
            errorMessage =
                "This account already has an authenticator. Remove it in the Steam mobile app first, "
                + "or import its maFile instead."

        case .awaitingFinalization(let revocationCode):
            // Persist before anything else can fail.
            if let account = linker.linkedAccount {
                model.save(account)
            }
            smsCode = ""
            revocationAcknowledged = false
            step = .revocationCode(revocationCode)
        }
    }

    private func finalize() async {
        guard let linker else { return }
        await run {
            let result = try await linker.finalize(smsCode: smsCode)
            switch result {
            case .success:
                if let account = linker.linkedAccount { model.save(account) }
                step = .finished
                model.show(.success, "Authenticator is now active on this Mac.")

            case .badSMSCode:
                errorMessage = "That SMS code was not accepted. Check it and try again."

            case .unableToGenerateCorrectCodes:
                errorMessage =
                    "Steam rejected the generated codes. Your Mac's clock is probably off — turn on "
                    + "automatic time in System Settings, then try again."

            case .steamKeptAskingForCodes:
                // Nothing was rejected here, so pointing at the clock would
                // send them off to fix something that is not broken.
                errorMessage =
                    "Steam kept asking for another code without finishing. Your authenticator is "
                    + "saved, so try Finish Setup again in a moment."
            }
        }
    }
}
