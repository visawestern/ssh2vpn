import Foundation

/// Central filter for user-supplied free text that will be rendered in the UI.
///
/// Swift strings are memory-safe, so "crashing" is not the real threat —
/// spoofing and layout corruption are: zero-width characters that hide
/// content, bidi overrides that flip displayed text, control codes, exotic
/// whitespace, private-use glyphs and zalgo combining-mark towers. This
/// filter strips all of those, normalizes whitespace and caps length.
///
/// Labels (display-only) are silently SANITIZED through here; connection
/// coordinates (host / username) are instead REJECTED by ProfileValidator
/// when they contain the same classes of characters — silently fixing the
/// machine you connect to would be a security bug.
public enum TextInputSanitizer {

    /// Max grapheme clusters kept in a server label. Character-based, so an
    /// emoji flag still counts as one.
    public static let labelMaxLength = 40

    /// Max consecutive combining marks kept in one run. Real scripts need
    /// at most ~4 (Indic base + virama + consonant + vowel/tone); zalgo
    /// towers stack 10+ and get clipped here.
    public static let maxCombiningRun = 6

    /// Scalar categories never allowed in display text or identifiers:
    /// control (Cc), format (Cf — zero-width spaces, bidi overrides, BOM,
    /// soft hyphen, word joiner…), line/paragraph separators, surrogates,
    /// private use and unassigned code points, plus Unicode noncharacters.
    public static func isUnsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator,
             .surrogate, .privateUse, .unassigned:
            return true
        default:
            return scalar.properties.isNoncharacterCodePoint
        }
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    /// Sanitizes a label: removes unsafe scalars, collapses any whitespace
    /// run (incl. NBSP and exotic Unicode spaces) into one ASCII space,
    /// clips combining-mark runs and caps total length by grapheme cluster.
    /// Returns nil when nothing displayable remains.
    public static func sanitizeLabel(_ raw: String?, maxLength: Int = labelMaxLength) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(raw.unicodeScalars.count)
        var pendingSpace = false
        var combiningRun = 0

        for scalar in raw.unicodeScalars {
            // Whitespace first: tab / newline / NBSP / exotic spaces all
            // become one ASCII space. Control-category whitespace (\t, \n)
            // must NOT fall through to the unsafe-scalar strip below.
            if scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            if isUnsafeScalar(scalar) { continue }
            if isCombiningMark(scalar) {
                combiningRun += 1
                if combiningRun > maxCombiningRun { continue }
            } else {
                combiningRun = 0
            }
            // Leading whitespace is dropped (scalars still empty), inner runs
            // collapse to a single space; trailing never gets flushed.
            if pendingSpace, !scalars.isEmpty {
                scalars.append(" ")
            }
            pendingSpace = false
            scalars.append(scalar)
        }

        var result = String(String.UnicodeScalarView(scalars))
        if result.count > maxLength {
            // Grapheme-safe cut may expose a flushed inner space at the edge.
            result = String(result.prefix(maxLength))
                .trimmingCharacters(in: .whitespaces)
        }
        return result.isEmpty ? nil : result
    }

    /// Grapheme-safe length cap for live TextField filtering (onChange).
    public static func capped(_ raw: String, maxLength: Int = labelMaxLength) -> String {
        raw.count > maxLength ? String(raw.prefix(maxLength)) : raw
    }
}
