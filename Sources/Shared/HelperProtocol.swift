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
    /// v5: per-connection receive timeout and concurrent serving (a silent
    /// client could wedge the accept loop and with it all fan control), fan
    /// index validation, and a watchdog that no longer counts sleep as silence.
    /// v6: `ping`/`status` are pure queries and no longer refresh the watchdog
    /// deadline. A v5 daemon treats any traffic as proof someone is driving the
    /// fans, so the app's 10 s liveness ping kept a hold it had lost track of
    /// alive forever — the bump exists to get that daemon replaced, since the
    /// wire format itself is unchanged.
    public static let version = 6

    public static let socketPath = "/var/run/fanglass.sock"
}
