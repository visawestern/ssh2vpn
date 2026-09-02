import Foundation
import Network

/// Result of validating a VPS before the gateway is bootstrapped over SSH.
public struct VPSEnvironment: Equatable, Sendable {
    public let osFamily: String
    public let libc: String?
    public let architecture: String
    public let pythonVersion: String
    public static let unknown = VPSEnvironment(osFamily: "unknown", libc: nil, architecture: "unknown", pythonVersion: "unknown")
}

public enum VPSValidationError: Error, Equatable, Sendable {
    case unsupportedOS
    case unsupportedArchitecture
    case unsupportedPython
    case unreachable
    case executionFailed
}

/// Describes the VPS the way the disposable gateway needs it: family + libc,
/// CPU architecture and a working python3 of the minimum version.
///
/// The evidence closures are injected so unit tests can feed literal VPS uname
/// / os-release / python output. Classification results are cached per
/// host:port fingerprint; reachability is deliberately never cached because it
/// is what decides READY on every (re)connect.
public struct VPSEnvironmentValidator: @unchecked Sendable {
    public var unameText: () throws -> String
    public var osReleaseText: (() throws -> String)?
    public var pythonVersionText: () throws -> String
    public var reachability: (String, Int, TimeInterval) throws -> Void
    public var minimumPythonVersion: (major: Int, minor: Int, patch: Int) = (3, 8, 0)
    /// Reconnect path: skip evidence collection, keep the connectivity gate.
    public var skip = false
    private var cache = VPSValidationCache()

    public init(
        unameText: @escaping () throws -> String,
        osReleaseText: (() throws -> String)? = nil,
        pythonVersionText: @escaping () throws -> String,
        reachability: @escaping (String, Int, TimeInterval) throws -> Void
    ) {
        self.unameText = unameText
        self.osReleaseText = osReleaseText
        self.pythonVersionText = pythonVersionText
        self.reachability = reachability
    }

    /// Full pipeline: classify (cached) then gate on outbound reachability.
    public func validate(host: String, port: Int, timeout: TimeInterval) throws -> VPSEnvironment {
        let environment = skip ? .unknown : try classify(host: host, port: port)
        try reachability(host, port, timeout)
        return environment
    }

    /// Bounded TCP connect used as the default gateway reachability probe.
    public static func defaultReachability(host: String, port: Int, timeout: TimeInterval) throws {
        guard let raw = NWEndpoint.Port(rawValue: UInt16(port)) else { throw VPSValidationError.unreachable }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: raw, using: .tcp)
        let queue = DispatchQueue(label: "pvvpn-validator-reachability")
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = ReachabilityOutcome()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.value = .success(())
                semaphore.signal()
                connection.cancel()
            case .failed:
                outcome.value = .failure(VPSValidationError.unreachable)
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        let result = semaphore.wait(timeout: .now() + timeout)
        connection.cancel()
        if result == .timedOut { throw VPSValidationError.unreachable }
        try outcome.value.get()
    }

    static func osFamily(from text: String) -> String? {
        text.range(of: "linux", options: .caseInsensitive) != nil ? "linux" : nil
    }

    static func architecture(from text: String) -> String? {
        if text.range(of: "aarch64", options: .caseInsensitive) != nil { return "aarch64" }
        if text.range(of: "x86_64", options: .caseInsensitive) != nil { return "x86_64" }
        return nil
    }

    static func parsePythonVersion(_ text: String) -> (major: Int, minor: Int, patch: Int)? {
        guard text.hasPrefix("Python") else { return nil }
        let rest = text.dropFirst("Python".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = rest.split(separator: " ").first else { return nil }
        let parts = token.split(separator: ".").prefix(3).map { Int($0) }
        guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { return nil }
        return (
            major: parts[0] ?? 0,
            minor: parts[1] ?? 0,
            patch: parts.count > 2 ? parts[2] ?? 0 : 0
        )
    }

    static func libc(from osRelease: String) -> String? {
        let lowered = osRelease.lowercased()
        if lowered.contains("alpine") { return "musl" }
        if ["ubuntu", "debian", "fedora", "rhel", "centos", "rocky", "arch", "opensuse"].contains(where: lowered.contains) {
            return "glibc"
        }
        return nil
    }

    private func classify(host: String, port: Int) throws -> VPSEnvironment {
        try cache.classify("\(host):\(port)") { try classifyUncached() }
    }

    private func classifyUncached() throws -> VPSEnvironment {
        let uname: String
        do { uname = try unameText() } catch { throw VPSValidationError.executionFailed }
        guard let family = Self.osFamily(from: uname) else { throw VPSValidationError.unsupportedOS }
        guard let arch = Self.architecture(from: uname) else { throw VPSValidationError.unsupportedArchitecture }

        let pythonText: String
        do { pythonText = try pythonVersionText() } catch { throw VPSValidationError.executionFailed }
        guard let version = Self.parsePythonVersion(pythonText),
              isAtLeast(version, minimumPythonVersion) else {
            throw VPSValidationError.unsupportedPython
        }

        var libc: String? = nil
        if let osReleaseText {
            if let release = try? osReleaseText() { libc = Self.libc(from: release) }
        }
        return VPSEnvironment(
            osFamily: family,
            libc: libc,
            architecture: arch,
            pythonVersion: "\(version.major).\(version.minor).\(version.patch)"
        )
    }

    private func isAtLeast(_ version: (major: Int, minor: Int, patch: Int), _ minimum: (major: Int, minor: Int, patch: Int)) -> Bool {
        (version.major, version.minor, version.patch) >= (minimum.major, minimum.minor, minimum.patch)
    }
}

private final class VPSValidationCache: @unchecked Sendable {
    private let lock = NSLock()
    private var classified: [String: VPSEnvironment] = [:]

    func classify(_ key: String, fallback: () throws -> VPSEnvironment) throws -> VPSEnvironment {
        lock.lock()
        defer { lock.unlock() }
        if let cached = classified[key] { return cached }
        let environment = try fallback()
        classified[key] = environment
        return environment
    }
}

private final class ReachabilityOutcome: @unchecked Sendable {
    var value: Result<Void, Error> = .failure(VPSValidationError.unreachable)
}