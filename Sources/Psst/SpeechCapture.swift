import AVFoundation
import Speech
import OSLog

struct PsstError: LocalizedError {
    let text: String
    static func message(_ text: String) -> Self { Self(text: text) }
    var errorDescription: String? { text }
}

private final class AudioLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Float = 0
    var value: Float {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

@MainActor
final class SpeechCapture {
    private let engine = AVAudioEngine()
    private var fastSpeech: FastSpeech?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapped = false
    private var token = UUID()
    private var terminalResult: Result<String, Error>?
    private var completion: ((Result<String, Error>) -> Void)?
    private var fixtureTask: Task<Void, Never>?
    var onFixtureEnd: (() -> Void)?
    private var finishTimeout: Task<Void, Never>?
    private let meter = AudioLevel()
    private(set) var transcript = ""
    var level: Float { meter.value }
    var backendName: String { fastSpeech == nil ? "SFSpeechRecognizer" : "SpeechAnalyzer" }
    var onTranscript: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    static func requestPermissions() async -> Bool {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { return false }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return speech == .authorized
    }

    static var hasPermissions: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func start(fixture: URL? = nil, replayInRealTime: Bool = false) throws {
        cancel()
        guard Self.hasPermissions else { throw PsstError.message("Allow Microphone and Speech Recognition for Psst in System Settings → Privacy & Security.") }
        let current = token
        let file = try fixture.map { try AVAudioFile(forReading: $0) }
        let format = file?.processingFormat ?? engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancel()
            throw PsstError.message("No microphone is available. Connect one and try again.")
        }
        let append: @Sendable (AVAudioPCMBuffer) -> Void
        if let configuration = FastSpeech.configuration {
            let fast = try FastSpeech(configuration: configuration, inputFormat: format) { [weak self] text in
                guard let self, self.token == current else { return }
                self.transcript = text
                self.onTranscript?(text)
            } complete: { [weak self] result in
                guard let self, self.token == current else { return }
                if case .failure(let error) = result, self.completion == nil { self.onFailure?(error) }
                else { self.resolve(result) }
            }
            fastSpeech = fast
            let sink = fast.sink
            append = { sink.append($0) }
        } else {
            let request = try beginLegacyRecognition(token: current)
            append = { request.append($0) }
        }
        if let file {
            // Diagnostic input goes through the exact same audio consumer as the microphone.
            if replayInRealTime {
                fixtureTask = Task(priority: .userInitiated) { [weak self] in
                    do {
                        while file.framePosition < file.length {
                            try Task.checkCancellation()
                            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else { return }
                            try file.read(into: buffer)
                            append(buffer)
                            try await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate))
                        }
                        guard let self, self.token == current else { return }
                        self.onFixtureEnd?()
                    } catch is CancellationError { }
                    catch { self?.onFailure?(error) }
                }
            } else {
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                        throw PsstError.message("Couldn’t read the speech test fixture.")
                    }
                    try file.read(into: buffer)
                    append(buffer)
                }
            }
            return
        }
        let input = engine.inputNode
        let meter = meter
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            meter.value = min(1, max(0, (20 * log10(max(rms, 0.00001)) + 55) / 45))
        }
        tapped = true
        engine.prepare()
        do { try engine.start() } catch { cancel(); throw error }
    }

    private func beginLegacyRecognition(token current: UUID) throws -> SFSpeechAudioBufferRecognitionRequest {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw PsstError.message("On-device speech isn’t available for your current language. Enable Dictation for this language in System Settings → Keyboard, then try again.")
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .search
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            Task(priority: .userInitiated) { @MainActor in
                guard let self, self.token == current else { return }
                if let text { self.transcript = text; self.onTranscript?(text) }
                if final {
                    self.stopAudio()
                    self.resolve(.success(self.transcript))
                } else if let error {
                    self.stopAudio()
                    let failure = error as NSError
                    Logger(subsystem: "com.adamzafir.psst", category: "Speech").error("Recognition error: \(failure.domain, privacy: .public) / \(failure.code)")
                    if failure.domain == "kAFAssistantErrorDomain", failure.code == 1110 {
                        // A short tap or silence is not a transcription failure.
                        self.resolve(.success(self.transcript))
                    } else if self.completion != nil {
                        // Speech can report an end-of-audio error after a useful partial result.
                        if self.transcript.isEmpty { self.resolve(.failure(error)) }
                        else { self.resolve(.success(self.transcript)) }
                    } else { self.onFailure?(error) }
                }
            }
        }
        return request
    }

    func finish(_ completion: @escaping (Result<String, Error>) -> Void) {
        stopAudio()
        self.completion = completion
        if let terminalResult { resolve(terminalResult); return }
        fastSpeech?.finish()
        request?.endAudio()
        task?.finish()
        let current = token
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.transcript.isEmpty == false ? 1.2 : 3))
            guard !Task.isCancelled, let self, self.token == current else { return }
            self.resolve(.success(self.transcript))
        }
    }

    private func resolve(_ result: Result<String, Error>) {
        terminalResult = result
        guard let completion else { return }
        self.completion = nil
        finishTimeout?.cancel()
        completion(result)
    }

    private func stopAudio() {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        meter.value = 0
    }

    func cancel() {
        token = UUID()
        stopAudio()
        fixtureTask?.cancel(); fixtureTask = nil
        finishTimeout?.cancel()
        finishTimeout = nil
        completion = nil
        request?.endAudio()
        task?.cancel()
        fastSpeech?.cancel(); fastSpeech = nil
        task = nil; request = nil; recognizer = nil
        transcript = ""
        terminalResult = nil
    }

    static func userMessage(for error: Error) -> String {
        let error = error as NSError
        if error.domain == "kAFAssistantErrorDomain", [1100, 1101, 1107].contains(error.code) {
            return "Apple’s speech service stopped. Try again; if it persists, enable Dictation in System Settings → Keyboard."
        }
        if error.domain == "kLSRErrorDomain", [102, 201, 300].contains(error.code) {
            return "The speech model isn’t ready. Enable Dictation for your language in System Settings → Keyboard, then try again."
        }
        return "Couldn’t transcribe your question (\(error.domain) \(error.code)). Check Microphone and Speech Recognition permissions for Psst."
    }
}
