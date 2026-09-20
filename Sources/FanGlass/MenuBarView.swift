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
                VStack(alignment: .trailing, spacing: 2) {
                    Text("风扇转速")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", state.primaryFanRPM))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("RPM")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
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

            // quick actions
            VStack(alignment: .leading, spacing: 8) {
                Text("快捷模式(应用于所有风扇)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                // Equal-width compact pills: a 300-pt panel cannot fit five
                // default LiquidButtons, and HStack then crushes the leading
                // ones ("自动" / "静音") into "…".
                HStack(spacing: 5) {
                    compactModeButton("自动") { state.restoreAutoAll() }
                    ForEach(FanConfig.presets, id: \.name) { preset in
                        compactModeButton(preset.name) {
                            for fan in state.fans { state.applyPreset(fan.index, curve: preset.curve) }
                        }
                    }
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
        .onAppear { state.refreshHelperStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .fanglassOpenMainWindow)) { _ in
            openMainWindow()
        }
    }

    private func compactModeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(LiquidButtonStyle(compact: true))
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        DispatchQueue.main.async { AppDelegate.presentMainWindow() }
    }
}
