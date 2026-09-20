// SettingsView.swift — polling, control source, hysteresis, alerts, helper management.
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    var onScrolled: ((Bool) -> Void)? = nil
    @State private var helperBusy = false
    @State private var helperNote: String?

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

    private var helperCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeader(
                    title: "特权助手",
                    detail: state.helperAvailable ? "运行中" : "未安装"
                )

                Text("风扇转速的写入需要 root 权限,由后台特权助手完成。传感器读取无需权限。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if !state.helperAvailable {
                        Button("安装助手…") { runScript("install.sh") }
                            .buttonStyle(LiquidButtonStyle(prominent: true))
                            .disabled(helperBusy)
                    } else {
                        Button("重新安装助手…") { runScript("install.sh") }
                            .buttonStyle(LiquidButtonStyle())
                            .disabled(helperBusy)
                        Button("卸载助手…") { runScript("uninstall.sh") }
                            .buttonStyle(LiquidButtonStyle())
                            .disabled(helperBusy)
                    }
                    Spacer()
                    Button("刷新状态") { state.refreshHelperStatus() }
                        .buttonStyle(LiquidButtonStyle())
                        .disabled(helperBusy)
                }

                if helperBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在请求管理员授权…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else if let helperNote {
                    Text(helperNote)
                        .font(.system(size: 11))
                        .foregroundStyle(state.helperAvailable ? .secondary : Color.orange)
                }
            }
        }
    }

    private func runScript(_ name: String) {
        guard let script = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "scripts") else {
            helperNote = "找不到 \(name)"
            return
        }
        helperBusy = true
        helperNote = nil

        let helperURL = Bundle.main.url(forResource: "fanglass-helper", withExtension: nil)
        let plistURL = Bundle.main.url(forResource: "com.fanglass.helper", withExtension: "plist")

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            var env = ProcessInfo.processInfo.environment
            if let helperURL { env["FANGLASS_HELPER"] = helperURL.path }
            if let plistURL { env["FANGLASS_PLIST"] = plistURL.path }
            process.environment = env
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    helperBusy = false
                    helperNote = error.localizedDescription
                }
                return
            }

            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ok = process.terminationStatus == 0
            let canceled = errText.localizedCaseInsensitiveContains("canceled")
                || errText.localizedCaseInsensitiveContains("cancelled")
                || errText.contains("(-128)")

            DispatchQueue.main.async {
                helperBusy = false
                if ok {
                    helperNote = name.contains("uninstall") ? "助手已卸载" : "助手已安装"
                } else if canceled {
                    helperNote = "已取消授权"
                } else if errText.isEmpty {
                    helperNote = "操作失败（退出码 \(process.terminationStatus)）"
                } else {
                    helperNote = errText
                }
                state.refreshHelperStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { state.refreshHelperStatus() }
            }
        }
    }
}
