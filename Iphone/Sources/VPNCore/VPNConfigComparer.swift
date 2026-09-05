import Foundation

/// Plain-data mirror of the live NETunnelProviderProtocol values the app
/// manages (bundle id, server, routes, enabled flag, provider dictionary).
/// Lives in VPNCore without any NetworkExtension import so the "reuse or
/// rewrite?" decision is unit-testable.
public struct VPNProtocolSnapshot {
    public var providerBundleIdentifier: String
    public var serverAddress: String
    public var enforceRoutes: Bool
    public var includeAllNetworks: Bool
    public var isEnabled: Bool
    public var providerConfiguration: [String: Any]

    public init(
        providerBundleIdentifier: String,
        serverAddress: String,
        enforceRoutes: Bool,
        includeAllNetworks: Bool = true,
        isEnabled: Bool,
        providerConfiguration: [String: Any]
    ) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.serverAddress = serverAddress
        self.enforceRoutes = enforceRoutes
        self.includeAllNetworks = includeAllNetworks
        self.isEnabled = isEnabled
        self.providerConfiguration = providerConfiguration
    }
}

/// Decides whether the stored system VPN configuration already equals the
/// desired one. On match the app skips saveToPreferences/loadFromPreferences
/// entirely and just starts the tunnel — no redundant system churn, no extra
/// status flapping, no wasted failure surface.
public enum VPNConfigComparer {
    public static func isSame(current: VPNProtocolSnapshot, desired: VPNProtocolSnapshot) -> Bool {
        current.providerBundleIdentifier == desired.providerBundleIdentifier &&
        current.serverAddress == desired.serverAddress &&
        current.enforceRoutes == desired.enforceRoutes &&
        current.includeAllNetworks == desired.includeAllNetworks &&
        current.isEnabled == desired.isEnabled &&
        NSDictionary(dictionary: current.providerConfiguration).isEqual(to: desired.providerConfiguration)
    }
}
