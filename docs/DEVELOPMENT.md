# Development

## Implementation

- AppKit accessory application; an active Quartz session event tap at the head of the event stream consumes Option–Space key-down, auto-repeat, and key-up events. The filter runs on its own thread, requires Accessibility, and uses actual key edges rather than polling. Releasing Option first ends recording but continues swallowing Space until it comes up. Esc is consumed only for an active recording/overlay. Other keys pass through untouched. Nothing is logged about the keys you type. macOS Secure Input and earlier privileged system filters cannot be overridden by an ordinary app.
- `AVAudioEngine` feeds `SpeechAnalyzer` with `SpeechTranscriber.fastResults` when its language assets are installed. Audio is converted to the analyzer’s preferred format. Otherwise it uses `SFSpeechAudioBufferRecognitionRequest` with `requiresOnDeviceRecognition = true`; no server fallback. Releasing stops the microphone immediately and explicitly finalizes recognition, with a bounded fallback of 1.2 seconds when partial text exists or 3 seconds without text. No-speech results are dismissed silently; actual service failures keep their diagnostic domain/code. Empty speech is silently dismissed.
- `LanguageModelSession` uses Apple’s default on-device Foundation Model, a fresh session per question, a session prewarmed at launch and again while speaking for subsequent questions, early transcript prefix caching, and streamed text shown immediately. Generation begins once final speech is available: benchmarking found that repeatedly generating against changing partial transcripts made latency worse. The transcript remains above the answer, and a visible thinking state covers the wait for the first token. The current system prompt prefers roughly 30–70 words, with enough academic detail to answer properly. Greedy decoding and a 256-token ceiling bound generation work while allowing the requested answer length. Active requests use user-initiated, latency-critical scheduling; the activity ends on completion or cancellation. Low Power Mode is respected and never changed.
- Offline formatting renders Markdown emphasis, inline code, headings and bullets, plus common LaTeX notation as readable Unicode math (exponents, numeric subscripts, Greek symbols, square roots and parenthesized fractions). This is a lightweight formatter, not a full TeX typesetter; unsupported commands remain visible. Formatted text is measured using the same fonts as the display.
- Native `NSGlassEffectView` inside a borderless, nonactivating `NSPanel`. Supports Spaces, fullscreen apps, multiple displays, light/dark appearance, and Reduce Motion. The cyan/pink/purple orb uses flowing colour lobes and a deforming glass outline. Speech controls its size and movement, thinking accelerates the flow, and completed answers settle into a slow idle. Reduce Motion disables movement. The orb is painted before audio-device startup. Normal macOS microphone privacy indicators still appear.
- Main-actor interaction lifecycle: idle → starting → recording → transcribing → answering → showing. Per-request IDs reject stale callbacks. Esc, a new shortcut press, sleep, session deactivation, and quitting cancel work and release the microphone. Recording stops after 45 seconds; model generation times out after 35 seconds.
- During normal use, no audio, transcripts, answer history, or analytics are written to disk or sent to a third-party service. Apple may need to download speech and model assets during system setup. Local diagnostic logs contain latency timings and error codes, not question or answer content. Explicit benchmark modes write synthetic transcripts and answers to the chosen report file. Preferences only remember whether login startup was configured.

The on-device model has no web access and may answer factual questions incorrectly. It cannot retrieve live information.


## Verification

```sh
~/Applications/Psst.app/Contents/MacOS/Psst --self-test
```

Shortcut, question-matching, and stream lifecycle regression tests (work with Command Line Tools alone):

```sh
./scripts/test.sh
```

A synthetic audio fixture can verify the complete streaming speech-to-answer path without recording the microphone:

```sh
say -v Samantha -o .build/speech-fixture.aiff 'What is twelve times eight?'
# Quit the normal Psst instance first; launch via the app bundle for its permissions.
open -W ~/Applications/Psst.app --args --speech-test "$PWD/.build/speech-fixture.aiff" "$PWD/.build/speech-report.txt"
cat .build/speech-report.txt
```

Run the smoke test with the regular instance closed. This checks speech/model availability, event-tap installation, popup focus preservation and dismissal, then streams answers to three fixed questions and reports length and latency. It also checks that the transcript survives thinking/streaming transitions and is cleared on dismissal. It does not test physical microphone transcription. The separate fixture test exercises the same audio-buffer recognizer and finalization path used for microphone audio, counts live transcript and response updates, and checks that the main run loop remains responsive during generation.

Manual end-to-end checks:

1. Keep a text editor focused. Hold Option–Space, ask “What is a light-year?”, then release. Verify the indicator appears only while processing and the answer appears without moving focus.
2. Press Esc while recording, while thinking, and while showing an answer. Check that the microphone stops and late callbacks do not reopen the panel.
3. Verify Option–Space neither inserts text in an editor nor scrolls a web page. Release Option before Space; briefly tap the shortcut without speaking; begin another question during generation.
4. Try fullscreen and a second display. Move the pointer to that display before asking.
5. Disable a permission or Apple Intelligence and verify Psst explains how to restore availability. Check Launch at Login in System Settings.

Apple references: [on-device speech support](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition), [Foundation Models](https://developer.apple.com/documentation/foundationmodels), [NSPanel](https://developer.apple.com/documentation/appkit/nspanel), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).
