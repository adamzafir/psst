import Foundation
import Speech
import AVFoundation

/// macOS 26 streaming ASR. Uses installed assets only; legacy Speech remains a
/// fallback for a language whose modern on-device assets aren't available.
@MainActor
final class FastSpeech {
    struct Configuration {
        let locale: Locale
        let format: AVAudioFormat
    }
    static var configuration: Configuration?
    private static var preparation: Task<Void, Never>?

    static func prepare() async {
        if let preparation { await preparation.value; return }
        let task = Task(priority: .userInitiated) {
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { return }
            let installed = await SpeechTranscriber.installedLocales
            guard installed.contains(where: { $0.identifier == locale.identifier }) else { return }
            // Reservation makes installed shared assets available to this app;
            // status(forModules:) can otherwise report merely "supported".
            guard (try? await AssetInventory.reserve(locale: locale)) != nil else { return }
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            guard await AssetInventory.status(forModules: [module]) == .installed,
                  let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { return }
            configuration = Configuration(locale: locale, format: format)
        }
        preparation = task
        await task.value
    }

    let sink: AnalyzerAudioSink
    private let analyzer: SpeechAnalyzer
    private var startTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var cancelled = false

    init(configuration: Configuration, inputFormat: AVAudioFormat,
         update: @escaping (String) -> Void, complete: @escaping (Result<String, Error>) -> Void) throws {
        let module = SpeechTranscriber(locale: configuration.locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        sink = try AnalyzerAudioSink(input: inputFormat, output: configuration.format, continuation: continuation)
        let analyzer = analyzer
        resultsTask = Task(priority: .userInitiated) { [weak self] in
            var finalized = ""
            var current = ""
            do {
                for try await result in module.results {
                    guard let self, !self.cancelled else { return }
                    let fragment = String(result.text.characters)
                    current = finalized.isEmpty || fragment.hasPrefix(" ") ? finalized + fragment : finalized + " " + fragment
                    update(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    if result.isFinal { finalized = current }
                }
                guard let self, !self.cancelled else { return }
                complete(.success(current.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                guard let self, !self.cancelled else { return }
                complete(.failure(error))
            }
        }
        startTask = Task(priority: .userInitiated) { [weak self] in
            do { try await analyzer.start(inputSequence: input) }
            catch {
                guard let self, !self.cancelled else { return }
                complete(.failure(error))
            }
        }
    }

    func finish() {
        sink.finish()
        let analyzer = analyzer
        let startTask = startTask
        finishTask = Task(priority: .userInitiated) {
            await startTask?.value
            guard !Task.isCancelled else { return }
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { /* The results sequence reports analyzer failures. */ }
        }
    }

    func cancel() {
        cancelled = true
        sink.finish()
        startTask?.cancel(); resultsTask?.cancel(); finishTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// The producer is the serial audio tap (or the serial fixture replay). Each
/// converted buffer owns its samples before crossing into the analyzer actor.
final class AnalyzerAudioSink: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation

    init(input: AVAudioFormat, output: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw PsstError.message("Couldn’t prepare the microphone’s audio format.")
        }
        self.converter = converter
        self.output = output
        self.continuation = continuation
    }

    func append(_ input: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * output.sampleRate / input.format.sampleRate)) + 32
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: buffer, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if error == nil, buffer.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: buffer)) }
    }

    func finish() { continuation.finish() }
}
