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
                    HStack {
                        GlassSectionHeader(
                            title: "风扇",
                            detail: String(format: "控制源温度 %.0f°C", state.controlTemperature)
                        )
                        Spacer()
                        // An action, not a mode — no accent `active` treatment,
                        // but it must not look clickable when it would do nothing.
                        Button("全部恢复自动") { state.restoreAutoAll() }
                            .buttonStyle(LiquidButtonStyle())
                            .disabled(state.allFansAuto)
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
}

struct FanCardView: View {
    @EnvironmentObject var state: AppState
    let fan: FanStatus

    private var config: FanConfig { state.settings.fanConfig(for: fan.index) }

    private var modeBinding: Binding<FanControlMode> {
        Binding(
            get: { config.mode },
            set: { mode in state.updateFanConfig(fan.index) { $0.mode = mode } }
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
            set: { v in state.updateFanConfig(fan.index) { $0.fixedPercent = v } }
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
                    Button(preset.name) { state.applyPreset(fan.index, curve: preset.curve) }
                        .buttonStyle(LiquidButtonStyle(active: config.selection == .preset(preset.name)))
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
        .chartYScale(domain: 0...(fan.maxRPM * 1.1))
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
