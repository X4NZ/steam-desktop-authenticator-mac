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
([SteamKit2](https://github.com/SteamRE/SteamKit)). Steam's
`IAuthenticationService` speaks protobuf only, so rather
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

- the code-generation vector comes from [steamguard-cli](https://github.com/dyc3/steamguard-cli)'s own test suite,
- the PBKDF2 key from Python's `hashlib.pbkdf2_hmac`,
- the AES ciphertext from `openssl enc`,
- the protobuf byte strings were computed by hand from the wire-format spec.

---

## Credits

This app is an independent implementation, not a port: no third-party source
was copied into it. These are the projects it was built against, and what each
one contributed.

| Project | Licence | What it gave this app |
| --- | --- | --- |
| [Steam Desktop Authenticator](https://github.com/Jessecar96/SteamDesktopAuthenticator) by Jessecar96 | MIT | The thing being reimplemented. Its `maFile` and `manifest.json` layout and its PBKDF2/AES parameters are matched byte for byte so folders move between the two. No code taken. |
| [steamguard-cli](https://github.com/dyc3/steamguard-cli) by dyc3 | GPL-3.0 | One code-generation test vector, used in `Tests/SteamAuthKitTests/CryptoTests.swift`. The only third-party material in this repository. |
| [SteamKit](https://github.com/SteamRE/SteamKit) (SteamKit2) by SteamRE | LGPL-2.1 | Nothing, by necessity: it is the .NET library SDA delegates login to, which is why `SteamLogin.swift` and `Proto.swift` had to be written from the wire format instead. |

Code generation follows [RFC 4226](https://www.rfc-editor.org/rfc/rfc4226)
(HOTP), with Steam's base-26 alphabet substituted for decimal digits.

---

## Licence

Copyright (C) 2026 XanZ

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. The full text is in [LICENSE](LICENSE).

It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY,
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the licence for details.

The code here is written from Steam's own protocols rather than ported from
SDA, and protocols and file formats are not themselves copyrightable, so this
licence is not inherited from anything. It is chosen rather than required: the
one piece of third-party material in the repository is a test vector from
steamguard-cli, which is GPL-3.0, and copyleft keeps that unambiguous. Note
that upstream SDA is MIT, not GPL-3.0, so nothing here obliged this choice —
see [Credits](#credits).
