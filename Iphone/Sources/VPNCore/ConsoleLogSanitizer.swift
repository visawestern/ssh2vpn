import Foundation

public enum ConsoleLogSanitizer {

    private static let privateKeyRegex = try! NSRegularExpression(
        pattern: "(-----BEGIN [A-Z0-9 ]+PRIVATE KEY-----)[\\s\\S]*?(-----END [A-Z0-9 ]+PRIVATE KEY-----)",
        options: []
    )

    private static let passwordPatterns: [NSRegularExpression] = [
        // password: "secret" or password='secret' or password: secret
        try! NSRegularExpression(pattern: #"(?i)(password|passwd|pwd|auth|secret)\s*[:=]\s*["']?([^"'\s,;]+)["']?"#, options: []),
        // "password": "value" in JSON
        try! NSRegularExpression(pattern: #"(?i)"(password|passwd|pwd|secret)"\s*:\s*"([^"]+)""#, options: []),
        // -P secret or -p secret (CLI args with password flag)
        try! NSRegularExpression(pattern: #"(?<=\s-P\s)([^\s]+)"#, options: []),
    ]

    public static func sanitize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        // 1. Scrub Private Key bodies
        let keyRange = NSRange(result.startIndex..<result.endIndex, in: result)
        result = privateKeyRegex.stringByReplacingMatches(
            in: result,
            options: [],
            range: keyRange,
            withTemplate: "$1\n[PRIVATE_KEY_REDACTED]\n$2"
        )

        // 2. Scrub Passwords / Secrets
        for regex in passwordPatterns {
            let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..<result.endIndex, in: result))
            for match in matches.reversed() {
                // If regex has capturing group for the secret value (group 2 or group 1)
                let targetGroup = match.numberOfRanges > 2 ? 2 : (match.numberOfRanges > 1 ? 1 : 0)
                if let range = Range(match.range(at: targetGroup), in: result) {
                    result.replaceSubrange(range, with: "***REDACTED***")
                }
            }
        }

        return result
    }
}
