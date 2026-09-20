// SettingsView.swift — language, polling, control source, hysteresis, alerts, helper management.
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    var onScrolled: ((Bool) -> Void)? = nil

    /// The picker's own copy of the choice. `AppLanguage.current` reads
    /// UserDefaults, which is not observable, so the picker needs state.
    @State private var language: AppLanguage = .current
    /// Set once the user picks a different language; the note (and its
    /// "Relaunch now" button) stays until they relaunch or dismiss it.
    @State private var languageNeedsRelaunch = false

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
                GlassSectionHeader(title: String(localized: "General"))

                HStack {
                    Text("Language")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { language },
                        set: { newValue in
                            guard newValue != language else { return }
                            language = newValue
                            newValue.apply()
                            languageNeedsRelaunch = true
                        }
                    )) {
                        // Each language names itself; "System" follows macOS.
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }

                if languageNeedsRelaunch {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(GlassPalette.accent)
                        Text("The new language is applied the next time FanGlass starts.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Relaunch now") { AppRelaunch.now() }
                            .buttonStyle(LiquidButtonStyle(compact: true, active: true))
                            .fixedSize()
                        Button("Later") { languageNeedsRelaunch = false }
                            .buttonStyle(LiquidButtonStyle(compact: true))
                            .fixedSize()
                    }
                }

                HStack {
                    Text("Sampling interval")
                        .font(.system(size: 12))
                    Spacer()
                    Text(String(format: String(localized: "%.1f s"), state.settings.pollInterval))
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

                Toggle("Launch at login", isOn: Binding(
                    get: { state.settings.launchAtLogin },
                    set: { v in
                        state.settings.launchAtLogin = v
                        state.applyLaunchAtLogin()
                    }
                ))
                .font(.system(size: 12))

                Toggle("Restore automatic fan control immediately on quit", isOn: Binding(
                    get: { state.settings.restoreAutoOnQuit },
                    set: { v in state.settings.restoreAutoOnQuit = v }
                ))
                .font(.system(size: 12))

                // The toggle cannot mean "keep my fans where I left them": once
                // FanGlass stops sending its heartbeat the helper's watchdog
                // hands the fans back anyway. Say which of the two it picks
                // rather than implying a third behaviour that does not exist.
                Text("With this off, fans are not restored the moment you quit; but once the helper has gone about 20 seconds without a heartbeat from FanGlass it hands them back to the system anyway.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var controlCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeader(title: String(localized: "Control"))

                HStack {
                    Text("Curve temperature source")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { state.settings.controlSource },
                        set: { state.settings.controlSource = $0 }
                    )) {
                        ForEach(state.groups.filter { $0.id != "ambient" && $0.id != "other" }) { group in
                            Text(group.name).tag(group.id)
                        }
                        Text("Hottest sensor").tag("max")
                    }
                    .pickerStyle(.menu)
                    // 180, not 160: "Hottest sensor" is a third wider than
                    // the Chinese label it replaces.
                    .frame(width: 180)
                }

                // Key families differ per chip generation, so a curve carried
                // over from another Mac can point at a group this one does not
                // have. Substituting a different signal silently is exactly the
                // kind of thing a fan controller must never do.
                if state.controlSourceMissing {
                    Text("The selected control source is not available on this Mac; the hottest sensor is used instead.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text("RPM hysteresis")
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

                Text("Hysteresis keeps the fan speed from jittering around a boundary value; set it to 0 to update on every sample.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var alertCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeader(title: String(localized: "Overheat alert"))

                HStack {
                    Text("Temperature threshold")
                        .font(.system(size: 12))
                    Spacer()
                    Text(state.settings.overheatThreshold <= 0
                         ? String(localized: "Off")
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

                Text("Sends a system notification when any sensor (except Ambient and Other) goes over the threshold; drag to the far left to switch it off.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - privileged helper

    private var busy: Bool { state.installPhase.isBusy }

    private var helperDetail: String {
        guard let version = state.helperVersion else { return String(localized: "Not installed") }
        return state.helperOutdated
            ? String(format: String(localized: "Outdated (v%lld)"), version)
            : String(format: String(localized: "Running · v%lld"), version)
    }

    private var helperCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeader(title: String(localized: "Privileged Helper"), detail: helperDetail)

                Text("Writing fan speeds requires root privileges and is done by a background privileged helper. Reading sensors needs no privileges.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if state.helperOutdated {
                    Text(String(format: String(localized: "The installed helper is an older version (v%lld, v%lld required); update it before the new commands can take effect."),
                                state.helperVersion ?? 0, HelperProtocol.version))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    if !state.helperAvailable {
                        Button("Install Helper…") { state.beginInstall() }
                            .buttonStyle(LiquidButtonStyle(prominent: true))
                            .disabled(busy)
                    } else {
                        Button(state.helperOutdated ? "Update Helper…" : "Reinstall Helper…") { state.beginInstall() }
                            .buttonStyle(LiquidButtonStyle(prominent: state.helperOutdated))
                            .disabled(busy)
                        Button("Uninstall Helper…") { state.uninstallHelper() }
                            .buttonStyle(LiquidButtonStyle())
                            .disabled(busy)
                    }
                    Spacer()
                    Button("Refresh") { state.refreshHelperStatus() }
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
