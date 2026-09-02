import Foundation

/// Serializable settings for Protocol / DNS / Advanced sub-screens.
/// Kept in VPNCore so it is unit-testable on macOS without the App target.
public struct AppSettingsState: Equatable {
    public var protocolName: String
    public var useCustomDNS: Bool
    public var primaryDNS: String
    public var secondaryDNS: String
    public var killSwitch: Bool
    public var connectOnDemand: Bool
    public var enableLogging: Bool

    public init(
        protocolName: String = "SSH2",
        useCustomDNS: Bool = false,
        primaryDNS: String = "1.1.1.1",
        secondaryDNS: String = "8.8.8.8",
        killSwitch: Bool = true,
        connectOnDemand: Bool = false,
        enableLogging: Bool = false
    ) {
        self.protocolName = protocolName
        self.useCustomDNS = useCustomDNS
        self.primaryDNS = primaryDNS
        self.secondaryDNS = secondaryDNS
        self.killSwitch = killSwitch
        self.connectOnDemand = connectOnDemand
        self.enableLogging = enableLogging
    }

    /// Resolved DNS servers: custom values when enabled, otherwise empty.
    public var resolvedDNSServers: [String] {
        guard useCustomDNS else { return [] }
        return [primaryDNS, secondaryDNS].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

public enum AppSettingsError: Error, Equatable {
    case encodingFailed
    case decodingFailed
}

/// Persists AppSettingsState to Data round-trippable through UserDefaults.
public struct AppSettingsCodec {
    public static let key = "vpn.settings"

    public static func encode(_ s: AppSettingsState) throws -> Data {
        let dict: [String: Any] = [
            "protocol": s.protocolName,
            "useCustomDNS": s.useCustomDNS,
            "primaryDNS": s.primaryDNS,
            "secondaryDNS": s.secondaryDNS,
            "killSwitch": s.killSwitch,
            "connectOnDemand": s.connectOnDemand,
            "enableLogging": s.enableLogging
        ]
        guard JSONSerialization.isValidJSONObject(dict) else { throw AppSettingsError.encodingFailed }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    public static func decode(_ data: Data) throws -> AppSettingsState {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AppSettingsError.decodingFailed
        }
        return AppSettingsState(
            protocolName: dict["protocol"] as? String ?? "SSH2",
            useCustomDNS: dict["useCustomDNS"] as? Bool ?? false,
            primaryDNS: dict["primaryDNS"] as? String ?? "1.1.1.1",
            secondaryDNS: dict["secondaryDNS"] as? String ?? "8.8.8.8",
            killSwitch: dict["killSwitch"] as? Bool ?? true,
            connectOnDemand: dict["connectOnDemand"] as? Bool ?? false,
            enableLogging: dict["enableLogging"] as? Bool ?? false
        )
    }
}
