import Crypto
import Foundation

/// Errors thrown when a gateway artifact fails verification. Each case is a
/// distinct, user-actionable failure so the UI can report *why* the binary was
/// rejected rather than a generic "verification failed".
public enum GatewayArtifactError: Error, Equatable {
    case emptyBinary
    case binaryTooLarge(maximum: Int)
    case hashMismatch(expected: String, actual: String)
    case signatureMismatch
}

/// A trusted Ed25519 public key together with the date it becomes active.
///
/// Key rollover (Chapter 2, p.30-31) is supported by trusting several keys at
/// once, each with its own activation date. A signature verifies if it was
/// made with *any* key that is already active at verification time. A
/// signature made with a key before its activation date is rejected — this is
/// the rollover grace period that prevents a pre-activated key from being used
/// before its rotation date.
public struct TrustedKey: Sendable {
    public let publicKey: Curve25519.Signing.PublicKey
    public let activationDate: Date

    public init(publicKey: Curve25519.Signing.PublicKey, activationDate: Date = .distantPast) {
        self.publicKey = publicKey
        self.activationDate = activationDate
    }
}

/// Verifies a gateway artifact before it is ever trusted for execution.
///
/// C10 security core: a binary must pass **sha256** AND **Ed25519** checks in
/// that order before it is written to disk and executed. The checks are
/// ordered cheapest-first (emptiness → size → hash → signature) so a bogus
/// artifact is rejected with minimal work and the most specific error.
///
/// This is the non-negotiable primitive that the rest of Chapter 2 (streaming,
/// CDN, UI progress) builds on top of — without it, a tampered artifact could
/// run on the host.
public struct GatewayArtifactVerifier: Sendable {
    private let expectedHash: Data
    private let trustedKeys: [TrustedKey]
    public let maximumBinarySize: Int

    public init(expectedHash: Data, trustedKeys: [TrustedKey], maximumBinarySize: Int = 2 * 1024 * 1024) {
        self.expectedHash = expectedHash
        self.trustedKeys = trustedKeys
        self.maximumBinarySize = maximumBinarySize
    }

    /// Single-key convenience initializer. The key is treated as always active
    /// (activation in the distant past), which preserves backward compatibility
    /// with the original single-key verification flow.
    public init(expectedHash: Data, publicKey: Curve25519.Signing.PublicKey, maximumBinarySize: Int = 2 * 1024 * 1024) {
        self.init(
            expectedHash: expectedHash,
            trustedKeys: [TrustedKey(publicKey: publicKey)],
            maximumBinarySize: maximumBinarySize
        )
    }

    /// Verifies `binary` against its `signature`, returning the verified bytes.
    /// A signature is valid if it was made with any trusted key that is active
    /// at `now`. Throws a `GatewayArtifactError` on the first check that fails.
    public func verify(_ binary: Data, signature: Data, now: Date = Date()) throws -> Data {
        guard !binary.isEmpty else { throw GatewayArtifactError.emptyBinary }
        guard binary.count <= maximumBinarySize else { throw GatewayArtifactError.binaryTooLarge(maximum: maximumBinarySize) }

        let actualHash = Data(SHA256.hash(data: binary))
        guard actualHash == expectedHash else {
            throw GatewayArtifactError.hashMismatch(expected: expectedHash.hex, actual: actualHash.hex)
        }

        let activeKeys = trustedKeys.filter { $0.activationDate <= now }
        let signatureValid = activeKeys.contains { $0.publicKey.isValidSignature(signature, for: binary) }
        guard signatureValid else {
            throw GatewayArtifactError.signatureMismatch
        }

        return binary
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
