import Foundation

/// Kebab-case ASCII slugs, the OpenKnowledge vault naming convention for projects and
/// documents (`billing-api`, `2026-10-16-sprint-review`).
public enum OKSlug {
    /// `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 80 characters.
    public static func isValid(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 80 else { return false }
        guard s.utf8.allSatisfy({ isLowerAlphanumeric($0) || $0 == UInt8(ascii: "-") }) else { return false }
        return !s.hasPrefix("-") && !s.hasSuffix("-") && !s.contains("--")
    }

    /// Folds diacritics, lowercases, turns every run of non-alphanumeric ASCII
    /// into a single `-` and cuts at `maxLength` without a trailing `-`.
    /// Returns `""` when nothing survives ("✨✨", "!!!"); callers pick a fallback.
    public static func make(from title: String, maxLength: Int = 60) -> String {
        let folded = title
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var slug = ""
        var pendingDash = false
        for byte in folded.utf8 {
            if isLowerAlphanumeric(byte) {
                if pendingDash && !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.append(Character(UnicodeScalar(byte)))
            } else {
                pendingDash = true
            }
        }
        if slug.count > maxLength {
            slug = String(slug.prefix(maxLength))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug
    }

    private static func isLowerAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
