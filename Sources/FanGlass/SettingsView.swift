// SettingsView.swift — polling, control source, hysteresis, alerts, helper management.
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    var onScrolled: ((Bool) -> Void)? = nil

    var body: some View {
        GlassScrollView(topMargin: 68, onScrolled: onScrolled) {
            VStack(alignment: .leading, spacing: 16) {
                generalCard
                controlCard
                alertCard
                helperCard
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }

    private var generalCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeader(title: "通用")

                HStack {
                    Text("采样间隔")
                        .font(.system(size: 12))
                    Spacer()
                    Text(String(format: "%.1f 秒", state.settings.pollInterval))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { state.settings.pollInterval },
                        set: { v in
                            state.settings.pollInterval = v
                            state.restartPolling()
                        }
                    ),
                    in: 0.5...3.0, step: 0.5
                )
                .tint(GlassPalette.accent)

                Toggle("登录时启动", isOn: Binding(
                    get: { state.settings.launchAtLogin },
                    set: { v in
                        state.settings.launchAtLogin = v
                        state.applyLaunchAtLogin()
                    }
                ))
                .font(.system(size: 12))

                Toggle("退出时恢复风扇自动控制", isOn: Binding(
                    get: { state.settings.restoreAutoOnQuit },
                    set: { v in state.settings.restoreAutoOnQuit = v }
                ))
                .font(.system(size: 12))
            }
        }
    }

    private var controlCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeader(title: "控制")

                HStack {
                    Text("曲线温度源")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { state.settings.controlSource },
                        set: { state.settings.controlSource = $0 }
                    )) {
                        ForEach(state.groups.filter { $0.id != "ambient" && $0.id != "other" }) { group in
                            Text(group.name).tag(group.id)
                        }
                        Text("最热传感器").tag("max")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                // Key families differ per chip generation, so a curve carried
                // over from another Mac can point at a group this one does not
                // have. Substituting a different signal silently is exactly the
                // kind of thing a fan controller must never do.
                if state.controlSourceMissing {
                    Text("所选控制源在本机型不可用,已改用最热传感器。")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text("转速迟滞")
                        .font(.system(size: 12))
                    Spacer()
                    Text(String(format: "%.0f RPM", state.settings.hysteresisRPM))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { state.settings.hysteresisRPM },
                        set: { state.settings.hysteresisRPM = $0 }
                    ),
                    in: 0...400, step: 20
                )
                .tint(GlassPalette.accent)

                Text("迟滞可避免转速在边界值附近频繁抖动;设 0 则每次采样都更新。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var alertCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeader(title: "过热提醒")

                HStack {
                    Text("温度阈值")
                        .font(.system(size: 12))
                    Spacer()
                    Text(state.settings.overheatThreshold <= 0
                         ? "已关闭"
                         : String(format: "%.0f°C", state.settings.overheatThreshold))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { state.settings.overheatThreshold },
                        set: { state.settings.overheatThreshold = $0 }
                    ),
                    in: 0...110, step: 5
                )
                .tint(.orange)

                Text("任一传感器(除环境)超过阈值时发送系统通知;拖到最左关闭。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - privileged helper

    private var busy: Bool { state.installPhase.isBusy }

    private var helperDetail: String {
        guard let version = state.helperVersion else { return "未安装" }
        return state.helperOutdated ? "版本过旧(v\(version))" : "运行中 · v\(version)"
    }

    private var helperCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeader(title: "特权助手", detail: helperDetail)

                Text("风扇转速的写入需要 root 权限,由后台特权助手完成。传感器读取无需权限。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if state.helperOutdated {
                    Text("已安装的助手是旧版本(v\(state.helperVersion ?? 0),需要 v\(HelperProtocol.version)),更新后新指令才能生效。")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    if !state.helperAvailable {
                        Button("安装助手…") { state.beginInstall() }
                            .buttonStyle(LiquidButtonStyle(prominent: true))
                            .disabled(busy)
                    } else {
                        Button(state.helperOutdated ? "更新助手…" : "重新安装助手…") { state.beginInstall() }
                            .buttonStyle(LiquidButtonStyle(prominent: state.helperOutdated))
                            .disabled(busy)
                        Button("卸载助手…") { state.uninstallHelper() }
                            .buttonStyle(LiquidButtonStyle())
                            .disabled(busy)
                    }
                    Spacer()
                    Button("刷新状态") { state.refreshHelperStatus() }
                        .buttonStyle(LiquidButtonStyle())
                        .disabled(busy)
                }

                if busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(state.installPhase.note ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else if let note = state.installPhase.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(state.installPhase.isProblem ? Color.orange : .secondary)
                }
            }
        }
    }
}
