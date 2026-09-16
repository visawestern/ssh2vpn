import Foundation

/// Server-side egress self-check: what the phone asks the USER'S OWN server
/// to report about itself, over the already-authenticated SSH session.
///
/// Privacy design (App Review 5.1.1 / 5.4): NOTHING in this check contacts
/// any third party — not from the phone, not from the server either. The
/// phone's only network peer here is the user's own server, and the server
/// only reads its OWN kernel routing table (a local lookup that sends zero
/// packets anywhere). No curl, no wget, no IP-echo service, no fetch of any
/// kind. If the server cannot answer (no iproute2), the check reports
/// "unverified" instead of failing.
public enum SSHExecCheck {

    /// Runs on the server via SSH exec. Prints two lines:
    ///   IP:<egress source IPv4 from the routing table, or empty>
    ///   WEB:<"route" when a default egress route exists, else "none">
    /// `ip route get` is a LOCAL FIB lookup — it consults the kernel's
    /// routing table and sends no traffic. Same for `ip route show`.
    /// Worst case (no `ip` tool, no default route) degrades to empty
    /// output — unverified, never a false claim in either direction.
    public static let egressCommand = """
    echo "IP:$(ip -4 route get 8.8.8.8 2>/dev/null | sed -n 's/.* src \\([0-9.]*\\).*/\\1/p')"; \
    echo "WEB:$(ip -4 route show default 2>/dev/null | grep -q . && echo route || echo none)"
    """

    /// Parsed server report. Nil fields mean "the server could not tell"
    /// (no iproute2, no route) — unverified, never a bypass claim.
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
