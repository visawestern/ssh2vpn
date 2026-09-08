import Foundation

/// Parses arbitrary user-pasted SSH credential strings into a server profile
/// candidate. Pure, local, no network — credentials never leave the device.
///
/// Strategy order (most structured → most forgiving):
///  1. JSON object
///  2. scheme://user:pass@host:port (userinfo optional)
///  3. labeled text (EN + RU: "Host: …", "Пароль: …")
///  4. user:pass@host[:port] (uses the LAST @ so passwords may contain @)
///  5. colon form host:port:user:pass (password may contain colons)
///  6. token form (space/tab/comma/semicolon, `-p` flag)
///  Then, for multiline input, each line in order via 1–6.
///  7. host scan anywhere (true last resort; yields host with defaults)
public enum CredentialParser {

    public struct Parsed: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var username: String
        public var password: String?

        public init(host: String, port: Int = 22, username: String = "root", password: String? = nil) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    public enum ParseError: Error, Equatable, Sendable {
        case emptyInput
        case noHostFound
    }

    public static func parse(_ raw: String) throws -> Parsed {
        let trimmed = normalize(raw)
        guard !trimmed.isEmpty else { throw ParseError.emptyInput }

        if let parsed = parseSingle(trimmed) { return parsed }

        // Multiline paste (provider emails): first line that fully parses wins.
        if trimmed.contains("\n") {
            for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
                if let parsed = parseSingle(String(line)) { return parsed }
            }
        }

        if let parsed = tryParseHostScan(trimmed) { return parsed }
        throw ParseError.noHostFound
    }

    static func parseSingle(_ s: String) -> Parsed? {
        if let parsed = tryParseJSON(s) { return parsed }
        if let parsed = tryParseURL(s) { return parsed }
        if let parsed = tryParseLabeled(s) { return parsed }
        if let parsed = tryParseUserinfoForm(s) { return parsed }
        if let parsed = tryParseColonForm(s) { return parsed }
        if let parsed = tryParseTokenForm(s) { return parsed }
        return nil
    }
}

// MARK: - Normalization

private func normalize(_ raw: String) -> String {
    var s = raw
    s = s.replacingOccurrences(of: "\r\n", with: "\n")
    s = s.replacingOccurrences(of: "\r", with: "\n")
    s = s.replacingOccurrences(of: "\u{00A0}", with: " ")   // NBSP
    s = s.replacingOccurrences(of: "\u{200B}", with: "")    // zero-width space
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return stripCommandPrefix(s)
}

/// Strips a leading "ssh "/"sftp "/"scp " command word (never "ssh://" URLs).
private func stripCommandPrefix(_ s: String) -> String {
    for prefix in ["ssh ", "sftp ", "scp "] {
        if s.count > prefix.count, s.lowercased().hasPrefix(prefix) {
            return String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return s
}

private let hostRegex = try! NSRegularExpression(
    pattern: #"^((?:\d{1,3}\.){3}\d{1,3})$|^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+)$"#
)

func looksLikeHost(_ token: String) -> Bool {
    guard let match = hostRegex.firstMatch(
        in: token, range: NSRange(token.startIndex..<token.endIndex, in: token)
    ) else { return false }
    // Reject incomplete IPv4 like "1.2.3" (regex alternative 1 requires 4 octets,
    // but "1.2.3" would match the domain alternative only with a valid TLD shape).
    return match.numberOfRanges >= 1
}

func validPort(_ n: Int) -> Bool { (1...65535).contains(n) }

// MARK: - Strategy 1: JSON

private func tryParseJSON(_ s: String) -> CredentialParser.Parsed? {
    guard s.hasPrefix("{"), s.hasSuffix("}") else { return nil }
    guard let data = s.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

    func pick(_ keys: [String]) -> String? {
        for k in keys {
            if let v = obj[k] as? String, !v.isEmpty { return v }
            if let n = obj[k] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    guard let host = pick(["host", "hostname", "ip", "address", "server", "sshHost"]) else { return nil }
    guard looksLikeHost(host) else { return nil }
    let port = pick(["port", "sshPort", "ssh_port"]).flatMap { Int($0) } ?? 22
    guard validPort(port) else { return nil }
    let username = pick(["username", "user", "login", "sshUser"]) ?? "root"
    let password = pick(["password", "pass", "sshPassword", "ssh_password"])
    return CredentialParser.Parsed(host: host, port: port, username: username, password: password)
}

// MARK: - Strategy 2: scheme URL (userinfo optional)

private let schemeURLRegex = try! NSRegularExpression(
    pattern: #"^(?:ssh|sftp|scp|tcp|udp)://(?:([^@/\s]+)@)?([a-zA-Z0-9.\-]+)(?::(\d{1,5}))?(?:[/?].*)?$"#,
    options: [.caseInsensitive]
)

private func tryParseURL(_ s: String) -> CredentialParser.Parsed? {
    guard let m = schemeURLRegex.firstMatch(
        in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)
    ) else { return nil }
    func grp(_ i: Int) -> String? {
        guard let r = Range(m.range(at: i), in: s), r.upperBound > r.lowerBound else { return nil }
        return String(s[r])
    }
    guard let host = grp(2) else { return nil }

    var username = "root"
    var password: String?
    if let userinfo = grp(1) {
        let parts = userinfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            username = String(parts[0])
            password = String(parts[1])
        } else if let first = parts.first, !first.isEmpty {
            username = String(first)
        }
    }
    let port = grp(3).flatMap { Int($0) } ?? 22
    guard validPort(port) else { return nil }
    return CredentialParser.Parsed(host: host, port: port, username: username, password: password)
}

// MARK: - Strategy 3: labeled text (EN + RU)

private enum CredentialField { case host, port, username, password }

/// Label → field, EN + RU. ICU `\b` does not work next to Cyrillic, so labels
/// are matched as whole tokens instead of a regex with word boundaries.
private let labelMap: [String: CredentialField] = {
    var m: [String: CredentialField] = [:]
    func put(_ names: [String], _ field: CredentialField) {
        for n in names { m[n.lowercased()] = field }
    }
    put(["host", "hostname", "server", "address", "ip", "ip address", "ip-address",
         "хост", "адрес", "ip-адрес", "ip адрес", "адрес сервера", "айпи"], .host)
    put(["port", "ssh port", "ssh-port", "sshport",
         "порт", "порт ssh", "порта"], .port)
    put(["user", "username", "login",
         "пользователь", "юзер", "логин", "имя пользователя"], .username)
    put(["password", "pass", "passwort", "pwd",
         "пароль", "пароля", "пасс"], .password)
    return m
}()

private func tryParseLabeled(_ s: String) -> CredentialParser.Parsed? {
    let rawTokens = s.split(whereSeparator: { " \t\n\r,;/".contains($0) })
    guard !rawTokens.isEmpty else { return nil }

    var found: [CredentialField: String] = [:]
    var lastLabel: CredentialField?

    for raw in rawTokens {
        let token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "."))

        // "label:value" or "label=value" inside one token.
        if let sep = token.firstIndex(where: { $0 == ":" || $0 == "=" }) {
            let left = String(token[..<sep]).lowercased()
            let right = String(token[token.index(after: sep)...])
            if let field = labelMap[left] {
                if !right.isEmpty, found[field] == nil { found[field] = right }
                lastLabel = field
                continue
            }
        }

        // Standalone label token, value arrives in the next token.
        if let field = labelMap[token.lowercased()] {
            lastLabel = field
            continue
        }

        if let field = lastLabel, found[field] == nil, !token.isEmpty {
            found[field] = token
            lastLabel = nil
        }
    }

    guard let hostValue = found[.host], looksLikeHost(hostValue) else { return nil }
    // A lone host label is not enough evidence — need one more labeled field.
    guard found.count >= 2 else { return nil }

    let port = found[.port].flatMap { Int($0) }.flatMap { validPort($0) ? $0 : nil } ?? 22
    return CredentialParser.Parsed(
        host: hostValue,
        port: port,
        username: found[.username] ?? "root",
        password: found[.password]
    )
}

// MARK: - Strategy 4: user:pass@host[:port] (last @ wins; password may contain @)

private func tryParseUserinfoForm(_ s: String) -> CredentialParser.Parsed? {
    // Prefer the LAST @: passwords may themselves contain '@'.
    let atPositions = s.indices.filter { s[$0] == "@" }
    for atPos in atPositions.reversed() {
        guard let parsed = tryParseUserinfoAt(s, at: atPos) else { continue }
        return parsed
    }
    return nil
}

private func tryParseUserinfoAt(_ s: String, at atPos: String.Index) -> CredentialParser.Parsed? {
    let before = String(s[s.startIndex..<atPos])
    let afterAll = String(s[s.index(after: atPos)...])

    // Host token ends at the first whitespace; the remainder may hold "-p 2222".
    let afterParts = afterAll.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    let hostToken = afterParts.first.map(String.init) ?? ""
    let tail = afterParts.count > 1 ? String(afterParts[1]) : ""

    // Strip any trailing path.
    let hostCore = hostToken.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)[0]
    guard !hostCore.isEmpty else { return nil }

    var host = hostCore
    var port = 22
    if let colon = hostCore.firstIndex(of: ":") {
        let maybePort = String(hostCore[hostCore.index(after: colon)...])
        if let n = Int(maybePort), validPort(n) {
            port = n
            host = String(hostCore[hostCore.startIndex..<colon])
        }
    }
    guard looksLikeHost(host) else { return nil }

    // "-p 2222" (or a bare numeric) in the tail.
    if port == 22 {
        let tailTokens = tail.split(whereSeparator: { " \t".contains($0) }).map(String.init)
        if let pIdx = tailTokens.firstIndex(of: "-p"), pIdx < tailTokens.count - 1,
           let n = Int(tailTokens[pIdx + 1]), validPort(n) {
            port = n
        }
    }

    var username = "root"
    var password: String?
    let userCore = before.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)[0]
    let parts = userCore.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2 {
        username = String(parts[0])
        password = String(parts[1])
    } else if let first = parts.first, !first.isEmpty {
        username = String(first)
    }
    return CredentialParser.Parsed(host: host, port: port, username: username, password: password)
}

// MARK: - Strategy 5: colon form host:port:user:pass

private func tryParseColonForm(_ s: String) -> CredentialParser.Parsed? {
    guard s.contains(":"), !s.contains("@") else { return nil }

    let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    // Real inputs never exceed a handful of fields; refuse pathological pastes.
    guard (2...16).contains(parts.count), !parts[0].isEmpty else { return nil }

    // host:port (2 parts) — only when the second part is a valid port number.
    if parts.count == 2 {
        guard let n = Int(parts[1]), validPort(n) else { return nil }
        guard looksLikeHost(parts[0]) else { return nil }
        return CredentialParser.Parsed(host: parts[0], port: n, username: "root", password: nil)
    }

    if let n = Int(parts[1]), validPort(n) {
        guard looksLikeHost(parts[0]) else { return nil }
        let username = parts[2]
        // Everything after the 3rd colon is the password (may contain colons).
        let password = parts.count >= 4 ? parts[3...].joined(separator: ":") : nil
        return CredentialParser.Parsed(host: parts[0], port: n, username: username, password: password)
    }

    // host:user:pass (no port).
    if !parts[1].isEmpty, looksLikeHost(parts[0]) {
        let password = parts[2...].joined(separator: ":")
        guard !password.isEmpty else { return nil }
        return CredentialParser.Parsed(host: parts[0], port: 22, username: parts[1], password: password)
    }
    return nil
}

// MARK: - Strategy 6: token form (space/tab/comma/semicolon)

private func tryParseTokenForm(_ s: String) -> CredentialParser.Parsed? {
    let tokens = s.split(whereSeparator: { " \t\n,;".contains($0) }).map(String.init)
    guard tokens.count >= 2 else { return nil }
    guard let hostIdx = tokens.firstIndex(where: { looksLikeHost($0) }) else { return nil }
    let host = tokens[hostIdx]

    var port = 22
    var username: String?
    var password: String?

    var rest = Array(tokens[(hostIdx + 1)...])

    // "-p 2222" flag.
    if let pIdx = rest.firstIndex(of: "-p"), pIdx < rest.count - 1,
       let n = Int(rest[pIdx + 1]), validPort(n) {
        port = n
        let flagEnd = pIdx + 2
        if flagEnd <= rest.count {
            rest.removeSubrange(pIdx..<flagEnd)
        }
    } else if let first = rest.first, let n = Int(first), validPort(n) {
        port = n
        rest.removeFirst()
    }

    let nameCandidates = rest.filter { !looksLikeHost($0) && Int($0) == nil }
    if let first = nameCandidates.first {
        username = first
        if nameCandidates.count > 1 {
            password = nameCandidates.dropFirst().joined(separator: " ")
        }
    }
    return CredentialParser.Parsed(host: host, port: port, username: username ?? "root", password: password)
}

// MARK: - Strategy 7: host scan anywhere (last resort)

private func tryParseHostScan(_ s: String) -> CredentialParser.Parsed? {
    let tokens = s.split(whereSeparator: { " \t\n,;:@/".contains($0) }).map(String.init)
    guard let host = tokens.first(where: { looksLikeHost($0) }) else { return nil }
    return CredentialParser.Parsed(host: host, port: 22, username: "root", password: nil)
}
