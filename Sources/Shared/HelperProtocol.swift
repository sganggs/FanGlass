// HelperProtocol.swift — the wire contract between FanGlass.app and the
// privileged helper. Compiled into BOTH targets so the two can never drift.
import Foundation

public enum HelperProtocol {
    /// Bumped whenever the app needs a helper newer than one already installed.
    /// launchd keeps running whatever daemon is on disk, so an old helper would
    /// otherwise answer `ping` happily and silently ignore newer commands; the
    /// app compares this against the version `ping` reports and offers to update.
    /// v4: peer-uid authorization on the socket, runtime-typed SMC writes, and
    /// restore-to-auto when writes keep failing. An older daemon still answers
    /// every command, so the app offers an update rather than refusing to talk.
    public static let version = 4

    public static let socketPath = "/var/run/fanglass.sock"
}
