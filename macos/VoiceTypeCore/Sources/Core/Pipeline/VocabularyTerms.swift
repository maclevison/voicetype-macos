import Foundation

// Splits the user's vocabulary setting into terms: comma- or newline-separated,
// trimmed, empties dropped.
public enum VocabularyTerms {
    public static func parse(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
