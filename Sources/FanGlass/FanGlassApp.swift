// FanGlassApp.swift — app entry: menu-bar agent + optional main window.
import SwiftUI

extension Notification.Name {
    static let fanglassOpenMainWindow = Notification.Name("fanglass.openMainWindow")
}

@main
struct FanGlassApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("FanGlass", id: "main") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 880, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 940, height: 680)
        // Menu-bar agent: do not pop the dashboard on launch / login / restore.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "fan.fill")
                Text(state.hottestTemperature > 0
                     ? String(format: "%.0f°", state.hottestTemperature)
                     : "--°")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Hide Dock + Cmd-Tab; LSUIElement in Info.plist is the other half.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Finder / Spotlight re-open of an already-running agent: show the window.
        NotificationCenter.default.post(name: .fanglassOpenMainWindow, object: nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if AppState.restoreAutoOnQuitFlag {
            HelperClient.shared.autoAll()
        }
    }

    /// Raise an already-created dashboard window (MenuBarExtra panels are smaller / untitled).
    static func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where isMainWindow(window) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == "main" { return true }
        guard window.styleMask.contains(.titled) else { return false }
        return window.frame.width >= 700
    }
}

/// Lets SwiftUI reach the hosting NSWindow for small tweaks, and periodically
/// strips native scrollers from every NSScrollView SwiftUI creates (the custom
/// glass thumb in GlassScrollView replaces them). `.scrollIndicators(.hidden)`
/// alone is not honored on macOS 26.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
        context.coordinator.start(with: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
    }

    final class Coordinator {
        var timer: Timer?
        weak var view: NSView?

        func start(with view: NSView) {
            self.view = view
            timer?.invalidate()
            DispatchQueue.main.async { [weak self] in self?.killScrollers() }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.killScrollers()
            }
        }

        private func killScrollers() {
            guard let content = view?.window?.contentView else { return }
            func walk(_ v: NSView) {
                if let sv = v as? NSScrollView {
                    // .overlay first: legacy-style scrollers reserve a ~16 pt
                    // gutter that shifts the content off-center to the left.
                    sv.scrollerStyle = .overlay
                    sv.hasVerticalScroller = false
                    sv.hasHorizontalScroller = false
                }
                v.subviews.forEach(walk)
            }
            walk(content)
        }
    }
}
