import Foundation

// `--probe <file>...` runs the real pipeline over audio instead of the checks.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--probe") {
    Probe.run(paths: Array(args[(i + 1)...]))
    exit(0)
}

// Each check group lives in its own file in this directory and exposes a
// top-level `check<Thing>()` function. Add the call here as each group lands.

checkSessionState()
checkMultipartBody()
checkXFlowError()
checkCleanupPrompt()
checkGroq()
checkVocabularyPrompt()
checkScript()
checkTranslationDetection()
checkClipboardSwap()
checkSilenceDetector()
checkSegmentPolicy()
checkTranscriptAssembler()
checkHistoryLog()

Checks.report()
