import AppKit
import SteamAuthKit
import SwiftUI

/// Imports maFiles from an existing SDA install.
///
/// Importing a whole folder is the common case, because the per-file salt and IV
/// live in that folder's `manifest.json` — an encrypted `.maFile` on its own
/// cannot be decrypted without it.
struct ImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var pickedURL: URL?
    @State private var isFolder = false
    @State private var sourcePassphrase = ""
    @State private var needsPassphrase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Import maFiles").font(.headline)
                    Text("From a Windows SDA install or a backup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Pick your whole **maFiles** folder. It contains `manifest.json` plus one "
                    + "`.maFile` per account, and the manifest holds the salts needed to decrypt them."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Choose Folder…") { chooseFolder() }
                    Button("Choose Single File…") { chooseFile() }
                }

                if let pickedURL {
                    Label(pickedURL.path, systemImage: isFolder ? "folder" : "doc")
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                if needsPassphrase {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("These files are encrypted. Enter the passphrase they were saved with.")
                            .font(.callout)
                        SecureField("Source passphrase", text: $sourcePassphrase)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if model.isEncrypted {
                    Text("Imported accounts will be re-encrypted with this app's passphrase.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { performImport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pickedURL == nil || (needsPassphrase && sourcePassphrase.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 480)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedURL = url
        isFolder = true
        needsPassphrase = folderIsEncrypted(url)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedURL = url
        isFolder = false
        // A lone file that is not JSON must be ciphertext, which we cannot
        // decrypt without the manifest that holds its salt and IV.
        needsPassphrase = false

        if let data = try? Data(contentsOf: url),
           (try? JSONSerialization.jsonObject(with: data)) == nil {
            model.show(
                .warning,
                "That file looks encrypted. Import the whole maFiles folder instead, so its "
                    + "manifest.json can supply the decryption salt."
            )
            pickedURL = nil
        }
    }

    private func folderIsEncrypted(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return false }
        return manifest.encrypted
    }

    private func performImport() {
        guard let pickedURL else { return }
        let passphrase = needsPassphrase ? sourcePassphrase : nil

        if isFolder {
            model.importFolder(at: pickedURL, sourcePassphrase: passphrase)
        } else {
            model.importMaFile(at: pickedURL, sourcePassphrase: nil, salt: nil, iv: nil)
        }
        dismiss()
    }
}
