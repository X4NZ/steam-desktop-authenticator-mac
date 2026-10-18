# Steam Desktop Authenticator for Mac

A native macOS implementation of [Steam Desktop Authenticator](https://github.com/Jessecar96/SteamDesktopAuthenticator):
Steam Guard codes, trade confirmations and authenticator setup, in a SwiftUI app
with a menu bar extra.

Upstream SDA is a .NET 8 WinForms app targeting `net8.0-windows`, so it cannot
run on macOS. This is a reimplementation of the same protocols, not a port or a
wrapper — but it reads and writes the **same `maFiles` format**, so you can move
a folder between this app and SDA on Windows in either direction.

> **This is not affiliated with Valve or Steam.**

---

## Install

Grab the latest `.zip` from [Releases](https://github.com/X4NZ/steam-desktop-authenticator-mac/releases/latest),
unzip it, and drag the app into `/Applications`.

The app is ad-hoc signed, not notarized, so the first launch needs
**right-click ▸ Open** (or **System Settings ▸ Privacy & Security ▸ Open Anyway**).
After that it opens normally.

### Updating

**Check for Updates…** in the app menu compares against the latest GitHub
release and can download and install it in place, restarting the app when it is
done. It also checks quietly once a day on launch.

### Building it yourself

Needs Xcode 14+ (tested on Xcode 27.1 / Swift 6.4) and macOS 14 or later.

```bash
./Scripts/make-app.sh
open "build/Steam Desktop Authenticator.app"
```

To run the tests:

```bash
swift test
```

### Cutting a release

Tag it and the workflow builds, tests, zips and publishes:

```bash
git tag v1.1.0 && git push origin v1.1.0
```

---

## What it does

- **Steam Guard codes** — live code with a countdown ring, in the window and in
  the menu bar. Click to copy, or press ⇧⌘C from anywhere in the app.
- **Trade confirmations** — list, confirm and cancel, individually or in bulk.
  This uses Steam's JSON mobile endpoint, so there is no embedded web view
  (upstream SDA renders Steam's HTML page in WebView2, which is where most of
  its "blank confirmation window" bugs come from).
- **Set up a new authenticator** — full login, phone verification over SMS, and
  finalization. Works on accounts that have no authenticator yet.
- **Import existing maFiles** — from a Windows SDA install, encrypted or not.
- **Deactivate** — remove the authenticator from the Steam account, with the
  revocation code required to confirm.
- **Background checking** — poll for confirmations on a timer, with optional
  auto-confirm for trades and market listings, and macOS notifications.
- **Encryption** — same scheme as SDA, with the passphrase optionally stored in
  your login keychain instead of passed on the command line, and optionally
  behind Touch ID.

### A note on Touch ID

Turning on **Unlock with Touch ID** keeps the passphrase in your login keychain
and makes the app require Touch ID (or your Mac's login password) before reading
it. macOS also stops other apps reading that keychain item without asking you.

It is a lock on the app, not a second layer of encryption: the maFiles are still
encrypted with your passphrase, and anyone who knows that passphrase can open
them without Touch ID. Binding the item to the Secure Enclave outright needs a
Developer ID provisioning profile, which an ad-hoc signed build cannot have.

## Where your files live

```
~/Library/Application Support/SDA/maFiles/
```

Set `SDA_MAFILES_DIR` to keep them somewhere else — an encrypted disk image or
an external volume, for instance:

```bash
SDA_MAFILES_DIR=/Volumes/Secure/maFiles open "build/Steam Desktop Authenticator.app"
```

The layout is SDA's: `manifest.json` plus one `{steamid}.maFile` per account.
Files are written `0600`.

### Importing from Windows

Copy your whole `maFiles` **folder** across and use **Import maFiles ▸ Choose
Folder**. The folder matters: for encrypted installs, each file's salt and IV
live in `manifest.json`, so a lone `.maFile` cannot be decrypted without it.

---

## Please read this part

Upstream SDA is **no longer maintained**, and its authors recommend against
using any desktop authenticator. That advice applies here too:

- **Running your authenticator on the machine you trade from removes most of
  what two-factor authentication buys you.** If this Mac is compromised, so is
  your Steam account. Auto-confirm makes this strictly worse — anything that can
  reach the app can move your items. It is off by default; leave it off unless
  you genuinely need it.
- **Write down your revocation code** (the `R#####` string, shown during setup
  and under Account ▸ Reveal). It is the only way to remove the authenticator if
  you lose this Mac.
- **Back up your `maFiles` folder.** Lose both it and the revocation code and the
  account is gone — Steam Support is the only remaining option.
- Moving an authenticator between devices puts **trading on hold for a few days**.
- Turn on encryption. Without it your Steam accounts sit in plain text in your
  home folder.

---

## How it works

| Piece | Where |
|---|---|
| Code generation, confirmation signing | `Sources/SteamAuthKit/SteamGuardAccount.swift` |
| HMAC-SHA1, PBKDF2, AES-256-CBC, RSA | `Sources/SteamAuthKit/Crypto.swift` |
| maFile encryption (SDA-compatible) | `Sources/SteamAuthKit/FileEncryptor.swift` |
| manifest + account storage | `Sources/SteamAuthKit/AccountStore.swift` |
| Login (`IAuthenticationService`) | `Sources/SteamAuthKit/SteamLogin.swift` |
| Authenticator linking | `Sources/SteamAuthKit/AuthenticatorLinker.swift` |
| Confirmations | `Sources/SteamAuthKit/Confirmation.swift` |
| Minimal protobuf codec | `Sources/SteamAuthKit/Proto.swift` |

A few notes on the interesting parts:

**Codes** are RFC 4226 HOTP on a 30-second step, except the truncated value is
rendered in base 26 over Steam's alphabet `23456789BCDFGHJKMNPQRTVWXY` rather
than in decimal.

**Login** is the one place SDA leans on a library this app cannot use
(SteamKit2). Steam's `IAuthenticationService` speaks protobuf only, so rather
than take a protobuf dependency and a codegen step for four messages, `Proto.swift`
implements the three wire types those messages need in about 200 lines.

**maFile encryption** is pinned to SDA's parameters — PBKDF2-SHA1, 50,000 rounds,
AES-256-CBC. Those numbers are low by modern standards, but they are part of the
file format: changing them would make files unreadable by SDA and break the
compatibility that is the point of this app.

**Time** comes from Steam rather than the local clock. Codes live in a 30-second
window, so a drifting clock produces codes Steam rejects; the app measures the
offset once at launch and applies it.

### Tests

`swift test` covers the format-critical paths against vectors produced
*outside* this codebase, so they pin behaviour rather than restate it:

- the code-generation vector comes from steamguard-cli's own test suite,
- the PBKDF2 key from Python's `hashlib.pbkdf2_hmac`,
- the AES ciphertext from `openssl enc`,
- the protobuf byte strings were computed by hand from the wire-format spec.

---

## Licence

The upstream project is GPL-3.0. This is an independent implementation of the
same protocols; treat it as GPL-3.0 as well.
