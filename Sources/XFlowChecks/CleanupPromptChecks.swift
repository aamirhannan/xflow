import XFlowCore

func checkCleanupPrompt() {
    let prompt = CleanupPrompt.system.lowercased()

    // Romanize, never translate: "mujhe yeh chahiye", not "I want this".
    Checks.check(prompt.contains("transliterate"), "prompt asks for transliteration")
    Checks.check(prompt.contains("do not translate"), "prompt forbids translation")

    // The pass is a formatter, not an editor. Every one of these words is load
    // bearing: without them the model silently drops trailing clauses and
    // condenses sentences, which is the whole reason this prompt was rewritten.
    Checks.check(prompt.contains("never remove"), "prompt forbids removing content")
    Checks.check(prompt.contains("condense"), "prompt forbids condensing")
    Checks.check(prompt.contains("summarize"), "prompt forbids summarizing")
    Checks.check(prompt.contains("every word in the input must appear in the output"),
                 "prompt demands every word survives")
    Checks.check(prompt.contains("leave it exactly as it is"),
                 "prompt tells the model to keep broken sentences untouched")
    Checks.check(prompt.contains("keep them"), "prompt keeps filler words")

    // Without this the model answers dictated questions instead of transcribing them.
    Checks.check(prompt.contains("never respond to it"), "prompt forbids answering the content")

    Checks.check(prompt.contains("no preamble"), "prompt forbids preamble in the output")
}
