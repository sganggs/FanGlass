// FansView.swift — per-fan control cards: auto / fixed / curve modes, presets, RPM history.
import SwiftUI
import Charts

struct FansView: View {
    @EnvironmentObject var state: AppState
    var onScrolled: ((Bool) -> Void)? = nil

    var body: some View {
        GlassScrollView(topMargin: 68, onScrolled: onScrolled) {
            VStack(alignment: .leading, spacing: 16) {
                if state.fans.isEmpty && !state.scanning {
                    GlassCard {
                        VStack(spacing: 8) {
                            Image(systemName: "fan.slash")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("No fans detected")
                                .font(.headline)
                            Text("This Mac may have no controllable fans (a fanless design), or the SMC is unavailable.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                } else {
                    // Hardware first, then permissions, then runtime failures —
                    // each one makes the next moot, so only the top-most shows.
                    if !state.fanControlSupported {
                        NoticeCard(
                            title: "Fan control is not supported on this Mac; sensor data only",
                            detail: "The SMC exposes no writable RPM target or manual-mode switch."
                        )
                    } else if !state.helperAvailable {
                        // Same warning the menu-bar panel shows: without the helper a
                        // mode still saves and still lights up, but no fan moves.
                        helperBanner(
                            title: "Helper not installed; the mode you pick will not take effect",
                            detail: "Writing fan speeds requires root privileges; one authorization is all it takes.",
                            action: "Install Helper…",
                            reason: .banner
                        )
                    } else if state.helperOutdated {
                        // An update that was declined or that failed leaves a
                        // daemon too old for this build's commands. Without this
                        // the only trace is the Settings card, which the user has
                        // to go looking for — and the prompt fires only once.
                        helperBanner(
                            title: "Helper is outdated; some commands may not take effect",
                            detail: "Updating costs one more authorization.",
                            action: "Update Helper…",
                            reason: .outdated
                        )
                    } else if state.sensorsUnavailable {
                        // Only the curve branch releases on a blackout; a fan
                        // on a fixed speed is still held at its target.
                        NoticeCard(
                            title: "Sensor read failed; curve mode is back on automatic control",
                            detail: "The SMC cannot read temperatures right now, so curve mode will not keep driving the fans as though the temperature were 0°C; fans on a fixed speed keep their target."
                        )
                    } else if state.controlWriteFailed {
                        NoticeCard(
                            title: "The fan speed change did not take effect",
                            detail: "The helper received the command but the SMC refused the write; this Mac may not allow forcing a fan speed."
                        )
                    }

                    HStack {
                        GlassSectionHeader(
                            title: String(localized: "Fans"),
                            detail: state.controlTemperatureValue.map {
                                String(format: String(localized: "Control source %.0f°C"), $0)
                            } ?? String(localized: "Control source temperature unavailable")
                        )
                        Spacer()
                        // An action, not a mode — no accent `active` treatment,
                        // but it must not look clickable when it would do nothing.
                        Button("Restore All to Auto") { state.restoreAutoAll() }
                            .buttonStyle(LiquidButtonStyle())
                            .disabled(state.allFansAuto || !state.fanControlSupported)
                    }

                    ForEach(state.fans, id: \.index) { fan in
                        FanCardView(fan: fan)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }

    private func helperBanner(title: LocalizedStringKey, detail: LocalizedStringKey,
                              action: LocalizedStringKey,
                              reason: HelperInstaller.Reason) -> some View {
        GlassCard(padding: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Button(action) { state.requestHelperInstall(reason: reason) }
                    .buttonStyle(LiquidButtonStyle(prominent: true))
                    .fixedSize()
            }
        }
    }
}

struct FanCardView: View {
    @EnvironmentObject var state: AppState
    let fan: FanStatus

    private var config: FanConfig { state.settings.fanConfig(for: fan.index) }

    private var modeBinding: Binding<FanControlMode> {
        Binding(
            get: { config.mode },
            set: { mode in
                let apply = { state.updateFanConfig(fan.index) { $0.mode = mode } }
                // Auto IS what an uninstalled helper leaves the fan on — only the
                // modes that need a privileged write are worth a password for.
                if mode == .auto { apply() } else { state.requireHelper(.modePicked, then: apply) }
            }
        )
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                // header
                HStack(alignment: .firstTextBaseline) {
                    SpinningFanView(rpm: fan.actualRPM, size: 14)
                    Text("Fan \(fan.index + 1)")
                        .font(.system(size: 15, weight: .semibold))
                    if fan.forced {
                        Text("Manual control")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(GlassPalette.accent.gradient))
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.0f", fan.actualRPM))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("RPM")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(String(format: String(localized: "Range %.0f–%.0f"), fan.minRPM, fan.maxRPM))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                LiquidSegmentedPicker(
                    options: FanControlMode.allCases.map { ($0, $0.title) },
                    selection: modeBinding
                )
                // 260 pt gives each of Auto / Fixed / Curve 81.3 pt; the widest
                // English label needs 59 pt, the Chinese ones less.
                .frame(width: 260)
                // LiquidSegmentedPicker has no disabled styling of its own.
                .opacity(state.fanControlSupported ? 1 : 0.45)
                .disabled(!state.fanControlSupported)

                switch config.mode {
                case .auto:
                    autoBody
                case .fixed:
                    fixedBody
                case .curve:
                    curveBody
                }

                rpmHistory
            }
        }
    }

    private var autoBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.green)
            Text("Fan speed is managed automatically by the system.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var fixedBody: some View {
        let binding = Binding<Double>(
            get: { config.fixedPercent },
            // Mid-drag: update the target and let hysteresis decide whether it
            // is worth sending. The release below applies the final value.
            set: { v in state.updateFanConfig(fan.index, resend: false) { $0.fixedPercent = v } }
        )
        let rpm = fan.minRPM + config.fixedPercent / 100 * (fan.maxRPM - fan.minRPM)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Target speed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: String(localized: "%.0f RPM (%.0f%%)"), rpm, config.fixedPercent))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            Slider(value: binding, in: 0...100, step: 1) {
                // The slider's own label, kept distinct from the menu-bar
                // panel's "Fan speed" heading so the two can be worded apart.
                Text("Speed")
            } minimumValueLabel: {
                Text(String(format: "%.0f", fan.minRPM)).font(.system(size: 9))
            } maximumValueLabel: {
                Text(String(format: "%.0f", fan.maxRPM)).font(.system(size: 9))
            } onEditingChanged: { editing in
                if !editing { state.resendFan(fan.index) }
            }
            .tint(GlassPalette.accent)
        }
        .padding(.vertical, 4)
    }

    private var curveBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Presets")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(FanConfig.presets) { preset in
                    Button(preset.title) {
                        state.requireHelper(.presetPicked) {
                            state.applyPreset(fan.index, curve: preset.curve)
                        }
                    }
                    .buttonStyle(LiquidButtonStyle(active: config.selection == .preset(preset.id)))
                    .disabled(!state.fanControlSupported)
                }
                // Outlined and neutral on purpose: "Custom" describes the state
                // of an unlit row, it is not a fifth preset to click.
                if config.selection == .customCurve {
                    Text("Custom")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.8))
                }
                Spacer()
                if let target = state.targetRPMs[fan.index], target > 0 {
                    Text(String(format: String(localized: "Target %.0f RPM"), target))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            CurveEditorView(
                points: config.curve,
                currentTemp: state.controlTemperatureValue,
                currentPercent: percent(of: fan.actualRPM),
                minRPM: fan.minRPM,
                maxRPM: fan.maxRPM
            ) { newPoints in
                state.updateFanConfig(fan.index) { $0.curve = newPoints }
            }
            .frame(height: 230)

            Text("Drag a point to adjust · double-click empty space to add · right-click to delete")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func percent(of rpm: Double) -> Double {
        guard fan.maxRPM > fan.minRPM else { return 0 }
        return (rpm - fan.minRPM) / (fan.maxRPM - fan.minRPM) * 100
    }

    private var rpmHistory: some View {
        let history = state.fanHistories[fan.index] ?? []
        return Chart(history, id: \.time) { sample in
            AreaMark(
                x: .value(String(localized: "Time"), sample.time),
                y: .value("RPM", sample.value)
            )
            .foregroundStyle(GlassPalette.accent.opacity(0.15).gradient)
            .interpolationMethod(.catmullRom)
            LineMark(
                x: .value(String(localized: "Time"), sample.time),
                y: .value("RPM", sample.value)
            )
            .foregroundStyle(GlassPalette.accent)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 1.6))
        }
        // A Mac whose F{i}Mx reads 0 would otherwise build the degenerate
        // domain 0...0, which Charts does not handle gracefully.
        .chartYScale(domain: 0...max(fan.maxRPM * 1.1, 1))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel()
                    .font(.system(size: 9))
            }
        }
        .frame(height: 90)
    }
}

/// A one-line warning card in the fan list. Every degraded state the app can be
/// in gets said out loud here — a fan controller must never look like it is
/// working when it is not.
private struct NoticeCard: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
