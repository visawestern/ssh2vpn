import Foundation

/// Pure JSON coding between the app and the extension's server-list API.
///
/// This is the only place that knows how to (de)serialize `ServerProfile` for
/// the message channel. It lives in VPNCore so it can be unit-tested without a
/// real VPN manager.
///
/// SECURITY: `decodeServerList` always strips `password` / `privateKey` after
/// parsing, so even if a buggy extension leaked them the app never retains them.
public enum ServerListCoder {

    /// Encodes a full profile (including secrets) into the `args` dictionary
    /// for a `serverSet` command. Only non-nil secrets are included.
    public static func encodeServerSet(_ profile: ServerProfile) -> [String: Any] {
        var dict: [String: Any] = [
            "id": profile.id,
            "name": profile.name,
            "host": profile.host,
            "port": profile.port,
            "username": profile.username,
            "hostKey": profile.hostKey,
            "dnsServers": profile.dnsServers,
            "hasPassword": profile.hasPassword,
            "hasPrivateKey": profile.hasPrivateKey
        ]
        if let password = profile.password { dict["password"] = password }
        if let privateKey = profile.privateKey { dict["privateKey"] = privateKey }
        return dict
    }

    /// Decodes the `data` dictionary from a `serverList` response into a server
    /// list + selected id. Always strips secrets from the result.
    public static func decodeServerList(data: [String: String]) -> (servers: [ServerProfile], selectedID: String?) {
        let selectedID = data["selectedID"]
        guard let json = data["servers"],
              let raw = json.data(using: .utf8),
              let profiles = try? JSONDecoder().decode([ServerProfile].self, from: raw) else {
            return ([], selectedID)
        }
        // Defense in depth: never retain secrets even if the extension leaks them.
        let sanitized = profiles.map { p -> ServerProfile in
            var copy = p
            copy.password = nil
            copy.privateKey = nil
            return copy
        }
        return (sanitized, selectedID)
    }
}
