// HelperOnboardingView.swift — the in-window authorization prompt.
// Shown as a sheet when the main window is on screen; AppState falls back to an
// NSAlert when it is not (first launch has no window, and the menu-bar panel
// dismisses itself the moment the password dialog takes focus).
import SwiftUI

struct HelperOnboardingView: View {
    @EnvironmentObject var state: AppState

    private var reason: HelperInstaller.Reason { state.installReason }
    private var phase: HelperInstaller.Phase { state.installPhase }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(GlassPalette.accent)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(reason.title)
                        .font(.system(size: 16, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(reason.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if phase.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase.note ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if phase.isProblem, let note = phase.note {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Text("之后可以随时在「设置 → 特权助手」里安装或卸载。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 12)
                Button("稍后") { state.cancelInstallRequest() }
                    .buttonStyle(LiquidButtonStyle())
                    .disabled(phase.isBusy)
                Button(reason.confirmTitle) { state.beginInstall() }
                    .buttonStyle(LiquidButtonStyle(prominent: true))
                    .disabled(phase.isBusy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
