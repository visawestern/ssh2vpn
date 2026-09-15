import Crypto
import Foundation
import NIOSSH

/// Imports the key forms that can be converted to NIOSSHPrivateKey without
/// invoking a shell or writing the original private-key text to disk.
public enum SSHPrivateKeyImporter {
    public enum ImportError: Swift.Error, Equatable, Sendable {
        case empty
        case unsupportedFormat
        case encryptedKeyUnsupported
        case malformedKey
        case unsupportedAlgorithm
    }

    public static func importEd25519(_ input: Data) throws -> NIOSSHPrivateKey {
        guard !input.isEmpty else { throw ImportError.empty }
        if input.count == 32 {
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: input))
        }
        guard let text = String(data: input, encoding: .utf8) else {
            throw ImportError.unsupportedFormat
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.contains("BEGIN OPENSSH PRIVATE KEY") {
            if let base64 = Data(base64Encoded: normalized), base64.count == 32 {
                return try importEd25519(base64)
            }
            let hex = Self.decodeHex(normalized)
            if let hex, hex.count == 32 { return try importEd25519(hex) }
        }
        guard normalized.contains("BEGIN OPENSSH PRIVATE KEY") else {
            throw ImportError.unsupportedFormat
        }
        guard let body = pemBody(normalized), let decoded = Data(base64Encoded: body) else {
            throw ImportError.malformedKey
        }
        return try parseOpenSSHEd25519(decoded)
    }

    /// Returns the canonical 32-byte Ed25519 seed for Keychain storage.
    public static func canonicalSeed(from input: Data) throws -> Data {
        _ = try importEd25519(input)
        if input.count == 32 { return input }
        guard let text = String(data: input, encoding: .utf8) else { throw ImportError.unsupportedFormat }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.contains("BEGIN OPENSSH PRIVATE KEY") {
            if let base64 = Data(base64Encoded: normalized), base64.count == 32 {
                return base64
            }
            if let hex = decodeHex(normalized), hex.count == 32 { return hex }
            throw ImportError.unsupportedFormat
        }
        guard let body = pemBody(normalized), let decoded = Data(base64Encoded: body) else {
            throw ImportError.malformedKey
        }
        return try parseSeed(decoded)
    }

    /// PEM body: strips the BEGIN/END guards and every whitespace char
    /// (keys pasted from Files/Notes often carry \r\n — every variant must
    /// decode, not just the exact ssh-keygen line layout).
    private static func pemBody(_ text: String) -> String? {
        let body = text
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return body.isEmpty ? nil : body
    }
    private static func decodeHex(_ text: String) -> Data? {
        guard text.count == 64 else { return nil }
        return Data((0..<64).compactMap { offset in
            guard offset.isMultiple(of: 2) else { return nil }
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: 2)
            return UInt8(text[start..<end], radix: 16)
        })
    }

    /// Lightweight pre-flight check for the save-server form: validates the
    /// pasted/imported key WITHOUT importing it. Catches the encrypted-key
    /// and wrong-format cases at entry time instead of as a mystery tunnel
    /// failure at connect time.
    public static func validatePEM(_ text: String) -> ImportError? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        do {
            _ = try importEd25519(Data(trimmed.utf8))
            return nil
        } catch let e as ImportError {
            return e
        } catch {
            return .malformedKey
        }
    }

    private static func parseOpenSSHEd25519(_ data: Data) throws -> NIOSSHPrivateKey {
        let seed = try parseSeed(data)
        return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }

    private static func parseSeed(_ data: Data) throws -> Data {
        var reader = BinaryReader(data)
        guard try reader.readBytes(count: 15) == Data("openssh-key-v1\0".utf8) else {
            throw ImportError.malformedKey
        }
        let cipher = try reader.readString()
        _ = try reader.readString() // KDF name
        _ = try reader.readBytes(count: Int(try reader.readUInt32())) // KDF options
        guard cipher == "none" else { throw ImportError.encryptedKeyUnsupported }
        guard try reader.readUInt32() == 1 else { throw ImportError.unsupportedFormat }
        // The public key blob is BINARY (mpints + algorithm name framing), not
        // UTF-8 text — reading it through readString() made every real
        // unencrypted key fail as "malformedKey" (the bug that broke key
        // auth entirely while passwords worked). It only needs skipping.
        _ = try reader.readStringData() // public key blob
        let privateBlob = try reader.readStringData()
        var privateReader = BinaryReader(privateBlob)
        let firstCheck = try privateReader.readUInt32()
        let secondCheck = try privateReader.readUInt32()
        guard firstCheck == secondCheck else {
            throw ImportError.malformedKey
        }
        guard try privateReader.readString() == "ssh-ed25519" else {
            throw ImportError.unsupportedAlgorithm
        }
        // Public key inside the private section is binary too (seed||public).
        _ = try privateReader.readStringData()
        let privateKey = try privateReader.readStringData()
        // OpenSSH stores the 32-byte seed followed by the 32-byte public
        // key as one mpint. Accept exactly that 64-byte layout (leading
        // zero-stripped 63-byte mpints never occur for Ed25519 seeds).
        guard privateKey.count == 64 else { throw ImportError.malformedKey }
        return privateKey.prefix(32)
    }
}

private struct BinaryReader {
    private let data: Data
    private var index = 0

    init(_ data: Data) { self.data = data }

    mutating func readUInt32() throws -> UInt32 {
        guard data.count - index >= 4 else { throw SSHPrivateKeyImporter.ImportError.malformedKey }
        let value = data[index..<index + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        index += 4
        return value
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, data.count - index >= count else { throw SSHPrivateKeyImporter.ImportError.malformedKey }
        let result = Data(data[index..<index + count])
        index += count
        return result
    }

    mutating func readStringData() throws -> Data {
        let count = Int(try readUInt32())
        return try readBytes(count: count)
    }

    mutating func readString() throws -> String {
        guard let value = String(data: try readStringData(), encoding: .utf8) else {
            throw SSHPrivateKeyImporter.ImportError.malformedKey
        }
        return value
    }
}
