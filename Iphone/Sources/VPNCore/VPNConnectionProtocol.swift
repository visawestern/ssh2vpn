import Foundation

/// Errors that can occur during VPN connection lifecycle.
public enum VPNConnectionError: Error, Equatable {
    case loadFailed(String)
    case saveFailed(String)
    case startFailed(String)
    case invalidConfiguration(String)
    case keychainError(String)
    case alreadyConnected
    case notConfigured
}

/// Protocol abstracting the VPN connection lifecycle.
/// Conforms in App target; test via mock in VPNCoreTests.
public protocol VPNConnectionManager: AnyObject {
    var isConnected: Bool { get }
    var isConnecting: Bool { get }

    func start(
        host: String,
        port: Int,
        username: String,
        providerBundleIdentifier: String,
        providerConfiguration: [String: Any],
        completion: @escaping (VPNConnectionError?) -> Void
    )
    func stop()
}
