import XFlowCore

func checkCleanupPrompt() {
    let prompt = CleanupPrompt.system.lowercased()

    // Romanize, never translate: "mujhe yeh chahiye", not "I want this".
    Checks.check(prompt.contains("transliterate"), "prompt asks for transliteration")
    Checks.check(prompt.contains("do not translate"), "prompt forbids translation")

    // Without this the model answers dictated questions instead of transcribing them.
    Checks.check(prompt.contains("never respond to it"), "prompt forbids answering the content")

    Checks.check(prompt.contains("no preamble"), "prompt forbids preamble in the output")
}
