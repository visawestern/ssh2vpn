import Foundation

/// Launch command for the bundled UDP-over-TCP helper.
///
/// No separate files anywhere: `udp_relay.py` ships INSIDE the app bundle
/// (`Sources/VPNCore/Resources`) and runs on the VPS via a single SSH exec
/// as VISIBLE PLAINTEXT — a quoted heredoc on fd 3:
///
///     python3 -u /dev/fd/3 3<<'SSH2VPN_HELPER_EOF'
///     <exact udp_relay.py source, byte for byte>
///     SSH2VPN_HELPER_EOF
///
/// Deliberately NO base64, NO `exec(...)`, NO argv blob: everything the
/// server runs is human-readable in the command itself (and in this repo),
/// so there is nothing obfuscated for anyone — user, reviewer, or scanner —
/// to wonder about. The quoted delimiter (`'...'`) makes the heredoc body
/// fully literal: no shell expansion, no quote processing, no escaping
/// trap. Nothing is written to disk on the server, no root, no TUN.
/// Stock `python3` (stdlib only) under a POSIX `sh` is the only server
/// requirement — the same one the product already states.
public enum UDPHelperCommand {
    /// Heredoc terminator. Must never appear as a full line of the source
    /// (enforced by `command(source:)` returning nil).
    public static let delimiter = "SSH2VPN_HELPER_EOF"

    /// Bundled helper source, nil when the resource is missing from the bundle.
    public static func source() -> String? {
        guard let url = Bundle.module.url(forResource: "udp_relay", withExtension: "py") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// One SSH exec launching `source` as a plaintext heredoc program on
    /// fd 3 (stdin stays free for the framed relay protocol). Nil on empty
    /// source or on a delimiter collision.
    public static func command(source: String) -> String? {
        guard !source.isEmpty else { return nil }
        for line in source.components(separatedBy: "\n") {
            guard line != delimiter else { return nil }
        }
        return "python3 -u /dev/fd/3 3<<'\(delimiter)'\n" + source + "\n" + delimiter
    }

    /// Ready-to-exec command from the bundled resource. Nil when the
    /// resource is missing (caller logs and retries — never crashes).
    public static func bundledCommand() -> String? {
        guard let src = source() else { return nil }
        return command(source: src)
    }
}
