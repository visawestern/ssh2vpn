import Foundation

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
}
