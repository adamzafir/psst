import Foundation

@main
struct AnswerRunTests {
    @MainActor static func main() async throws {
        let run = AnswerRun(key: QuestionKey("2+2")) { emit in
            emit("  ")
            emit("Four")
            emit("Four")
            emit("Four.")
        }
        var updates = [String]()
        try await run.attach { updates.append($0) }
        precondition(updates == ["Four", "Four."] || updates == ["Four."])
        var replay = [String]()
        try await run.attach { replay.append($0) }
        precondition(replay == ["Four."], "A confirmed candidate must immediately replay its buffered answer")

        let cancelled = AnswerRun(key: QuestionKey("cancel")) { emit in
            try await Task.sleep(for: .seconds(10))
            emit("This must never appear")
        }
        var staleUpdates = 0
        let consumer = Task { try await cancelled.attach { _ in staleUpdates += 1 } }
        await Task.yield()
        cancelled.cancel()
        do { try await consumer.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError { }
        precondition(staleUpdates == 0)

        let failure = AnswerRun(key: QuestionKey("error")) { _ in throw PsstError.message("test failure") }
        do { try await failure.attach { _ in }; preconditionFailure("Expected generation failure") }
        catch { precondition(error.localizedDescription == "test failure") }

        let empty = AnswerRun(key: QuestionKey("empty")) { _ in }
        do { try await empty.attach { _ in }; preconditionFailure("Empty output must fail") }
        catch { precondition(error.localizedDescription.contains("No answer")) }
        print("PASS: 4 answer buffering, cancellation, failure, and empty-stream regressions")
    }
}
