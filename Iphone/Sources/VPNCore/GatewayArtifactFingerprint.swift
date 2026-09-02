import Crypto
import Foundation

/// Deterministic, path-safe fingerprints for gateway artifacts (Chapter 3, p.50).
///
/// A host+user pair maps to a unique `sha256` hex string so:
///   - two different hosts (or users) never share an artifact name;
///   - the same host+user always resolves to the same name (idempotent install);
///   - the output is pure hexadecimal, so it is safe inside any file path.
public enum GatewayArtifactFingerprint {
    public static func fingerprint(host: String, user: String) -> String {
        let material = host + "/" + user
        let hash = SHA256.hash(data: Data(material.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
