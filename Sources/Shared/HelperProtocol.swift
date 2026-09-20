// HelperProtocol.swift — the wire contract between FanGlass.app and the
// privileged helper. Compiled into BOTH targets so the two can never drift.
import Foundation

public enum HelperProtocol {
    /// Bumped whenever the app needs a helper newer than one already installed.
    /// launchd keeps running whatever daemon is on disk, so an old helper would
    /// otherwise answer `ping` happily and silently ignore newer commands; the
    /// app compares this against the version `ping` reports and offers to update.
    public static let version = 3

    public static let socketPath = "/var/run/fanglass.sock"
}
