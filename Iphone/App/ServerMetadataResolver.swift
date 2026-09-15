import Foundation
import Network

public struct ServerGeoInfo: Equatable, Sendable {
    public let country: String
    public let countryCode: String
    public let city: String
    public let flag: String
    public let lat: Double
    public let lon: Double

    public init(country: String, countryCode: String, city: String, flag: String, lat: Double, lon: Double) {
        self.country = country
        self.countryCode = countryCode
        self.city = city
        self.flag = flag
        self.lat = lat
        self.lon = lon
    }
}

private final class PingContext: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<Int?, Never>
    private var connection: NWConnection?

    init(continuation: CheckedContinuation<Int?, Never>) {
        self.continuation = continuation
    }

    func setConnection(_ conn: NWConnection) {
        lock.lock()
        self.connection = conn
        lock.unlock()
    }

    func finish(_ result: Int?) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        connection?.cancel()
        continuation.resume(returning: result)
    }
}

public enum ServerMetadataResolver {

    public static func flagEmoji(for countryCode: String) -> String {
        let code = countryCode.uppercased()
        guard code.count == 2 else { return "🌐" }
        let base: UInt32 = 127397
        var s = ""
        for v in code.unicodeScalars {
            if let scalar = UnicodeScalar(base + v.value) {
                s.unicodeScalars.append(scalar)
            }
        }
        return s.isEmpty ? "🌐" : s
    }

    public static func isLocalOrPrivate(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if h == "localhost" || h == "127.0.0.1" || h == "::1" { return true }
        if h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasPrefix("172.16.") || h.hasPrefix("172.17.") || h.hasPrefix("172.18.") || h.hasPrefix("172.19.") || h.hasPrefix("172.20.") || h.hasPrefix("172.21.") || h.hasPrefix("172.22.") || h.hasPrefix("172.23.") || h.hasPrefix("172.24.") || h.hasPrefix("172.25.") || h.hasPrefix("172.26.") || h.hasPrefix("172.27.") || h.hasPrefix("172.28.") || h.hasPrefix("172.29.") || h.hasPrefix("172.30.") || h.hasPrefix("172.31.") {
            return true
        }
        return false
    }

    /// Resolves the CURRENT device's region — LOCAL ONLY (device locale,
    /// no network). Previously this queried public IP-geo endpoints; that
    /// sent the device IP to third parties and is now removed for privacy.
    /// Callers needing ad targeting rely on the ad SDK itself.
    public static func resolveOwnCountry() async -> String? {
        Locale.current.region?.identifier
    }

    /// Local-only server metadata. Private/loopback addresses get a LAN
    /// badge; anything else returns nil — the UI shows the hostname + ping
    /// honestly instead of a guessed country. No external GeoIP service is
    /// ever contacted (privacy: the server address never leaves the device
    /// for location purposes).
    public static func resolveGeo(host: String) async -> ServerGeoInfo? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isLocalOrPrivate(trimmed) {
            return ServerGeoInfo(
                country: "Local Network",
                countryCode: "LOCAL",
                city: "LAN",
                flag: "🏠",
                lat: 48.1351,
                lon: 11.5820
            )
        }

        return nil
    }

    public static func measurePing(host: String, port: Int, onState: ((String) -> Void)? = nil) async -> Int? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, port > 0 && port <= 65535 else { return nil }

        let start = DispatchTime.now()
        return await withCheckedContinuation { continuation in
            let context = PingContext(continuation: continuation)
            let endpointHost = NWEndpoint.Host(trimmed)
            guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                context.finish(nil)
                return
            }

            let conn = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
            context.setConnection(conn)

            // Boxed so the @Sendable state handler can call it.
            final class StateSink: @unchecked Sendable {
                let fn: ((String) -> Void)?
                init(_ fn: ((String) -> Void)?) { self.fn = fn }
            }
            let sink = StateSink(onState)
            conn.stateUpdateHandler = { state in
                // Full state trace (only when a logger is attached — the
                // self-test passes one; minutely pings stay silent).
                if let fn = sink.fn {
                    switch state {
                    case .setup: fn("setup")
                    case .waiting(let e): fn("waiting(\(e))")
                    case .preparing: fn("preparing")
                    case .ready: fn("ready")
                    case .failed(let e): fn("failed(\(e))")
                    case .cancelled: fn("cancelled")
                    @unknown default: fn("unknown")
                    }
                }
                switch state {
                case .ready:
                    let end = DispatchTime.now()
                    let nano = end.uptimeNanoseconds - start.uptimeNanoseconds
                    let ms = Int(nano / 1_000_000)
                    context.finish(max(1, ms))
                case .failed, .cancelled:
                    context.finish(nil)
                default:
                    break
                }
            }

            let queue = DispatchQueue(label: "com.ssh2vpn.ping.\(UUID().uuidString)")
            conn.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 2.5) {
                context.finish(nil)
            }
        }
    }
}
