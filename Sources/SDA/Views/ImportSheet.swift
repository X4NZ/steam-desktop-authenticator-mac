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
    @State private var isTargeted = false

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
                // One literal, so SwiftUI parses the markdown rather than
                // printing the asterisks and backticks.
                Text("Drag your whole **maFiles** folder here. It holds `manifest.json` plus one `.maFile` per account, and that manifest carries the salts needed to decrypt them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                dropZone

                if needsPassphrase {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("These files are encrypted. Enter the passphrase they were saved with.")
                            .font(.callout)
                        SecureField("Source passphrase", text: $sourcePassphrase)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { performImport() }
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

    /// Drop target and file pickers in one. Dragging a folder in from Finder is
    /// the quickest route, since importing wants the whole maFiles folder anyway.
    private var dropZone: some View {
        VStack(spacing: 10) {
            if let pickedURL {
                Image(systemName: isFolder ? "folder.fill" : "doc.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)

                Text(pickedURL.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(pickedURL.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button("Choose Something Else") { self.pickedURL = nil }
                    .controlSize(.small)
                    .buttonStyle(.link)
            } else {
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "folder.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

                Text(isTargeted ? "Drop to import" : "Drag your maFiles folder here")
                    .font(.callout)
                    .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

                HStack(spacing: 8) {
                    Button("Choose Folder…") { chooseFolder() }
                    Button("Choose File…") { chooseFile() }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.quaternary.opacity(0.25)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 1.5, dash: pickedURL == nil ? [6, 4] : [])
                )
        )
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            return accept(url)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    /// Validates a URL from either a drop or a picker, and works out whether a
    /// source passphrase will be needed.
    @discardableResult
    private func accept(_ url: URL) -> Bool {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        if isDirectory {
            let manifestURL = url.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                // A folder of loose maFiles has no salts, so encrypted ones in it
                // are unreadable. Say so rather than failing cryptically later.
                model.show(
                    .error,
                    "That folder has no manifest.json, so it is not an maFiles folder. "
                        + "Pick the folder that contains it."
                )
                return false
            }
            pickedURL = url
            isFolder = true
            needsPassphrase = folderIsEncrypted(url)
            return true
        }

        guard url.pathExtension == "maFile" || url.lastPathComponent == "manifest.json" else {
            model.show(.error, "That is not an maFile. Drop your maFiles folder instead.")
            return false
        }

        // Dropping manifest.json is a near miss; treat it as the folder.
        if url.lastPathComponent == "manifest.json" {
            return accept(url.deletingLastPathComponent())
        }

        guard let data = try? Data(contentsOf: url),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            model.show(
                .warning,
                "That maFile is encrypted. Import the whole maFiles folder instead, so its "
                    + "manifest.json can supply the decryption salt."
            )
            return false
        }

        pickedURL = url
        isFolder = false
        needsPassphrase = false
        return true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        accept(url)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        accept(url)
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
