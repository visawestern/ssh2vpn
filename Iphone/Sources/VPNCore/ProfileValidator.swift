import Foundation

/// Typed reasons a pinned host key failed entry-time validation. The
/// validator stays UI-free (English descriptions only); the app maps each
/// reason to a localized Copy string.
public enum HostKeyInvalidReason: Error, Equatable, Sendable {
    /// Multiple lines pasted (two keys or a PEM block).
    case multiLine
    /// Zero-width / bidi / control scalars in a security coordinate.
    case invisibleScalars
    /// Not "algorithm-id base64-data" at all (e.g. a SHA256 fingerprint).
    case expectedFormat
    /// Algorithm id not one of the ssh-keyscan types.
    case unknownType(String)
    /// Second token is not valid base64.
    case badBase64
}

public enum ProfileValidationError: Error, Equatable, LocalizedError {
    case emptyHost
    case invalidHost(String)
    case emptyPort
    case invalidPortFormat
    case portOutOfRange(min: Int, max: Int)
    case emptyUsername
    case invalidUsername(String)
    case missingAuthentication
    case invalidPrivateKeyFormat
    /// Richer key failure carrying a ready-to-show localized message
    /// (from the importer's typed diagnosis), so the UI never has to map.
    case invalidPrivateKey(message: String)
    /// Pinned host key entry-time validation failure. Empty host key is
    /// valid (TOFU) — this only fires on non-empty bad input. Carries the
    /// typed reason; the app maps it to a localized message.
    case invalidHostKey(HostKeyInvalidReason)

    public var errorDescription: String? {
        switch self {
        case .emptyHost:
            return "Server address cannot be empty."
        case .invalidHost(let reason):
            return "Invalid server address: \(reason)"
        case .emptyPort:
            return "Port cannot be empty."
        case .invalidPortFormat:
            return "Port must be a valid positive integer."
        case .portOutOfRange(let min, let max):
            return "Port must be between \(min) and \(max)."
        case .emptyUsername:
            return "Username cannot be empty."
        case .invalidUsername(let reason):
            return "Invalid username: \(reason)"
        case .missingAuthentication:
            return "Either password or private key must be provided."
        case .invalidPrivateKeyFormat:
            return "Invalid private key format. Must be an OpenSSH key."
        case .invalidPrivateKey(let message):
            return message
        case .invalidHostKey(let reason):
            // English developer-facing text; the app UI maps HostKeyInvalidReason
            // to localized Copy strings.
            switch reason {
            case .multiLine: return "Invalid pinned host key: paste exactly one host key line"
            case .invisibleScalars: return "Invalid pinned host key: contains invisible or control characters"
            case .expectedFormat: return "Invalid pinned host key: expected ssh-ed25519 AAAA... (from ssh-keyscan or known_hosts), not a fingerprint"
            case .unknownType(let t): return "Invalid pinned host key: unknown key type \"\(t)\" — use ssh-keyscan output, not a fingerprint (SHA256:...)"
            case .badBase64: return "Invalid pinned host key: key data is not valid base64"
            }
        }
    }
}

public enum ProfileValidator {

    public static func validatePort(_ rawString: String) throws -> Int {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProfileValidationError.emptyPort
        }

        // Check if integer
        guard let port = Int(trimmed) else {
            // If it starts with minus or is numbers only but overflowed
            if trimmed.hasPrefix("-") || trimmed.allSatisfy({ $0.isNumber }) {
                throw ProfileValidationError.portOutOfRange(min: 1, max: 65535)
            }
            throw ProfileValidationError.invalidPortFormat
        }

        guard port >= 1 && port <= 65535 else {
            throw ProfileValidationError.portOutOfRange(min: 1, max: 65535)
        }

        return port
    }

    public static func validateHost(_ rawString: String) throws -> String {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProfileValidationError.emptyHost
        }

        // Disallow scheme prefixes
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") || trimmed.lowercased().hasPrefix("ssh://") {
            throw ProfileValidationError.invalidHost("Do not include protocol schemes like http:// or https://")
        }

        // Disallow dangerous characters (whitespace, semicolons, shell characters)
        let forbidden = CharacterSet(charactersIn: " ;&$`|<>\\'\"\n\r\t")
        guard trimmed.rangeOfCharacter(from: forbidden) == nil else {
            throw ProfileValidationError.invalidHost("Contains invalid or forbidden characters")
        }

        // Reject invisible / spoofing characters outright: zero-width, bidi
        // overrides, control, private-use, unassigned, noncharacters. A host
        // is a connection coordinate — never silently fix, always refuse.
        guard !trimmed.unicodeScalars.contains(where: { TextInputSanitizer.isUnsafeScalar($0) }) else {
            throw ProfileValidationError.invalidHost("Contains invisible or control characters")
        }

        // RFC 1035 caps a fully-qualified domain at 253 characters; nothing
        // longer is a real host.
        guard trimmed.count <= 253 else {
            throw ProfileValidationError.invalidHost("Address is too long")
        }

        // Check for numeric-only dot sequences (incomplete or invalid IPv4)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if parts.allSatisfy({ Int($0) != nil }) {
            guard parts.count == 4 else {
                throw ProfileValidationError.invalidHost("Incomplete IPv4 address")
            }
            for part in parts {
                guard let num = Int(part), num >= 0 && num <= 255 else {
                    throw ProfileValidationError.invalidHost("IPv4 octets must be between 0 and 255")
                }
            }
            return trimmed
        }

        // Domain validation
        if trimmed.hasPrefix("-") || trimmed.hasSuffix("-") || trimmed.hasPrefix(".") || trimmed.hasSuffix(".") {
            throw ProfileValidationError.invalidHost("Domain cannot start or end with a hyphen or dot")
        }

        return trimmed
    }

    public static func validateUsername(_ rawString: String) throws -> String {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProfileValidationError.emptyUsername
        }

        let forbidden = CharacterSet(charactersIn: " :;\n\r\t\0")
        guard trimmed.rangeOfCharacter(from: forbidden) == nil else {
            throw ProfileValidationError.invalidUsername("Username contains illegal characters")
        }

        // Same invisible-spoofing scalar classes as the host: the username
        // is rendered in the chip next to the alias, so bidi / zero-width
        // chars in it can visually lie about the server being edited.
        guard !trimmed.unicodeScalars.contains(where: { TextInputSanitizer.isUnsafeScalar($0) }) else {
            throw ProfileValidationError.invalidUsername("Username contains invisible or control characters")
        }

        // Unix login names are capped at 32 (LOGIN_NAME_MAX) on every
        // mainstream platform; anything longer is not a real username.
        guard trimmed.count <= 32 else {
            throw ProfileValidationError.invalidUsername("Username is too long")
        }

        return trimmed
    }

    public static func validateCredentials(password: String, privateKey: String) throws {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPassword.isEmpty || !trimmedKey.isEmpty else {
            throw ProfileValidationError.missingAuthentication
        }

        if !trimmedKey.isEmpty {
            guard trimmedKey.contains("BEGIN") && (trimmedKey.contains("OPENSSH PRIVATE KEY") || trimmedKey.contains("RSA PRIVATE KEY") || trimmedKey.contains("EC PRIVATE KEY")) else {
                throw ProfileValidationError.invalidPrivateKeyFormat
            }
        }
    }

    /// Validates a pinned OpenSSH host key: empty = TOFU (accepted), non-empty
    /// must be the single-line "algorithm-id base64-data [comment]" form
    /// (what `ssh-keyscan -t ed25519 host` prints / known_hosts stores).
    /// Rejects the common wrong inputs at entry time instead of as a mystery
    /// hostKeyMismatch/connection failure at connect time: fingerprints
    /// ("SHA256:..."), private-key PEM blocks, and multi-line pastes
    /// (two keys). Typed reasons (HostKeyInvalidReason) let the app show a
    /// localized, actionable message.
    public static func validateHostKey(_ rawString: String) throws -> String {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw ProfileValidationError.invalidHostKey(.multiLine)
        }

        // Invisible-spoofing scalars (zero-width/bidi): a pinned key is a
        // security coordinate — garbage must fail loudly, never silently.
        guard !trimmed.unicodeScalars.contains(where: { TextInputSanitizer.isUnsafeScalar($0) }) else {
            throw ProfileValidationError.invalidHostKey(.invisibleScalars)
        }

        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw ProfileValidationError.invalidHostKey(.expectedFormat)
        }
        let algo = String(parts[0])
        let data = String(parts[1])

        // Any ssh-keyscan algorithm is structurally valid for NIOSSH; we only
        // deep-validate Ed25519 (the app's own hint/placeholder type).
        let knownAlgos = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-dss"]
        guard knownAlgos.contains(algo) else {
            throw ProfileValidationError.invalidHostKey(.unknownType(algo))
        }
        guard data.range(of: "^[A-Za-z0-9+/]+={0,3}$", options: .regularExpression) != nil else {
            throw ProfileValidationError.invalidHostKey(.badBase64)
        }
        return trimmed
    }
}
