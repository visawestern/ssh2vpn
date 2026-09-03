import Foundation

/// Knows which tunnel-provider bundle ids belong to this app — including the
/// legacy one from the com.sshtunnel era. Stale profiles must be deleted (they
/// can never connect again) and their status notifications must be ignored.
public enum TunnelOwnership {
    public static let legacyProviderBundleID = "com.sshtunnel.app.packet-tunnel"
    public static let currentProviderBundleID = "com.ssh2vpn.app.packet-tunnel"

    public static func isStaleLegacy(bundleID: String?) -> Bool {
        bundleID == legacyProviderBundleID
    }
}

/// Decodes NEProviderStopReason without importing NetworkExtension (keeps
/// VPNCore portable). Values match Apple's NEProviderStopReason enum.
public enum TunnelStopReason {
    public static func text(forRawValue v: Int) -> String {
        switch v {
        case 0: return "none"
        case 1: return "userInitiated"
        case 2: return "providerFailed"
        case 3: return "noNetworkAvailable"
        case 4: return "unrecoverableNetworkChange"
        case 5: return "providerDisabled"
        case 6: return "authenticationCanceled"
        case 7: return "configurationFailed"
        case 8: return "idleTimeout"
        case 9: return "configurationDisabled"
        case 10: return "configurationRemoved"
        case 11: return "superceded"
        case 12: return "userLogout"
        case 13: return "userSwitch"
        case 14: return "connectionFailed"
        default: return "unknown(\(v))"
        }
    }
}
