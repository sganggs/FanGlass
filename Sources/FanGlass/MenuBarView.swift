// MenuBarView.swift — compact glass panel behind the menu bar icon.
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // header: hottest temp + fan rpm
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("最热传感器")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", state.hottestTemperature))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(state.temperatureColor(state.hottestTemperature))
                        Text("°C")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !state.fans.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        // With two or more fans this is the fastest one, not fan 0.
                        Text(state.fans.count > 1 ? "最高转速" : "风扇转速")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(String(format: "%.0f", state.primaryFanRPM))
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                            Text("RPM")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        if state.fans.count > 1 {
                            Text("共 \(state.fans.count) 个风扇")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Divider().opacity(0.4)

            // sensor groups
            VStack(spacing: 6) {
                ForEach(state.groups.filter { $0.id != "other" }.prefix(7)) { group in
                    HStack {
                        Circle()
                            .fill(state.temperatureColor(group.value))
                            .frame(width: 6, height: 6)
                        Text(group.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f°C", group.value))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                }
            }

            Divider().opacity(0.4)

            // quick actions — only where a fan can actually be driven.
            if state.fanControlSupported {
                quickModes
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "fan.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(state.fans.isEmpty ? "本机无可控风扇" : "此机型暂不支持风扇控制")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.4)

            HStack {
                Button("打开 FanGlass") { openMainWindow() }
                    .buttonStyle(LiquidButtonStyle(prominent: true))
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(LiquidButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 328)
        // Reopen is handled by MenuBarLabel, which — unlike this panel — is
        // hosted for the whole life of the app.
        .onAppear { state.refreshHelperStatus() }
    }

    private var quickModes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快捷模式(应用于所有风扇)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            // Without the helper a click still saves the setting but changes
            // nothing physically; say so, or the highlight below would be a lie.
            if !state.helperAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("未安装特权助手,选择的模式不会生效")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    // Straight to the password dialog — sending the user to
                    // the Settings tab to find the card is three clicks more.
                    Button("安装") { state.requestHelperInstall(reason: .banner) }
                        .buttonStyle(LiquidButtonStyle(compact: true))
                        .fixedSize()
                }
            } else if state.sensorsUnavailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("传感器读取失败,已恢复自动控制")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // Equal-width compact pills: a 300-pt panel cannot fit five
            // default LiquidButtons, and HStack then crushes the leading
            // ones ("自动" / "静音") into "…".
            HStack(spacing: 5) {
                compactModeButton("自动", active: selection == .auto) {
                    state.restoreAutoAll()
                }
                ForEach(FanConfig.presets, id: \.name) { preset in
                    compactModeButton(preset.name, active: selection == .preset(preset.name)) {
                        state.requireHelper(.presetPicked) {
                            for fan in state.fans { state.applyPreset(fan.index, curve: preset.curve) }
                        }
                    }
                }
            }

            // Covers 自定义曲线 / 固定转速 / mixed fans, so an all-dark row is
            // never left unexplained.
            if let hint = state.quickModeHint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The mode every fan shares, or nil when they differ (nothing lights up).
    private var selection: FanSelection? { state.selectionForAllFans }

    private func compactModeButton(_ title: String, active: Bool,
                                   action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(LiquidButtonStyle(compact: true, active: active))
            // Without a helper the pills still work — they save the mode, they
            // just cannot move a fan yet — so the row must not read as disabled,
            // and the selected pill least of all: dimming the one piece of
            // feedback that confirms the user's click is exactly backwards.
            // The orange line above already says it will not take effect.
            .opacity(state.helperAvailable || active ? 1 : 0.55)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
    }

    private func openMainWindow(tab: AppTab? = nil) {
        if let tab { state.pendingTab = tab }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        DispatchQueue.main.async { AppDelegate.presentMainWindow() }
    }
}
