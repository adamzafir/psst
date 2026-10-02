import AppKit
import Speech
import ServiceManagement

/// Explicit developer smoke test. Only fixed, synthetic questions are printed.
@MainActor
enum Diagnostics {
    static func run() async {
        let engine = AnswerEngine()
        print("Model: \(engine.unavailableMessage ?? "available")")
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        print("Speech locale: \(Locale.current.identifier); on-device: \(recognizer?.supportsOnDeviceRecognition == true)")
        print("Permissions: \(SpeechCapture.hasPermissions); login status: \(SMAppService.mainApp.status.rawValue)")
        let hotKey = HotKey()
        do {
            try hotKey.install()
            precondition(hotKey.setEscapeEnabled(true), "Esc registration failed")
            hotKey.setEscapeEnabled(false)
            hotKey.uninstall()
            print("PASS: Option–Space and Esc registration and cleanup")
        } catch { print("FAIL: shortcut registration: \(error.localizedDescription)") }
        let overlay = Overlay()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        overlay.chooseScreen()
        overlay.show(.recording)
        try? await Task.sleep(for: .milliseconds(300))
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "Recording indicator stole focus")
        overlay.updateTranscript("What is a light-year?")
        overlay.show(.thinking)
        precondition(overlay.model.transcript == "What is a light-year?" && overlay.model.isWorking)
        overlay.show(.streaming, text: "A light-year is")
        precondition(overlay.model.isWorking && !overlay.model.text.isEmpty)
        overlay.show(.answer, text: "A light-year is the distance light travels in one year: about 9.46 trillion kilometres.")
        try? await Task.sleep(for: .milliseconds(300))
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "Answer panel stole focus")
        precondition(NSApp.keyWindow == nil, "Overlay became the key window")
        overlay.hide()
        precondition(!overlay.isVisible && overlay.model.transcript.isEmpty && overlay.model.text.isEmpty)
        print("PASS: recording and answer panels preserve foreground app and keyboard focus; dismissal hides panel")
        guard engine.unavailableMessage == nil else { print("SKIP: model generation unavailable"); return }
        for question in ["What is a light-year?", "What is 12 times 8?", "What is the formula for the area of a circle?"] {
            do {
                let start = Date()
                var answer = ""
                try await engine.answer(question) { answer = $0 }
                let count = answer.split(whereSeparator: { $0.isWhitespace }).count
                print("ANSWER (\(count) words, \(String(format: "%.2f", Date().timeIntervalSince(start)))s): \(answer)")
                precondition(!answer.isEmpty)
                if count > 100 { print("NOTE: answer is longer than the preferred 30–70-word range") }
            } catch { print("FAIL: model generation: \(error)") }
        }
    }
}

extension Diagnostics {
    static func runSpeechFixture(_ fixture: URL, report: URL) async {
        var lines = ["Psst streaming speech → Foundation Models integration test"]
        defer {
            try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        let allowed = await SpeechCapture.requestPermissions()
        lines.append("Speech and microphone permissions: \(allowed)")
        guard allowed else { lines.append("FAIL: permissions unavailable"); return }
        await FastSpeech.prepare()
        let speech = SpeechCapture()
        let overlay = Overlay()
        overlay.chooseScreen()
        var transcriptUpdates = 0
        speech.onTranscript = { text in transcriptUpdates += 1; overlay.updateTranscript(text) }
        defer { overlay.hide() }
        do {
            overlay.show(.recording)
            try speech.start(fixture: fixture)
            overlay.show(.transcribing)
            let result: Result<String, Error> = await withCheckedContinuation { continuation in
                speech.finish { continuation.resume(returning: $0) }
            }
            let transcript = try result.get()
            speech.cancel()
            guard !transcript.isEmpty else { throw PsstError.message("No transcript returned for voiced fixture") }
            lines.append("Fixture transcript: \(transcript)")
            lines.append("Live transcript updates: \(transcriptUpdates)")
            precondition(transcriptUpdates > 0 && overlay.model.transcript == transcript)
            overlay.show(.thinking)
            let engine = AnswerEngine()
            var answer = ""
            var updates = 0
            var firstToken: Double?
            var uiTicks = 0
            let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in uiTicks += 1 }
            defer { timer.invalidate() }
            let start = Date()
            try await engine.answer(transcript) {
                if firstToken == nil { firstToken = Date().timeIntervalSince(start) }
                updates += 1
                answer = $0
                overlay.show(.streaming, text: $0)
            }
            overlay.finishAnswer()
            precondition(overlay.model.mode == .answer && overlay.model.transcript == transcript)
            precondition(uiTicks > 0, "Main run loop must stay responsive while generating")
            lines.append("Answer: \(answer)")
            lines.append("Streaming updates: \(updates); first text: \(String(format: "%.2f", firstToken ?? 0))s; total: \(String(format: "%.2f", Date().timeIntervalSince(start)))s; UI ticks: \(uiTicks)")
            lines.append("PASS: streaming on-device transcription and model response")
        } catch { speech.cancel(); lines.append("FAIL: \(error)") }
    }
}
