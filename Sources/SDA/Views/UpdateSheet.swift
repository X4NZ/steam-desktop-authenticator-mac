import AppUpdater
import SwiftUI

/// Shows what a new release contains and installs it.
struct UpdateSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let release: Updater.Release

    @State private var progress: Double = 0
    @State private var installing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(.headline)
                    Text("Version \(release.version) — you have \(Updater.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !release.notes.isEmpty {
                        Text(.init(release.notes))
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("No release notes were provided.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .frame(maxHeight: 240)

            Divider()

            VStack(spacing: 10) {
                if installing {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                        Text(
                            progress < 1
                                ? "Downloading… \(Int(progress * 100))%"
                                : "Installing and restarting…"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Link("View on GitHub", destination: release.pageURL)
                        .font(.callout)
                    Spacer()
                    Button("Later") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(installing)
                    Button("Install and Restart") { install() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(installing || release.downloadURL == nil)
                }
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    private func install() {
        installing = true
        errorMessage = nil

        Task {
            do {
                // Never returns: the app quits so the installer can swap it.
                try await Updater.downloadAndInstall(release) { fraction in
                    Task { @MainActor in progress = fraction }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    installing = false
                }
            }
        }
    }
}
