import Foundation

/// Deterministic checks on what the cleanup pass actually did to the script.
///
/// Three prompt revisions failed to make the LLM reliable at transliteration.
/// Measured on real inputs at temperature 0: 3 of 7 Hindi sentences came back
/// still in Devanagari, others picked up stray diacritics, and some were
/// translated into English outright. Prompt wording is not a guarantee, so the
/// result is verified mechanically instead and repaired when it is wrong.
public enum Script {
    /// Ranges the cleanup pass claims to romanize: Devanagari for Hindi/Marathi,
    /// and the Arabic blocks Urdu is written in.
    private static let nonLatinRanges: [ClosedRange<UInt32>] = [
        0x0900...0x097F,  // Devanagari
        0xA8E0...0xA8FF,  // Devanagari Extended
        0x0600...0x06FF,  // Arabic
        0x0750...0x077F,  // Arabic Supplement
        0x08A0...0x08FF,  // Arabic Extended-A
    ]

    public static func containsNonLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            nonLatinRanges.contains { $0.contains(scalar.value) }
        }
    }

    /// ICU transliteration, which ships with the OS. Deterministic, about 1.2ms
    /// for a four-minute transcript, and incapable of translating or of leaving
    /// script behind.
    ///
    /// ponytail: not used as the primary path because its output is scholarly
    /// rather than natural — "mujhe yaha cahi'e" where a Hindi speaker writes
    /// "mujhe yeh chahiye", because ISO-15919 keeps the inherent schwas that
    /// speech drops. Good enough as a guaranteed floor, not as the default.
    public static func romanize(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        return latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    }

    /// Dice coefficient over character bigrams. Order-insensitive and cheap.
    public static func similarity(_ a: String, _ b: String) -> Double {
        func bigrams(_ s: String) -> Set<String> {
            let chars = Array(s.lowercased().filter { $0.isLetter || $0 == " " })
            guard chars.count > 1 else { return [] }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
        }
        let left = bigrams(a), right = bigrams(b)
        guard !left.isEmpty, !right.isEmpty else { return 1 }
        return 2.0 * Double(left.intersection(right).count) / Double(left.count + right.count)
    }

    /// Measured separation on real sentences: transliteration scored 0.653 to
    /// 0.889 against the ICU baseline, translation scored 0.061 to 0.476. The
    /// threshold sits in the empty band between them.
    public static let translationThreshold = 0.55

    /// True when the cleanup translated the speaker instead of transliterating.
    ///
    /// Only meaningful when the original actually contained non-Latin script —
    /// English in, English out is not a translation.
    public static func looksTranslated(original: String, output: String) -> Bool {
        guard containsNonLatin(original) else { return false }
        return similarity(romanize(original), output) < translationThreshold
    }
}
