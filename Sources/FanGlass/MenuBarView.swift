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
                    Text("Hottest sensor")
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
                        Text(state.fans.count > 1 ? "Top fan speed" : "Fan speed")
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
                            Text("\(state.fans.count) fans in total")
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
                    Text(state.fans.isEmpty
                         ? "This Mac has no controllable fans"
                         : "Fan control is not supported on this Mac")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.4)

            HStack {
                Button("Open FanGlass") { openMainWindow() }
                    .buttonStyle(LiquidButtonStyle(prominent: true))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
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
            Text("Quick modes (applies to all fans)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            // Without the helper a click still saves the setting but changes
            // nothing physically; say so, or the highlight below would be a lie.
            if !state.helperAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("Helper not installed; the mode you pick will not take effect")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    // Straight to the password dialog — sending the user to
                    // the Settings tab to find the card is three clicks more.
                    Button("Install") { state.requestHelperInstall(reason: .banner) }
                        .buttonStyle(LiquidButtonStyle(compact: true))
                        .fixedSize()
                }
            } else if state.helperOutdated {
                // Same state the fan page and the top-bar pill report: an old
                // daemon may not understand this build's commands, so the
                // highlight below cannot be taken at face value either.
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("Helper is outdated; some commands may not take effect")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Update") { state.requestHelperInstall(reason: .outdated) }
                        .buttonStyle(LiquidButtonStyle(compact: true))
                        .fixedSize()
                }
            } else if state.sensorsUnavailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    // Only curve-mode fans are handed back; a fan pinned to a
                    // fixed RPM keeps its target, so do not claim otherwise.
                    Text("Sensor read failed; curve mode is back on automatic control")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // One row of equal-width pills while the labels fit (Simplified
            // Chinese always does), wrapping at natural widths when they do
            // not — five English labels in a 296-pt box cannot share it
            // equally without every one of them truncating to "…".
            AdaptivePillRow(spacing: 5) {
                compactModeButton(String(localized: "Auto"), active: selection == .auto) {
                    state.restoreAutoAll()
                }
                ForEach(FanConfig.presets) { preset in
                    compactModeButton(preset.title, active: selection == .preset(preset.id)) {
                        state.requireHelper(.presetPicked) {
                            for fan in state.fans { state.applyPreset(fan.index, curve: preset.curve) }
                        }
                    }
                }
            }

            // Covers a custom curve / a fixed speed / mixed fans, so an
            // all-dark row is never left unexplained.
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
            // Never dimmed, helper or not: clicking one of these pills is the
            // main path to the install prompt, so they must read as clickable.
            // The warning row above carries the "will not take effect" signal.
            // Widths belong to AdaptivePillRow, not to the button.
    }

    private func openMainWindow(tab: AppTab? = nil) {
        if let tab { state.pendingTab = tab }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        DispatchQueue.main.async { AppDelegate.presentMainWindow() }
    }
}
