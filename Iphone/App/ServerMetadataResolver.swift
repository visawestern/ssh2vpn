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

        // Try ip-api.com
        if let url = URL(string: "http://ip-api.com/json/\(trimmed)?fields=status,message,country,countryCode,city,lat,lon") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3.0
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String, status == "success" {
                let country = json["country"] as? String ?? "Unknown"
                let code = json["countryCode"] as? String ?? ""
                let city = json["city"] as? String ?? ""
                let lat = json["lat"] as? Double ?? 48.0
                let lon = json["lon"] as? Double ?? 11.0
                return ServerGeoInfo(
                    country: country,
                    countryCode: code,
                    city: city,
                    flag: flagEmoji(for: code),
                    lat: lat,
                    lon: lon
                )
            }
        }

        // Fallback to ipwhois.app
        if let url = URL(string: "https://ipwhois.app/json/\(trimmed)") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3.0
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success {
                let country = json["country"] as? String ?? "Unknown"
                let code = json["country_code"] as? String ?? ""
                let city = json["city"] as? String ?? ""
                let lat = json["latitude"] as? Double ?? 48.0
                let lon = json["longitude"] as? Double ?? 11.0
                return ServerGeoInfo(
                    country: country,
                    countryCode: code,
                    city: city,
                    flag: flagEmoji(for: code),
                    lat: lat,
                    lon: lon
                )
            }
        }

        return nil
    }

    public static func measurePing(host: String, port: Int) async -> Int? {
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

            conn.stateUpdateHandler = { state in
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
