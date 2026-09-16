import Foundation

/// Server-side egress self-check: what the phone asks the USER'S OWN server
/// to report about itself, over the already-authenticated SSH session.
///
/// Privacy design (App Review 5.1.1 / 5.4): the phone itself contacts NO
/// third-party service for this check. The only network peer of the phone
/// here is the user's own server. The server — the user's own machine —
/// reports its public IP (asking an IP-echo service itself, exactly as if
/// the user ran curl there by hand) and its web reachability. If the server
/// has no curl/wget, the check reports "unverified" instead of failing.
public enum SSHExecCheck {

    /// Runs on the server via SSH exec. Prints two lines:
    ///   IP:<public IPv4 or empty>
    ///   WEB:<HTTP code from generate_204 or "none">
    /// curl-first, wget fallback; every fetch is time-boxed so a filtered
    /// network degrades to empty output instead of hanging the channel.
    public static let egressCommand = """
    echo "IP:$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null || wget -qO- -T 4 https://api.ipify.org 2>/dev/null)"; \
    echo "WEB:$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 https://www.google.com/generate_204 2>/dev/null || echo none)"
    """

    /// Parsed server report. Nil fields mean "the server could not tell"
    /// (no curl/wget, filtered network) — unverified, never a bypass claim.
    public struct Report: Equatable, Sendable {
        public var ip: String?
        public var web: String?
        public init(ip: String? = nil, web: String? = nil) {
            self.ip = ip
            self.web = web
        }
    }

    /// Parses raw exec output into a Report. Tolerates extra lines, CRLF,
    /// surrounding whitespace and bracketed IPv6.
    public static func parse(_ output: String) -> Report {
        var r = Report()
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("IP:") {
                let v = TunnelSelfTest.normalizeIP(String(line.dropFirst(3)))
                r.ip = v.isEmpty ? nil : v
            } else if line.hasPrefix("WEB:") {
                let v = line.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
                r.web = v.isEmpty ? nil : v
            }
        }
        return r
    }

    /// True when bytes look like an SSH server banner ("SSH-2.0-...").
    /// Used by the app-side check that opens the user's own server port
    /// through the tunnel: a banner proves routing + relay + server in one.
    public static func looksLikeSSHBanner(_ bytes: Data) -> Bool {
        guard let s = String(data: bytes.prefix(255), encoding: .utf8) else { return false }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("SSH-")
    }
}
