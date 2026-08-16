import Foundation

/// Detects script that the cleanup pass was supposed to transliterate away.
///
/// This exists because the prompt alone is not a guarantee. Measured: the input
/// "यहाँ पे तो भई, मुझे consistency चाहिए" came back untransliterated in 6 of 6
/// runs at temperature 0 — it already had a comma, and the model appears to read
/// that as "already formatted, nothing to do". Other Hindi inputs passed 6 of 6.
/// So the failure is deterministic per input, not random, and no amount of
/// prompt wording makes it a promise. A cheap check after the fact does.
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
}
