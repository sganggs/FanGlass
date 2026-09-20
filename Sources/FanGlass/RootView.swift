// RootView.swift — solid background + floating glass top bar (system-app style)
// + tab content scrolling underneath the bar.
import SwiftUI

enum AppTab: String, CaseIterable {
    case dashboard, fans, settings
    var title: String {
        switch self {
        case .dashboard: return "仪表盘"
        case .fans: return "风扇控制"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .fans: return "fan"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var tab: AppTab = {
        if CommandLine.arguments.contains("--tab-fans") { return .fans }
        if CommandLine.arguments.contains("--tab-settings") { return .settings }
        return .dashboard
    }()
    @State private var contentScrolled = false

    private var heat: Double {
        max(0, min(1, (state.hottestTemperature - 40) / 60))
    }

    var body: some View {
        ZStack(alignment: .top) {
            SolidBackground(heat: heat, showStrip: false)

            // Content fills the whole window from y=0; each tab's GlassScrollView
            // adds a top content margin so it begins below the bar and scrolls under it.
            Group {
                switch tab {
                case .dashboard: DashboardView(onScrolled: { contentScrolled = $0 })
                case .fans: FansView(onScrolled: { contentScrolled = $0 })
                case .settings: SettingsView(onScrolled: { contentScrolled = $0 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .id(tab)

            glassTopBar
        }
        // Ignore the title-bar safe area for ALL layers at once — letting the top
        // bar start at the inset while content reached y=0 is what split the bar
        // into two misaligned layers with an unblurred strip on top.
        .ignoresSafeArea()
        .background(WindowAccessor().frame(width: 0, height: 0))
        .animation(.easeOut(duration: 0.22), value: tab)
        .onChange(of: tab) { _, _ in contentScrolled = false }
        // Deep link from the menu-bar panel. onAppear covers the window being
        // opened by that click; onChange covers it already being open.
        .onAppear { consumePendingTab() }
        .onChange(of: state.pendingTab) { _, _ in consumePendingTab() }
        .sheet(isPresented: $state.showInstallSheet) {
            HelperOnboardingView().environmentObject(state)
        }
    }

    private func consumePendingTab() {
        guard let pending = state.pendingTab else { return }
        tab = pending
        state.pendingTab = nil
    }

    // MARK: - unified glass top bar (traffic-light area included)

    private var glassTopBar: some View {
        VStack(spacing: 0) {
            // ambient heat strip hugging the very top edge of the window
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            GlassPalette.heatColor(heat).opacity(0),
                            GlassPalette.heatColor(heat),
                            GlassPalette.heatColor(heat).opacity(0),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 3)

            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    SpinningFanView(rpm: state.primaryFanRPM)
                    Text("FanGlass")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                }
                .padding(.leading, 72) // clear the traffic lights

                Spacer()

                LiquidSegmentedPicker(
                    options: AppTab.allCases.map { ($0, $0.title) },
                    selection: $tab
                )
                .frame(width: 300)

                Spacer()

                HelperStatusPill()
            }
            .padding(.horizontal, 20)
            .frame(height: 52)

            // hairline separator — invisible until content scrolls under the bar
            Rectangle()
                .fill(Color.black.opacity(0.16))
                .frame(height: 1)
                .opacity(contentScrolled ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: contentScrolled)
        }
        .background {
            // macOS 26 Liquid Glass: real refractive glass over the window's
            // own content — cards visibly blur as they scroll underneath.
            // (NSVisualEffectView .titlebar and SwiftUI materials both read
            // ~opaque white in light mode; glassEffect is the system look.)
            Color.clear
                .glassEffect(.regular, in: .rect)
                .overlay {
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .allowsHitTesting(false)
                .shadow(color: Color.black.opacity(contentScrolled ? 0.06 : 0),
                        radius: 6, x: 0, y: 2)
        }
        // soft glow spilling from the heat strip onto the glass bar
        .overlay(alignment: .top) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [GlassPalette.heatColor(heat).opacity(0.14),
                                 GlassPalette.heatColor(heat).opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(height: 16)
                .padding(.top, 3)
                .allowsHitTesting(false)
        }
    }
}

struct HelperStatusPill: View {
    @EnvironmentObject var state: AppState

    private enum Status { case connected, outdated, missing }

    private var status: Status {
        if !state.helperAvailable { return .missing }
        return state.helperOutdated ? .outdated : .connected
    }

    private var color: Color {
        switch status {
        case .connected: return .green
        case .outdated:  return .orange
        case .missing:   return .red
        }
    }

    private var label: String {
        switch status {
        case .connected: return "助手已连接"
        case .outdated:  return "助手版本过旧"
        case .missing:   return "助手未安装"
        }
    }

    // The most visible helper indicator in the window; make it fix the problem
    // it reports instead of only naming it.
    var body: some View {
        if status == .connected {
            pill
        } else {
            Button {
                state.requestHelperInstall(reason: status == .outdated ? .outdated : .statusPill)
            } label: {
                pill
            }
            .buttonStyle(.plain)
            .help(status == .outdated ? "点按更新特权助手" : "点按安装特权助手")
        }
    }

    private var pill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.6), radius: 3)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            ZStack(alignment: .top) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.6))
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.85), Color.white.opacity(0.25)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
        }
    }
}
