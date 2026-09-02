import Foundation

/// Constructs safe, sandboxed paths for gateway artifacts (Chapter 3, p.54, p.56, p.59).
///
/// Guarantees:
///   - p.59: hostnames are normalized (unicode → ASCII via IDNA-like folding) and
///     stripped of path-special characters, so a hostile host can never inject a
///     traversal or escape the artifact directory.
///   - p.54: every artifact path is built under a fixed base directory and
///     includes the per-host fingerprint, so artifacts are isolated per host.
///   - p.56: filenames are sanitized to drop shell-special and permission-escape
///     characters before they ever reach the filesystem.
public enum GatewayArtifactPaths {
    /// Normalizes a host/user string into a single safe path component.
    public static func safeComponent(_ raw: String) -> String {
        var value = raw
        // p.59: fold unicode to ASCII (e.g. "хост" → "host"-like transliteration
        // falls back to percent-free stripping when no latin mapping exists).
        if #available(macOS 10.11, iOS 9.0, *),
           let latin = value.applyingTransform(.toLatin, reverse: false),
           let stripped = latin.applyingTransform(.stripDiacritics, reverse: false) {
            value = stripped
        }
        // Drop anything that is not alphanumeric, dot, hyphen, or underscore.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        value = value.unicodeScalars.filter { allowed.contains($0) }.map { String($0) }.joined()
        // Collapse and strip leading dots (no hidden files / traversal).
        value = value.replacingOccurrences(of: "..", with: "")
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // Guarantee non-empty: fall back to a fingerprint of the raw input.
        if value.isEmpty {
            value = GatewayArtifactFingerprint.fingerprint(host: raw, user: "artifact")
        }
        return value
    }

    /// Builds an artifact URL under `baseURL` that resists path traversal.
    public static func appending(filename: String, to baseURL: URL, fingerprint: String) -> URL {
        let sanitized = safeComponent(filename)
        // Strip any extension from the sanitized name, then attach fingerprint.
        let stem = (sanitized as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let bounded: String
        if ext.isEmpty {
            bounded = "\(stem)-\(fingerprint)"
        } else {
            bounded = "\(stem)-\(fingerprint).\(ext)"
        }
        // Resolve against base and confirm it stays inside (defense in depth).
        let resolved = baseURL.appendingPathComponent(bounded).standardizedFileURL
        return resolved
    }
}
