# Psst latency

Measured on 20 September 2026: M2 MacBook Air, 8 GB RAM, macOS 27 beta, on battery with **Low Power Mode enabled**. Power settings were not changed. These are small, sequential local trials, not a controlled hardware benchmark or a guaranteed response time.

## Changes

- Use installed, on-device `SpeechAnalyzer` assets with `SpeechTranscriber.fastResults`, retaining legacy on-device recognition as a fallback.
- Finalize speech explicitly on release. Bound the legacy/failed-finalization wait to 1.2 seconds with partial text, or 3 seconds without it.
- Prewarm the Foundation Models session at launch and shortcut press. Cache an early speech prefix while the user speaks.
- Generate once against the finalized transcript. Speculative generation on partial speech was tested and disabled: revisions triggered 2–4 generations per question and none of the six candidates matched the final transcript.
- Stream text immediately using greedy decoding and a 256-token limit. Preserve the user's revised system prompt, including its 30–70-word preference.
- Use user-initiated tasks and a latency-critical process activity only during an active question. Release it on cancellation, completion, or failure.
- Keep the transcript and animated thinking state visible throughout the wait. Log release-to-first-text timings locally without question content.

## Results

Synthetic Samantha speech was replayed at real speaking speed through the same audio consumer as the microphone. Release occurs after the last audio buffer. Three questions (sky colour, Newton's second law, cell division) were repeated twice per configuration. These measurements include speech finalization and model startup, and distinguish first visible text from a completed answer.

| Configuration | Median first text | First-text range | Trials under 2 s |
| --- | ---: | ---: | ---: |
| Final-transcript generation (shipping default) | 1.936 s | 1.784–6.475 s | 4/6 |
| Speculative partial-transcript generation | 2.919 s | 0.914–5.123 s | 2/6 |

The first shipping-configuration trial took 6.475 seconds; the second took 2.527 seconds. Subsequent trials took 1.784–1.989 seconds to first text and 2.781–3.250 seconds to finish. Model residency, memory pressure, other activity, and speech length affect results. A dependable 1–2-second upper bound has **not** been achieved, especially for first/cold requests. Streaming does not make the entire answer available at the first-text time. No hardware or power-setting changes are assumed.

A fresh-process verification of the installed build measured first text at **6.013, 3.038, and 2.443 seconds**, with final speech at 0.383–0.753 seconds. Together, the nine trials of the shipping configuration have a 2.443-second median and a 1.784–6.475-second range. This retest reinforces that the faster warm trials are not a reliable upper bound.

[Recorded timings](docs/latency-2026-09-20.csv). The benchmark checks latency, not factual correctness; Apple’s model can still give incorrect answers. Physical microphone testing remains a manual check.

## Reproduce

Quit the normal Psst instance first. Build and install, then create synthetic audio without recording the microphone:

```sh
./scripts/build.sh --install
say -v Samantha -o .build/sky.aiff 'Why does the sky look blue during the day?'
say -v Samantha -o .build/newton.aiff 'What is Newtons second law?'
say -v Samantha -o .build/biology.aiff 'What is the difference between mitosis and meiosis?'
open -W ~/Applications/Psst.app --args --pipeline-benchmark "$PWD/.build/latency.csv" \
  "$PWD/.build/sky.aiff" "$PWD/.build/newton.aiff" "$PWD/.build/biology.aiff" \
  "$PWD/.build/sky.aiff" "$PWD/.build/newton.aiff" "$PWD/.build/biology.aiff"
open ~/Applications/Psst.app
```

The CSV is updated after each question, including backend, first text, completion, generation count, and Low Power Mode status. Explicit diagnostic reports include synthetic transcripts and generated answers; normal use does not save them. To compare the experimental speculative path, place `--speculate` before `--pipeline-benchmark`. Do not run multiple model benchmarks concurrently.

`./scripts/test.sh` checks shortcut handling, conservative question matching, buffered streaming, cancellation, failure, and empty results (18 checks).
