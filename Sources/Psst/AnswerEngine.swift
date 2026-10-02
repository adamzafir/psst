import Foundation
import FoundationModels

@MainActor
final class AnswerEngine {
    static let instructions = """
   Give a direct, glanceable answer with enough information for the user to confidently answer the question aloud.  
   For academic questions, include the important definition, explanation, formula, units, or key details when relevant.
    Prefer roughly 30–70 words, but use the length needed to answer properly.  Prioritize useful information over with brevity when needed.
    Use simple, natural language that can be understood quickly at a glance. 
    Avoid introductions, conclusions, filler, repetition, and follow-up offers.
   """
    private let enableSpeculation: Bool
    private(set) var generationCount = 0
    private(set) var reusedCandidate = false
    init(enableSpeculation: Bool = false) { self.enableSpeculation = enableSpeculation }
    private var prepared: LanguageModelSession?
    private var lastWarm = -Double.infinity
    private var warmedPrefix = ""
    private var pending: AnswerRun?
    private var draftKey: QuestionKey?
    private var draftTask: Task<Void, Never>?

    var unavailableMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri to use Psst."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn’t support Apple Intelligence. Psst needs an Apple silicon Mac with Apple Intelligence."
        case .unavailable(.modelNotReady):
            return "Apple’s on-device model is still downloading or preparing. Try again once Apple Intelligence is ready."
        case .unavailable: return "Apple’s on-device model is unavailable right now. Try again shortly."
        }
    }

    /// Re-prewarm an existing session as well: the OS may have evicted an idle model.
    /// Prefixes are cached while speech is arriving, outside the release-to-answer path.
    func prepare(prefix: String? = nil) {
        guard unavailableMessage == nil, pending == nil else { return }
        if prepared == nil { prepared = LanguageModelSession(instructions: Self.instructions) }
        let now = ProcessInfo.processInfo.systemUptime
        if let prefix {
            // Cache one early prefix. Repeated prewarm calls right before release
            // can queue redundant prefill work instead of accelerating generation.
            guard warmedPrefix.isEmpty, now - lastWarm >= 0.7 else { return }
            warmedPrefix = prefix
            prepared?.prewarm(promptPrefix: Prompt(prefix))
        } else {
            guard now - lastWarm >= 1 else { return }
            prepared?.prewarm()
        }
        lastWarm = now
    }

    /// Cache an early prefix while speaking. Speculative generation is opt-in
    /// for benchmarks: ASR revisions otherwise waste inference and its warm session.
    func observeDraft(_ question: String) {
        let key = QuestionKey(question)
        guard key != draftKey else { return }
        draftKey = key
        draftTask?.cancel()
        if let pending, pending.key != key { pending.cancel(); self.pending = nil }
        prepare(prefix: question)
        guard enableSpeculation, question.split(whereSeparator: \.isWhitespace).count >= 3 else { return }
        draftTask = Task(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.draftKey == key else { return }
            self.stage(question)
        }
    }

    /// Start inference while Speech drains its final audio buffers. Nothing is
    /// displayed unless the final transcript matches this candidate.
    func stage(_ question: String, confirmed: Bool = false) {
        guard enableSpeculation || confirmed else { return }
        draftTask?.cancel(); draftTask = nil
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = QuestionKey(question)
        if pending?.key == key { return }
        pending?.cancel()
        let session = prepared ?? LanguageModelSession(instructions: Self.instructions)
        prepared = nil
        warmedPrefix = ""
        lastWarm = -.infinity
        generationCount += 1
        pending = AnswerRun(key: key, question: question, session: session)
    }

    func answer(_ question: String, update: @escaping (String) -> Void) async throws {
        try Task.checkCancellation()
        if let message = unavailableMessage { throw PsstError.message(message) }
        reusedCandidate = pending?.key == QuestionKey(question)
        stage(question, confirmed: true)
        guard let pending else { throw PsstError.message("No question was heard.") }
        try await pending.attach(update)
    }

    func cancel() {
        draftTask?.cancel(); draftTask = nil; draftKey = nil
        pending?.cancel()
        pending = nil
        warmedPrefix = ""; lastWarm = -.infinity
        generationCount = 0; reusedCandidate = false
    }
}

/// One in-flight candidate. The latest text can be replayed immediately when
/// final speech confirms the question; revised speech discards it completely.
@MainActor
final class AnswerRun {
    let key: QuestionKey
    private var text = ""
    private var result: Result<Void, Error>?
    private var observer: ((String) -> Void)?
    private var waiter: CheckedContinuation<Void, Error>?
    private var task: Task<Void, Never>?

    convenience init(key: QuestionKey, question: String, session: LanguageModelSession) {
        self.init(key: key) { emit in
            let stream = session.streamResponse(to: question,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 256))
            for try await response in stream {
                try Task.checkCancellation()
                emit(response.content)
            }
        }
    }

    init(key: QuestionKey, generate: @escaping @MainActor (@escaping (String) -> Void) async throws -> Void) {
        self.key = key
        task = Task(priority: .userInitiated) { [weak self] in
            do {
                try Task.checkCancellation()
                try await generate { [weak self] output in
                    guard let self, self.result == nil else { return }
                    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, text != self.text else { return }
                    self.text = text
                    self.observer?(text)
                }
                guard let self else { return }
                if self.text.isEmpty { throw PsstError.message("No answer came back. Hold Option–Space to try again.") }
                self.finish(.success(()))
            } catch { self?.finish(.failure(error)) }
        }
    }

    func attach(_ update: @escaping (String) -> Void) async throws {
        try Task.checkCancellation()
        observer = update
        if !text.isEmpty { update(text) }
        if let result { return try result.get() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        task?.cancel()
        finish(.failure(CancellationError()))
        text = ""
        observer = nil
    }

    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        waiter?.resume(with: result)
        waiter = nil
        observer = nil
    }
}
