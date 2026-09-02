import Crypto
import Foundation

/// Device addressing for one VPN instance, derived deterministically from a
/// stable per-install broker id.
///
/// The gateway derives the exact same subnet (10.203.<h1>.<h2>.0/30 gateway
/// `.1`, and fd00:203:<h1h2>::/64), so two devices sharing one VPS never
/// collide. h1/h2 are the first two bytes of SHA-256(brokerID).
public struct TunnelDevice: Equatable, Sendable {
    public static let v4SubnetMask = "255.255.255.252"
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
        let h2 = Int(digest[1])
        return TunnelDevice(
            gatewayIPv4: "10.203.\(h1).\(h2).1",
            ipv4Address: "10.203.\(h1).\(h2).2",
            ipv6Address: String(format: "fd00:203:%02x%02x::2", h1, h2)
        )
    }
}

public enum TunnelDeviceError: Error, Equatable, Sendable {
    case invalidBrokerID
}