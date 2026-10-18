import SteamAuthKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            switch model.lockState {
            case .loading:
                ProgressView().controlSize(.large)
            case .locked:
                UnlockView()
            case .empty:
                WelcomeView()
            case .unlocked:
                MainView()
            }
        }
        .animation(.default, value: model.lockState)
        .overlay(alignment: .bottom) { BannerView() }
    }
}

/// Transient status line. Replaces SDA's habit of using modal alerts for
/// routine outcomes like "code copied".
struct BannerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let banner = model.banner {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: banner.kind))
                    .foregroundStyle(tint(for: banner.kind))
                Text(banner.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    model.banner = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint(for: banner.kind).opacity(0.35))
            )
            .shadow(radius: 12, y: 4)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func symbol(for kind: AppModel.Banner.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func tint(for kind: AppModel.Banner.Kind) -> Color {
        switch kind {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
