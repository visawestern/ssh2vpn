import Foundation

/// Describes a single-host exclude route for the kill switch (Chapter 6, p.104).
public struct GatewayExcludeRoute: Equatable, Sendable {
    public let address: String
    public let family: AddressFamily
    public let subnetMask: String?
    public let prefixLength: Int?

    public init(address: String, family: AddressFamily, subnetMask: String? = nil, prefixLength: Int? = nil) {
        self.address = address
        self.family = family
        self.subnetMask = subnetMask
        self.prefixLength = prefixLength
    }

    public enum AddressFamily: Sendable {
        case ipv4
        case ipv6
    }
}

/// Pure logic for building kill-switch exclude routes (Chapter 6, p.104).
///
/// Each resolved VPS IP is excluded as a single-host route — /32 for IPv4,
/// /128 for IPv6 — so the SSH control channel stays outside the packet tunnel
/// without black-holing a wider range. Converges chain C8.
public enum GatewayExcludedRoutes {
    public static func family(of ip: String) -> GatewayExcludeRoute.AddressFamily? {
        if ip.contains(":") { return .ipv6 }
        if ip.split(separator: ".").count == 4, ip.allSatisfy({ $0.isNumber || $0 == "." }) {
            return .ipv4
        }
        return nil
    }

    public static func exclude(ip: String, family: GatewayExcludeRoute.AddressFamily) -> GatewayExcludeRoute? {
        switch family {
        case .ipv4:
            return GatewayExcludeRoute(address: ip, family: .ipv4, subnetMask: "255.255.255.255")
        case .ipv6:
            return GatewayExcludeRoute(address: ip, family: .ipv6, prefixLength: 128)
        }
    }

    public static func excludes(for endpoint: SSHResolvedEndpoint) -> [GatewayExcludeRoute] {
        var routes: [GatewayExcludeRoute] = []
        for ip in endpoint.ipv4 {
            if let route = exclude(ip: ip, family: .ipv4) { routes.append(route) }
        }
        for ip in endpoint.ipv6 {
            if let route = exclude(ip: ip, family: .ipv6) { routes.append(route) }
        }
        return routes
    }
}
