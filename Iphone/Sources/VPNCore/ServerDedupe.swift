import Foundation

/// Duplicate-server hygiene shared by the app and the extension. Two records
/// are the same machine when host+port+username match (host compared
/// case-insensitively). Secrets, flags, names and dns never participate in
/// identity — they are payload, not coordinates.
public enum ServerDedupe {
    /// Ids that should be deleted: every duplicate group keeps the selected
    /// record, or the first one when nothing (or something unknown) is selected.
    public static func duplicateIDs(servers: [ServerProfile], selectedID: String?) -> [String] {
        var groups = [String: [ServerProfile]]()
        var order = [String]()
        for s in servers {
            let key = "\(s.host.lowercased())|\(s.port)|\(s.username)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(s)
        }
        var remove = [String]()
        for key in order {
            let group = groups[key]!
            guard group.count > 1 else { continue }
            let keep: String
            if let selectedID, group.contains(where: { $0.id == selectedID }) {
                keep = selectedID
            } else {
                keep = group[0].id
            }
            remove.append(contentsOf: group.map(\.id).filter { $0 != keep })
        }
        return remove
    }

    /// Finds the stored record for these connection coordinates, if any, so a
    /// save reuses its id instead of spawning a duplicate under a fresh UUID.
    public static func matchID(servers: [ServerProfile], host: String, port: Int, username: String) -> String? {
        servers.first {
            $0.host.lowercased() == host.lowercased() && $0.port == port && $0.username == username
        }?.id
    }
}
