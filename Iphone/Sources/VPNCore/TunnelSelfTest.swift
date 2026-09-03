import Foundation

/// Pure verdict logic for the post-connect self-test (see TunnelSelfTestTests).
/// After the tunnel reports CONNECTED, the app fetches its egress IP from a
/// known echo service and compares it with the server's IP: equal means the
/// traffic really flows through the VPS, anything else means a bypass.
public enum TunnelSelfTest {

    public enum EgressVerdict: Equatable, Sendable {
        /// Observed egress equals the server IP — traffic goes via the server.
        case viaServer
        /// Observed egress is a different IP — traffic bypasses the tunnel.
        case bypass(observed: String)
        /// The echo response was not usable (empty / not an IP).
        case unparseable(reason: String)
        /// The server's own IP is unknown (hostname that failed to resolve).
        case unknownExpected
    }

    /// Normalizes an echo-service response for comparison.
    public static func normalizeIP(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("[") && s.hasSuffix("]") && s.count > 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    public static func evaluate(expected: String?, observed: String) -> EgressVerdict {
        guard let expected, !normalizeIP(expected).isEmpty else { return .unknownExpected }
        let o = normalizeIP(observed)
        guard !o.isEmpty else { return .unparseable(reason: "empty response") }
        guard isIPLiteral(o) else { return .unparseable(reason: "not an IP literal") }
        return o == normalizeIP(expected) ? .viaServer : .bypass(observed: o)
    }

    /// Picks the IP the egress should match: a literal host is used directly,
    /// otherwise the first resolved IPv4; nil when neither is available.
    public static func pickExpected(host: String, resolvedIPv4: [String]) -> String? {
        let h = normalizeIP(host)
        if isIPLiteral(h) { return h }
        return resolvedIPv4.first.map(normalizeIP)
    }

    /// True for IPv4 dotted quads and IPv6 literals (contain ':'); hostnames
    /// never contain a colon, bracketed forms are stripped by normalizeIP.
    private static func isIPLiteral(_ s: String) -> Bool {
        if s.contains(":") { return true }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber), let v = Int(p) else { return false }
            return (0...255).contains(v)
        }
    }
}
