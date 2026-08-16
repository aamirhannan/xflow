# Version history — what changed and why

All three versions are Swift/AppKit. The differences are in *when* audio is sent
and *who* transcribes it, never in the language or UI framework.

> A note on V1: it is sometimes remembered as "plain JavaScript/HTML". It was
> not — XFlow has been a Swift menu-bar app since its first commit. What made V1
> feel primitive was that it made **one HTTP call after you finished speaking**,
> so the wait grew with how long you talked.

## Measured, end to end

| | V1 | V2 | V3 (current) |
| --- | --- | --- | --- |
| Audio sent | once, on release | in segments, while speaking | in segments, while speaking |
| Transcription | OpenAI `gpt-4o-transcribe` | Groq `whisper-large-v3-turbo` | OpenAI `gpt-4o-mini-transcribe` |
| Cleanup | OpenAI `gpt-4o-mini` | Groq `gpt-oss-20b` → `llama-3.3-70b` | Groq `llama-3.3-70b-versatile` |
| 13s dictation | 1.96s | 0.92s | ~1.48s |
| 126s dictation | **9.56s** | ~1.3s | ~1.5s |
| Cost per hour | ₹32 | ₹3.5 | ₹16 |
| Mixed Hindi + English | works | **broken, 0 of 6** | works, 6 of 6 |

## V1 — one call after you stop

Record the whole utterance to a single `.m4a`, POST it on release, run a cleanup
pass, paste.

Simple and correct, but the wait scaled with dictation length: 1.96s for 13
seconds of speech, **9.56s for two minutes**. Worse, the split was not where
anyone assumed — of that 9.56s, transcription was 5.45s and *cleanup was 4.11s*.
Any fix aimed only at speech-to-text would have left half the latency in place.

Four bugs were found and fixed in V1, all in [0003-findings](0003-findings.md):
dead HTTP/3 connections, retrying timeouts, the missing Edit menu, App Nap.

## V2 — transcribe while speaking, on Groq

Two changes at once, which in hindsight should have been sequenced.

**Segmentation.** `AVAudioRecorder` cannot surface audio mid-recording, so it was
replaced by `AVAudioEngine` with a tap. The RMS already computed for the waveform
also drives pause detection. A segment closes on a pause once it is ≥10s (Groq's
minimum billed duration, so segmenting costs nothing extra), or is force-closed
at 30s. On release only the tail remains — which is what makes the wait constant.

**Groq.** Chosen on a benchmark of the user's own Hinglish audio: with a
vocabulary prompt it beat `gpt-4o-transcribe` on accuracy at 15x the speed and a
ninth of the cost.

That benchmark was right about what it measured and wrong about what mattered.
It used a **Hindi-dominant** sample. On genuinely code-switched speech — the
app's actual daily use — Groq's Whisper deleted the Hindi entirely, in **0 of 6**
runs preserved. The failure was invisible because the output was fluent English.

Three more bugs surfaced here: the noise floor collapsing so pauses never fired,
`gpt-oss-20b` returning empty content and silently dropping whole segments, and
the cleanup model answering the speaker instead of transcribing them.

## V3 — split the providers

Transcription moved to OpenAI, cleanup stayed on Groq. Each provider does what it
measurably does best.

| Model | Result on three test recordings |
| --- | --- |
| Groq `whisper-large-v3-turbo` | translated the Hindi away; read pure Hindi as Urdu |
| Groq `whisper-large-v3` | dropped most of the content |
| OpenAI `gpt-4o-transcribe` | dropped most of the content |
| **OpenAI `gpt-4o-mini-transcribe`** | **correct on all three** |

Costs ~₹12/hour more than V2 and adds ~0.5s to the perceived wait, in exchange
for the one thing the app exists to do.

## Lessons that outlived their versions

- **Benchmark on the real workload.** The V2 benchmark used Hindi-dominant audio
  and the app's real use is code-switched. Published WER numbers were useless
  here — they are almost entirely English.
- **Run language tests more than once.** Several failures occur at ~50%. "Correct
  on all three files" was claimed from single runs and was wrong.
- **Fix latency where it is, not where you assume.** Cleanup was 43% of V1's wait
  and nobody had looked.
- **Two changes at once hides which one broke things.** V2 shipped segmentation
  and a provider swap together; the provider was the problem.
- **A prompt is not a guarantee.** Three prompt revisions failed before the
  output was verified mechanically instead.
