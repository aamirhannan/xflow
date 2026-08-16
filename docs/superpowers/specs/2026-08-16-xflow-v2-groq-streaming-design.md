# XFlow v2 — Groq transcription with silence-based segmentation

**Date:** 2026-08-16
**Status:** Approved design, ready for implementation planning
**Supersedes provider choices in:** `2026-08-16-xflow-dictation-design.md`

## Problem

v1 works, but the wait after releasing `fn` scales with how long you spoke.
Measured on the running app:

| Audio | STT | Cleanup | Total wait |
| --- | --- | --- | --- |
| ~12s | 1.02s | 0.94s | 1.96s |
| ~25s | 1.22s | 1.08s | 2.30s |
| ~65s | 3.47s | 2.84s | 6.31s |
| ~126s | 5.45s | 4.11s | 9.56s |

Two findings drive this redesign. First, the cleanup call is nearly as expensive
as transcription and had gone unnoticed — any fix that only addresses speech-to-
text leaves half the latency in place. Second, both legs run on OpenAI at
$0.36/hour, roughly ₹32/hour, when a materially better option exists.

## Benchmark evidence

All numbers below come from a single 4-minute recording of the user's own
Hinglish speech (`audio.opus`, converted to m4a), not from published benchmarks.
Vendor WER figures are overwhelmingly English-only and proved useless here.

### Latency

| Model | 4-min clip | 42s clip |
| --- | --- | --- |
| OpenAI `gpt-4o-transcribe` | 11.04s | 3.01s |
| Groq `whisper-large-v3` | HTTP 500 (3 attempts) | 4.14s |
| Groq `whisper-large-v3-turbo` | 1.55s | 1.00s |
| Groq `whisper-large-v3-turbo` + vocabulary prompt | — | **0.71s** |

### Accuracy on code-switched Hinglish

The speaker mixes Hindi with English technical vocabulary. Preserving English
terms in Latin script is the property that makes the tool useful; phonetic
transliteration into Devanagari destroys it.

| Spoken | Groq turbo (default) | **Groq turbo + vocab** | OpenAI 4o (default) | OpenAI 4o + vocab |
| --- | --- | --- | --- | --- |
| simple language | ✅ | ✅ | ✅ | ❌ `सिंपल लैंग्रेज` |
| actually | ✅ | ✅ | ✅ | ❌ `अक्शली` |
| already scope | ❌ `ओल्रेडी स्कूप` | ✅ | ✅ | ❌ `अल्रेडी स्कोप` |
| risk owner | ❌ `response और` | ✅ | ✅ | ❌ `रिस्कोनर` |
| SOX | ❌ `शॉक्स` | ✅ | ❌ `सॉक्स` | ❌ `सौक्स` |
| RBAC | ❌ `आरबैक` | ✅ mostly | ❌ `आरबैक` | ❌ `आरबैक` |

**Groq turbo with a vocabulary prompt is the only configuration that gets both
`SOX` and `risk owner` right.** It is also 15x faster and 9x cheaper than the
current setup.

### Three findings that shape the design

1. **The vocabulary prompt helps Groq and actively harms OpenAI.** The same
   `prompt` parameter that fixes Groq's acronym handling pushed
   `gpt-4o-transcribe` into romanizing everything into Devanagari. The prompt is
   therefore coupled to the provider, not a general-purpose knob.
2. **`language=en` must never be sent.** With it, Whisper translated and
   summarized instead of transcribing — "I will tell you about our simple
   language actually here we have here socks and internal audits already scope
   auditor we can see that already sorted" — losing most of the content. Auto-
   detection only.
3. **`whisper-large-v3` is worse than `turbo` here and less reliable.** It
   produced the most degraded transcript of any run and returned HTTP 500 three
   times on the 983KB file. The cheaper model is the better model for this
   workload.

## Goals

1. Replace OpenAI with Groq for both legs.
2. Make the wait after releasing `fn` roughly constant regardless of how long the
   user spoke, by transcribing during the recording rather than after it.
3. Preserve accuracy on code-switched Hinglish, which remains the top priority.

## Non-goals

No provider abstraction — Groq only, one implementation, no protocol or factory.
No WebSocket or real-time streaming API: Groq has no streaming transcription
endpoint, and OpenAI's Realtime transcription costs $1.02/hour, roughly 3x the
current spend and 29x Groq. No transcript history, analytics, or per-app
profiles. No automatic failover to a second provider.

## Decisions

| Decision | Choice | Reason |
| --- | --- | --- |
| Transcription | Groq `whisper-large-v3-turbo` | Fastest, cheapest, and most accurate on the benchmark |
| Cleanup | Groq `openai/gpt-oss-20b` | 1000 tokens/sec; turns a 4.11s cleanup into roughly 0.4s |
| Endpoints | `api.groq.com/openai/v1/...` | OpenAI-compatible request shapes; existing request builders need only a base URL |
| Vocabulary prompt | User-editable, sent to STT only | The single change that made Groq win |
| `language` parameter | Never sent | Causes translation and summarization |
| Segment boundary | Silence, not fixed time | A pause never cuts a word in half |
| Minimum segment | 10s | Exactly Groq's minimum billed duration, so segmenting costs nothing extra |
| Audio capture | `AVAudioEngine` | `AVAudioRecorder` cannot surface audio mid-recording |
| Cleanup scope | Per segment | Cleanup is a pure formatter, so formatting is a local operation |

## Architecture

### Phase 1 — Provider swap

Both API calls move to Groq. Because Groq's endpoints are OpenAI-compatible, the
existing request builders in `XFlowCore/OpenAI.swift` need only a base URL and
new model names. The `prompt` field is added to the transcription request.

The OpenAI key is removed from the settings window and replaced by a Groq key,
stored in the Keychain under the same service with account `groq`.

Expected result, projected from the benchmark: a 126s dictation drops from 9.56s
to roughly 1.8s, and cost from ₹32/hour to about ₹4/hour — likely ₹0 within
Groq's reported free tier of 2,000 requests per day.

**Phase 1 must be measured before Phase 2 is built.** If it lands near 1.8s, the
remaining gain from segmentation is roughly 0.6s on long dictations, and the user
may reasonably decide the added complexity is not worth it.

### Phase 2 — Silence-based segmentation

`AVAudioRecorder` is replaced by `AVAudioEngine` with a tap on the input node,
delivering PCM buffers roughly every 93ms. Each buffer yields one RMS value used
for two purposes: driving the existing waveform, and detecting silence. One
signal, no additional machinery.

**Segment rules:**

- A pause is RMS below the adaptive noise floor for at least 600ms.
- A segment closes on a pause only once it is at least 10s long.
- A segment that reaches 30s without a pause is force-closed at the quietest
  point in its last 2 seconds.

**Threshold calibration.** A fixed decibel threshold will be wrong: room noise,
microphone gain, and background activity all move it. The noise floor adapts from
a running minimum, and the sensitivity is exposed as a user-adjustable setting.

**Pipeline.** Each closed segment is written to its own AAC file, indexed, and
sent through transcription and cleanup concurrently, capped at 3 in flight.
Results are collected by index. On `fn` release only the tail segment remains
unprocessed; it is transcribed, and the accumulated text is assembled in index
order and pasted.

**Correctness insurance.** The whole session's PCM is retained in memory —
approximately 3.8MB at the 120s cap — so that if any segment permanently fails,
the complete audio can be rebuilt and sent as a single request using the v1 path.
No words are ever lost to a dropped segment.

**Kill switch.** A menu-bar toggle reverts to single-shot mode. The v1 path stays
in the code. This is deliberate insurance: the tool currently works well, and a
segmentation bug must not leave the user without dictation.

### Projected outcome

| Dictation | v1 (measured) | Phase 1 | Phase 2 |
| --- | --- | --- | --- |
| 25s | 2.30s | ~1.0s | ~1.0s |
| 65s | 6.31s | ~1.3s | ~1.2s |
| 126s | 9.56s | ~1.8s | ~1.2s |
| Cost/hour | ₹32 | ~₹4 | ~₹4.5 |

Phase 2's benefit is bounded and appears only on long dictations. It is worth
building only if Phase 1's measured numbers leave a gap the user cares about.

## Error handling

| Failure | Behaviour |
| --- | --- |
| Segment request fails twice | Rebuild full audio from retained PCM, single request via the v1 path |
| Whole-audio fallback also fails | Existing behaviour: text on clipboard, notification, error on the pill |
| Cleanup fails for a segment | Use that segment's raw transcript; never lose words |
| Recording exceeds 25MB (Groq limit) | Cannot occur: the 120s cap bounds a session to roughly 500KB |
| No Groq key | Pill reports it and opens settings |

All v1 guarantees are preserved: every failure degrades toward text on the
clipboard, never toward lost words.

## Testing

**Automated**, in `XFlowChecks`: the silence detector against synthetic RMS
sequences (pause detected, pause too short, segment below the 10s floor not
closed, force-close at 30s); segment assembly and ordering, including
out-of-order completion; request construction for the Groq base URL, model names,
vocabulary prompt inclusion, and a check asserting `language` is never sent.

**Manual**, added to the README checklist: dictate a 3-minute Hinglish passage
and confirm no word is dropped at a segment boundary; confirm the wait after
release does not grow with dictation length; force a segment failure with the
network off mid-dictation and confirm the whole-audio fallback recovers; confirm
the kill switch restores single-shot behaviour.

## Risks

- **The benchmark is one 4-minute sample.** It is far stronger evidence than
  published WER for this workload, but if `turbo` mangles something important in
  daily use, the model name is a setting away from change.
- **Removing OpenAI removes the fallback.** An explicit user decision: fewer
  moving parts over redundancy.
- **The silence threshold needs real-world tuning.** Hence the exposed knob.
- **Sparse punctuation from `turbo`** is accepted, because adding punctuation and
  capitalization is already the cleanup prompt's job.

## Definition of done

Holding `fn`, speaking mixed Hindi and English for two minutes, and releasing
produces correctly formatted romanized text in the active field in roughly one
second, at under ₹5 per hour of dictation, with no word lost at any segment
boundary.
