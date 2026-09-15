import Foundation

/// When a pooled SSH connection must renegotiate its session keys, mirroring
/// OpenSSH's `RekeyLimit default 4G 1h`. Either threshold alone is enough:
/// bulk downloads trip the byte limit, idle-but-open admin sessions trip the
/// timer. Pure value type; the pool supplies `bytesSinceRekey` (both
/// directions, counted on the relay path) and seconds since the last
/// (re)keying, and calls `NIOSSHHandler.rekey()` for due connections.
public struct SSHRekeyPolicy: Sendable {
    public var byteLimit: UInt64
    public var interval: TimeInterval

    public init(byteLimit: UInt64 = SSHCrowdProfile.rekeyByteLimit,
                interval: TimeInterval = SSHCrowdProfile.rekeyInterval) {
        self.byteLimit = byteLimit
        self.interval = interval
    }

    public func shouldRekey(bytesSinceRekey: UInt64, elapsed: TimeInterval) -> Bool {
        bytesSinceRekey >= byteLimit || elapsed >= interval
    }
}
