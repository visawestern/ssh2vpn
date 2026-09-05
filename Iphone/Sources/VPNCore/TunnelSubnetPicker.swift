import Crypto
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// An IPv4 network (address + prefix length) for collision checks.
public struct IPv4Net: Equatable, Sendable, CustomStringConvertible {
    public let addr: UInt32  // host byte order
    public let prefix: Int   // 0...32

    public init(addr: UInt32, prefix: Int) {
        self.addr = addr
        self.prefix = max(0, min(32, prefix))
    }

    public init?(string: String, prefix: Int) {
        let parts = string.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        var a: UInt32 = 0
        for p in parts { a = (a << 8) | p }
        self.init(addr: a, prefix: prefix)
    }

    /// Network base address (host bits cleared).
    public var network: UInt32 {
        prefix == 0 ? 0 : (addr & (~UInt32(0) << (32 - prefix)))
    }

    /// True on ANY overlap (either direction): a /24 inside a foreign /8
    /// still collides for routing purposes.
    public func overlaps(_ other: IPv4Net) -> Bool {
        let short = min(prefix, other.prefix)
        guard short > 0 else { return true } // /0 overlaps everything
        let mask: UInt32 = ~UInt32(0) << (32 - short)
        return (network & mask) == (other.network & mask)
    }

    public var description: String {
        "\(addr >> 24).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)/\(prefix)"
    }
}

/// Picks a free /24 for the utun interface.
///
/// The tunnel subnet used to be a blind SHA256 pick. If it lands inside an
/// occupied network (hotel WiFi on 10.x, office LAN, another VPN's utun),
/// iOS silently drops our IPv4 settings and ALL IPv4 bypasses the tunnel
/// with zero diagnostics. So: enumerate live interfaces, take the stable
/// primary when free, otherwise fall back — silently (user never sees this),
/// but the decision is always logged.
public enum TunnelSubnetPicker {
    /// Ordered /24 candidates for one install. Primary is the historic
    /// TunnelDevice pick (stable IP across reconnects); fallbacks live in
    /// ranges home/office routers almost never serve.
    public static func candidates(brokerID: String) -> [IPv4Net] {
        let digest = Array(SHA256.hash(data: Data(brokerID.utf8)))
        func b(_ i: Int) -> UInt32 { UInt32(digest[i % digest.count]) }
        let h1 = b(0)
        // 10.203.h1.0/24 (historic), 172.31.h1.0/24, 192.168.(200+h1%55).0/24
        return [
            IPv4Net(addr: (10 << 24) | (203 << 16) | (h1 << 8), prefix: 24),
            IPv4Net(addr: (172 << 24) | (31 << 16) | (h1 << 8), prefix: 24),
            IPv4Net(addr: (192 << 24) | (168 << 16) | ((200 + h1 % 55) << 8), prefix: 24),
        ]
    }

    public struct Choice: Equatable, Sendable {
        public let net: IPv4Net
        /// Device address inside net (.2) — mirrors the historic layout.
        public var deviceAddress: String {
            let base = net.network
            return "\(base >> 24).\((base >> 16) & 0xFF).\((base >> 8) & 0xFF).2"
        }
        /// True when every candidate collided and we kept primary anyway.
        public let collided: Bool
    }

    public static func pick(brokerID: String, occupied: [IPv4Net]) -> Choice {
        let all = candidates(brokerID: brokerID)
        for net in all where !occupied.contains(where: { $0.overlaps(net) }) {
            return Choice(net: net, collided: false)
        }
        return Choice(net: all[0], collided: true)
    }
}

/// Live IPv4 networks of this device (extension-safe: getifaddrs needs no
/// entitlement). Skips loopback; stale foreign utuns count as occupied —
/// their routes are alive.
public enum LocalInterfaceNets {
    /// "name addr/prefix" lines for diagnostics (app + extension).
    public static func describeInterfaces() -> [String] {
        #if canImport(Darwin)
        var out: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return ["getifaddrs-failed"] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cursor {
            defer { cursor = node.pointee.ifa_next }
            let flags = node.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let sa = node.pointee.ifa_addr else { continue }
            let name = String(cString: node.pointee.ifa_name)
            if sa.pointee.sa_family == UInt8(AF_INET),
               let sm = node.pointee.ifa_netmask {
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }.byteSwapped
                let m = sm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }.byteSwapped
                let net = IPv4Net(addr: a, prefix: m.nonzeroBitCount)
                out.append("\(name) \(net)")
            } else if sa.pointee.sa_family == UInt8(AF_INET6) {
                out.append("\(name) v6")
            } else {
                out.append("\(name) fam=\(sa.pointee.sa_family)")
            }
        }
        return out.sorted()
        #else
        return []
        #endif
    }

    public static func listIPv4Networks() -> [IPv4Net] {
        #if canImport(Darwin)
        var result: [IPv4Net] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cursor {
            defer { cursor = node.pointee.ifa_next }
            let flags = node.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let sa = node.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  let sm = node.pointee.ifa_netmask else { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }.byteSwapped
            let m = sm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }.byteSwapped
            let prefix = m.nonzeroBitCount
            result.append(IPv4Net(addr: a, prefix: prefix))
        }
        return result
        #else
        return []
        #endif
    }
}
