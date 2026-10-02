import Foundation
import FoundationModels

@MainActor
enum PerformanceBenchmarks {
    static func run(report: URL) async {
        let questions = ["Why does the sky look blue during the day?", "What is Newton's second law?", "What is the difference between mitosis and meiosis?"]
        var rows = ["mode,question,first_text_seconds,total_seconds,updates,words"]
        func write() { try? rows.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8) }
        write()
        for index in 0..<9 {
            let question = questions[index / 3]
            let mode = index % 3
            let session = LanguageModelSession(instructions: AnswerEngine.instructions)
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Psst latency benchmark")
            session.prewarm(promptPrefix: Prompt(question))
            try? await Task.sleep(for: .seconds(2))
            let start = Date()
            var first: Double?
            var updates = 0
            var last = ""
            do {
                for try await snapshot in session.streamResponse(to: question, options: mode == 2 ? GenerationOptions(sampling: .greedy, maximumResponseTokens: 256) : GenerationOptions(temperature: 0.2, maximumResponseTokens: mode == 0 ? 512 : 256)) {
                    let text = snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if first == nil { first = Date().timeIntervalSince(start) }
                    updates += 1
                    last = text
                }
                let name = ["prefix_512", "prefix_256", "prefix_greedy_256"][mode]
                rows.append("\(name),\(index / 3),\(String(format: "%.3f", first ?? -1)),\(String(format: "%.3f", Date().timeIntervalSince(start))),\(updates),\(last.split(whereSeparator: \.isWhitespace).count)")
            } catch { rows.append("ERROR,\(index),\(error.localizedDescription)") }
            ProcessInfo.processInfo.endActivity(activity)
            write()
        }
    }
}

extension PerformanceBenchmarks {
    /// Replays recorded synthetic speech at its real speaking speed. Measures
    /// key-release-to-text, including final speech decoding, not just model time.
    static func pipeline(fixtures: [URL], report: URL) async {
        var rows = ["question,backend,release_to_final_speech,release_to_first_text,release_to_complete,stream_updates,generations,reused_candidate,low_power,transcript,answer"]
        func write() { try? rows.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8) }
        write()
        guard await SpeechCapture.requestPermissions() else { rows.append("ERROR,permissions"); write(); return }
        await FastSpeech.prepare()
        let engine = AnswerEngine(enableSpeculation: CommandLine.arguments.contains("--speculate"))
        for (index, fixture) in fixtures.enumerated() {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Psst voice pipeline benchmark")
            let speech = SpeechCapture()
            var released: TimeInterval?
            speech.onTranscript = { text in
                if released == nil { engine.observeDraft(text) }
            }
            engine.prepare()
            do {
                let result: Result<String, Error> = await withCheckedContinuation { completion in
                    var finished = false
                    func finish(_ result: Result<String, Error>) {
                        guard !finished else { return }; finished = true
                        completion.resume(returning: result)
                    }
                    speech.onFailure = { finish(.failure($0)) }
                    speech.onFixtureEnd = {
                        released = ProcessInfo.processInfo.systemUptime
                        engine.stage(speech.transcript)
                        speech.finish { finish($0) }
                    }
                    do { try speech.start(fixture: fixture, replayInRealTime: true) }
                    catch { finish(.failure(error)) }
                }
                let question = try result.get()
                let backend = speech.backendName
                speech.cancel()
                guard !question.isEmpty, let releaseTime = released else { throw PsstError.message("No fixture transcript") }
                let finalized = ProcessInfo.processInfo.systemUptime - releaseTime
                var first: Double?
                var answer = ""
                var updates = 0
                try await engine.answer(question) { text in
                    if first == nil { first = ProcessInfo.processInfo.systemUptime - releaseTime }
                    answer = text
                    updates += 1
                }
                let total = ProcessInfo.processInfo.systemUptime - releaseTime
                func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\n", with: " ") + "\"" }
                rows.append("\(index),\(backend),\(String(format: "%.3f", finalized)),\(String(format: "%.3f", first ?? -1)),\(String(format: "%.3f", total)),\(updates),\(engine.generationCount),\(engine.reusedCandidate),\(ProcessInfo.processInfo.isLowPowerModeEnabled),\(quoted(question)),\(quoted(answer))")
            } catch { rows.append("ERROR,\(index),\(error.localizedDescription)") }
            speech.cancel(); engine.cancel()
            ProcessInfo.processInfo.endActivity(activity)
            write()
        }
    }
}
