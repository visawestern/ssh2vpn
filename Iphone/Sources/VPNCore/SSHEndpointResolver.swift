import Darwin

public struct SSHResolvedEndpoint: Equatable, Sendable {
    public let ipv4: [String]
    public let ipv6: [String]

    public init(ipv4: [String], ipv6: [String]) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    /// One stable connect target chosen once per tunnel. Prefer IPv4 so the
    /// connection does not depend on the local gateway's IPv6 reachability.
    public func primaryTarget() -> String? {
        ipv4.first ?? ipv6.first
    }
}

public enum SSHEndpointResolverError: Error, Equatable {
    case cannotResolve
}

public enum SSHEndpointResolver {
    public static func resolve(_ host: String) throws -> SSHResolvedEndpoint {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            throw SSHEndpointResolverError.cannotResolve
        }
        defer { freeaddrinfo(result) }

        var ipv4 = [String](); var ipv6 = [String]()
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            if status == 0 {
                let address = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if entry.pointee.ai_family == AF_INET, !ipv4.contains(address) { ipv4.append(address) }
                if entry.pointee.ai_family == AF_INET6, !ipv6.contains(address) { ipv6.append(address) }
            }
            cursor = entry.pointee.ai_next
        }
        guard !ipv4.isEmpty || !ipv6.isEmpty else { throw SSHEndpointResolverError.cannotResolve }
        return SSHResolvedEndpoint(ipv4: ipv4, ipv6: ipv6)
    }
}
