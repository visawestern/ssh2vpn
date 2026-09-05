import Foundation

/// Input profile data needed to build a tunnel configuration.
public struct VPNProfileInput: Equatable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var privateKey: String
    public var hostKey: String
    public var dnsServers: [String]

    public init(
        host: String,
        port: Int,
        username: String,
        password: String = "",
        privateKey: String = "",
        hostKey: String = "",
        dnsServers: [String] = []
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privateKey = privateKey
        self.hostKey = hostKey
        self.dnsServers = dnsServers
    }
}

/// Result of validating and building a tunnel configuration.
public struct VPNConfiguration: Equatable {
    public var providerBundleIdentifier: String
    public var serverAddress: String
    /// includeAllNetworks must stay ON: per Apple docs, without it the system
    /// routes only "designated system services" (DNS, some system traffic)
    /// through the tunnel while app traffic bypasses it (our delta=0
    /// signature: DNS arrives, app TCP never does). The old Code=1 fear
    /// dated from before the save→reload→start fix; the flag itself is the
    /// documented way to scope connections to a packet tunnel.
    public var includeAllNetworks: Bool
    public var enforceRoutes: Bool
    public var providerConfiguration: [String: Any]

    public static func == (lhs: VPNConfiguration, rhs: VPNConfiguration) -> Bool {
        lhs.providerBundleIdentifier == rhs.providerBundleIdentifier &&
        lhs.serverAddress == rhs.serverAddress &&
        lhs.includeAllNetworks == rhs.includeAllNetworks &&
        lhs.enforceRoutes == rhs.enforceRoutes &&
        NSDictionary(dictionary: lhs.providerConfiguration).isEqual(to: rhs.providerConfiguration)
    }
}

public enum VPNConfigurationError: Error, Equatable {
    case emptyHost
    case invalidPort
    case missingCredentials
    case emptyProviderBundleIdentifier
}

extension VPNConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyHost:
            return "No server address was provided. Enter your VPS host."
        case .invalidPort:
            return "The SSH port is invalid. Use a port between 1 and 65535."
        case .missingCredentials:
            return "No login credentials found. Add a password or an SSH private key for this server."
        case .emptyProviderBundleIdentifier:
            return "The tunnel provider is not configured."
        }
    }
}

/// Pure builder for the NETunnelProviderProtocol configuration.
/// No NetworkExtension imports so it is fully testable on macOS.
public enum VPNConfigurationBuilder {

    /// Builds tunnel configuration for the given profile.
    public static func build(
        profile: VPNProfileInput,
        providerBundleIdentifier: String
    ) throws -> VPNConfiguration {
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw VPNConfigurationError.emptyHost }
        guard (1...65535).contains(profile.port) else { throw VPNConfigurationError.invalidPort }
        let bundleId = providerBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty else { throw VPNConfigurationError.emptyProviderBundleIdentifier }
        // Password and privateKey are read from Keychain by identity; but a
        // tunnel with no auth at all is unusable.
        if profile.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            profile.password.isEmpty {
            throw VPNConfigurationError.missingCredentials
        }

        var providerConfig: [String: Any] = [
            "host": host,
            "port": profile.port,
            "username": profile.username
        ]
        if !profile.hostKey.isEmpty {
            providerConfig["hostKey"] = profile.hostKey
        }
        if !profile.dnsServers.isEmpty {
            providerConfig["dnsServers"] = profile.dnsServers
        }

        return VPNConfiguration(
            providerBundleIdentifier: providerBundleIdentifier,
            serverAddress: host,
            includeAllNetworks: true,
            enforceRoutes: true,
            providerConfiguration: providerConfig
        )
    }
}
