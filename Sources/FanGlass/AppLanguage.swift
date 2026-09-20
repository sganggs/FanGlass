// AppLanguage.swift — the in-app UI language override.
//
// The app follows the system language by default: English source strings are
// the localization keys, Resources/zh-Hans.lproj carries the Simplified Chinese
// wording, and the bundle picks whichever the user's language list asks for.
// The override below is the standard per-app one — the same AppleLanguages key
// System Settings → General → Language & Region → Applications writes — and is
// only ever written from the Settings picker.
import AppKit
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chineseSimplified = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// FanGlass's own key, deliberately not `AppleLanguages`: the user's choice
    /// is a setting in its own right, and reading it back must not depend on
    /// how macOS happens to have merged the language list.
    static let defaultsKey = "FanGlassUILanguage"
    private static let appleLanguagesKey = "AppleLanguages"

    static var current: AppLanguage {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: defaultsKey) {
            return AppLanguage(rawValue: raw) ?? .system
        }
        // No FanGlass key yet, but the user may still have pinned a language in
        // System Settings → General → Language & Region → Applications, which
        // writes AppleLanguages into FanGlass's OWN defaults domain. Read that
        // domain by name rather than through `standard`, whose search list also
        // carries the global (system-wide) AppleLanguages — every Mac has one,
        // and taking it would report a per-app override that does not exist.
        // Strictly a read: writing here would pin the app to whatever the list
        // happened to say at first launch.
        guard let identifier = Bundle.main.bundleIdentifier,
              let domain = defaults.persistentDomain(forName: identifier),
              let first = (domain[appleLanguagesKey] as? [String])?.first?.lowercased()
        else { return .system }
        if first.hasPrefix("zh") { return .chineseSimplified }
        if first.hasPrefix("en") { return .english }
        // Some third language: FanGlass has no table for it, so the bundle
        // falls back to English — which is what "follow the system" means here.
        return .system
    }

    /// Every language names itself, the way system language pickers do. Reading
    /// the endonym out of `Locale` also keeps the Chinese name out of the source
    /// tree, where the English strings are the keys.
    var title: String {
        switch self {
        case .system:
            return String(localized: "Follow system")
        default:
            let locale = Locale(identifier: rawValue)
            return locale.localizedString(forIdentifier: rawValue) ?? rawValue
        }
    }

    /// Write (or clear) the per-app override. Called only when the user picks a
    /// language: an ordinary launch must never touch `AppleLanguages`, or
    /// FanGlass would pin itself to whatever the list said the first time.
    func apply() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: AppLanguage.defaultsKey)
        switch self {
        case .system:
            defaults.removeObject(forKey: AppLanguage.appleLanguagesKey)
        default:
            defaults.set([rawValue], forKey: AppLanguage.appleLanguagesKey)
        }
    }
}

/// Quit and come back — a language change only reaches the loaded bundle on the
/// next launch.
enum AppRelaunch {
    static func now() {
        // Single-quoted for /bin/sh, with any apostrophe in the path escaped:
        // an app installed under a folder called "Sam's" must still come back.
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open '\(path)'"]
        try? process.run()
        // Quitting first is what makes LSMultipleInstancesProhibited harmless.
        // The normal quit path still runs: settings are flushed and the fans go
        // back to automatic control, and the new instance re-applies the saved
        // config once its helper probe answers.
        NSApp.terminate(nil)
    }
}
