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
                            Text("未检测到风扇")
                                .font(.headline)
                            Text("这台 Mac 可能没有可控风扇(如无风扇设计),或 SMC 不可用。")
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
                            title: "此机型暂不支持风扇控制,仅显示传感器数据",
                            detail: "SMC 没有提供可写入的转速目标或手动模式开关。"
                        )
                    } else if !state.helperAvailable {
                        // Same warning the menu-bar panel shows: without the helper a
                        // mode still saves and still lights up, but no fan moves.
                        helperBanner
                    } else if state.sensorsUnavailable {
                        NoticeCard(
                            title: "传感器读取失败,已恢复系统自动控制",
                            detail: "SMC 暂时无法读取温度,曲线模式不会按 0°C 继续下发转速。"
                        )
                    } else if state.controlWriteFailed {
                        NoticeCard(
                            title: "风扇转速写入未生效",
                            detail: "助手已收到指令但 SMC 拒绝写入,本机型可能不允许强制转速。"
                        )
                    }

                    HStack {
                        GlassSectionHeader(
                            title: "风扇",
                            detail: state.controlTemperatureValue.map { String(format: "控制源温度 %.0f°C", $0) }
                                ?? "控制源温度不可用"
                        )
                        Spacer()
                        // An action, not a mode — no accent `active` treatment,
                        // but it must not look clickable when it would do nothing.
                        Button("全部恢复自动") { state.restoreAutoAll() }
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

    private var helperBanner: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("未安装特权助手,选择的模式不会生效")
                        .font(.system(size: 12, weight: .medium))
                    Text("风扇转速的写入需要 root 权限,只需授权一次。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Button("安装助手…") { state.requestHelperInstall(reason: .banner) }
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
                // 自动 IS what an uninstalled helper leaves the fan on — only the
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
                    Text("风扇 \(fan.index + 1)")
                        .font(.system(size: 15, weight: .semibold))
                    if fan.forced {
                        Text("手动控制中")
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
                    Text(String(format: "范围 %.0f–%.0f", fan.minRPM, fan.maxRPM))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                LiquidSegmentedPicker(
                    options: FanControlMode.allCases.map { ($0, $0.title) },
                    selection: modeBinding
                )
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
            Text("由系统自动管理转速。")
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
                Text("目标转速")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f RPM(%.0f%%)", rpm, config.fixedPercent))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            Slider(value: binding, in: 0...100, step: 1) {
                Text("转速")
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
                Text("预设")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(FanConfig.presets, id: \.name) { preset in
                    Button(preset.name) {
                        state.requireHelper(.presetPicked) {
                            state.applyPreset(fan.index, curve: preset.curve)
                        }
                    }
                    .buttonStyle(LiquidButtonStyle(active: config.selection == .preset(preset.name)))
                    .disabled(!state.fanControlSupported)
                }
                // Outlined and neutral on purpose: 自定义 describes the state of
                // an unlit row, it is not a fifth preset to click.
                if config.selection == .customCurve {
                    Text("自定义")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.8))
                }
                Spacer()
                if let target = state.targetRPMs[fan.index], target > 0 {
                    Text(String(format: "目标 %.0f RPM", target))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            CurveEditorView(
                points: config.curve,
                currentTemp: state.controlTemperature,
                currentPercent: percent(of: fan.actualRPM),
                minRPM: fan.minRPM,
                maxRPM: fan.maxRPM
            ) { newPoints in
                state.updateFanConfig(fan.index) { $0.curve = newPoints }
            }
            .frame(height: 230)

            Text("拖拽控制点调整 · 双击空白添加 · 右键删除")
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
                x: .value("时间", sample.time),
                y: .value("RPM", sample.value)
            )
            .foregroundStyle(GlassPalette.accent.opacity(0.15).gradient)
            .interpolationMethod(.catmullRom)
            LineMark(
                x: .value("时间", sample.time),
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
    let title: String
    let detail: String

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
