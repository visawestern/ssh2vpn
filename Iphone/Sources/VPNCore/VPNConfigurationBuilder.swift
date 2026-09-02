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
    /// includeAllNetworks must stay OFF: PacketTunnelProvider installs its own
    /// default routes / exclusion rules, so capturing all networks here would
    /// conflict and cause NEVPNErrorDomain Code=1.
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
            includeAllNetworks: false,
            enforceRoutes: true,
            providerConfiguration: providerConfig
        )
    }
}
