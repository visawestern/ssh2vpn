import Crypto
import Foundation

/// Device addressing for one VPN instance, derived deterministically from a
/// stable per-install broker id.
///
/// Both ends share one /30: network 10.203.h1.(h2&0xFC), gateway +1, device
/// +2, mask 255.255.255.252, plus fd00:203:h1h2::/64 (gateway ::1, device
/// ::2). Masking the low two bits of h2 guarantees a valid /30 network base
/// for ANY hash bytes — five-octet strings are not IPv4 and make iOS silently
/// drop the v4 tunnel settings (all IPv4 then bypasses the tunnel). The
/// gateway computes the identical pair in gateway.py: keep them in sync.
public struct TunnelDevice: Equatable, Sendable {
    public static let v4SubnetMask = "255.255.255.0"
    public static let v6PrefixLength = 64

    /// The gateway end of the /30 link (real: gateway's own NAT exit).
    public let gatewayIPv4: String
    /// This device's address on the /30 link.
    public let ipv4Address: String
    /// This device's address on the /64 link.
    public let ipv6Address: String

    public static func derive(brokerID: String) throws -> TunnelDevice {
        guard !brokerID.isEmpty else { throw TunnelDeviceError.invalidBrokerID }
        let digest = Array(SHA256.hash(data: Data(brokerID.utf8)))
        guard digest.count >= 2 else { throw TunnelDeviceError.invalidBrokerID }
        let h1 = Int(digest[0])
        let base = Int(digest[1]) & 0xFC
        return TunnelDevice(
            gatewayIPv4: "10.203.\(h1).\(base + 1)",
            ipv4Address: "10.203.\(h1).\(base + 2)",
            ipv6Address: String(format: "fd00:203:%02x%02x::2", h1, Int(digest[1]))
        )
    }
}

public enum TunnelDeviceError: Error, Equatable, Sendable {
    case invalidBrokerID
}