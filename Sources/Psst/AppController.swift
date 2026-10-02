import AppKit
import ServiceManagement
import AVFoundation
import OSLog

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Phase { case idle, starting, recording, transcribing, answering, showing }
    private var phase: Phase = .idle
    private let hotKey = HotKey()
    private let speech = SpeechCapture()
    private let answers = AnswerEngine()
    private let overlay = Overlay()
    private var status: NSStatusItem!
    private var performanceActivity: NSObjectProtocol?
    private var pressedAt: TimeInterval?
    private var releasedAt: TimeInterval?
    private var firstTextShown = false
    private let latencyLog = Logger(subsystem: "com.adamzafir.psst", category: "Latency")
    private var captureStart: Task<Void, Never>?
    private var permissionWatch: Timer?
    private var generation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var meterTimer: Timer?
    private var requestID = UUID()
    private var permissionsPending = false
    private var shortcutReady = false
    private var loginItem: NSMenuItem!
    private var readinessItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        hotKey.onPress = { [weak self] in self?.begin() }
        hotKey.onRelease = { [weak self] in self?.end() }
        hotKey.onEscape = { [weak self] in self?.dismiss() }
        overlay.model.dismiss = { [weak self] in self?.dismiss() }
        speech.onTranscript = { [weak self] text in
            guard let self, self.phase == .recording || self.phase == .transcribing else { return }
            self.overlay.updateTranscript(text)
            if self.phase == .recording { self.answers.observeDraft(text) }
        }
        speech.onFailure = { [weak self] error in
            guard let self, self.phase == .recording else { return }
            self.showNotice(SpeechCapture.userMessage(for: error))
        }
        installShortcut()
        if !HotKey.hasPermission {
            HotKey.requestPermission()
            permissionWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, HotKey.hasPermission else { return }
                    self.permissionWatch?.invalidate(); self.permissionWatch = nil
                    self.dismiss()
                    self.installShortcut()
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(suspend), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(resume), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(resume), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(suspend), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioChanged), name: .AVAudioEngineConfigurationChange, object: nil)
        if !UserDefaults.standard.bool(forKey: "didConfigureLogin") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "didConfigureLogin")
            } catch { NSLog("Psst login registration: %@", error.localizedDescription) }
        }
        answers.prepare()
        Task(priority: .userInitiated) { await FastSpeech.prepare() }
        if CommandLine.arguments.contains("--preview") {
            overlay.chooseScreen()
            showNotice("A light-year is the distance light travels in one year: about 9.46 trillion kilometres.", mode: .answer)
        } else if !HotKey.hasPermission {
            showNotice("Enable Psst in System Settings → Privacy & Security → Accessibility. This lets Psst intercept Option–Space before other apps.")
        } else if !SpeechCapture.hasPermissions {
            requestPermissions()
        } else if let message = answers.unavailableMessage { showNotice(message) }
    }

    private func configureMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Psst")
        status.button?.toolTip = "Psst · Hold ⌥ Space to ask"
        let menu = NSMenu()
        menu.delegate = self
        let shortcut = NSMenuItem(title: "Hold ⌥ Space to ask", action: nil, keyEquivalent: "")
        menu.addItem(shortcut)
        readinessItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(readinessItem)
        menu.addItem(.separator())
        add("Set Up Permissions…", #selector(setUp), to: menu)
        add("Retry Shortcut", #selector(retryShortcut), to: menu)
        loginItem = add("Launch at Login", #selector(toggleLogin), to: menu)
        add("Preview Answer", #selector(preview), to: menu)
        add("Dismiss", #selector(dismiss), to: menu)
        menu.addItem(.separator())
        add("Quit Psst", #selector(quit), to: menu, key: "q")
        status.menu = menu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let login = SMAppService.mainApp.status
        loginItem.state = login == .enabled ? .on : .off
        loginItem.title = login == .requiresApproval ? "Approve Launch at Login…" : "Launch at Login"
        readinessItem.title = !shortcutReady ? "Shortcut unavailable" : !SpeechCapture.hasPermissions ? "Permissions needed" : answers.unavailableMessage == nil ? "On-device · Ready" : "Apple Intelligence unavailable"
    }

    private func installShortcut() {
        hotKey.uninstall()
        do { try hotKey.install(); shortcutReady = true }
        catch { shortcutReady = false; showNotice(error.localizedDescription) }
    }

    private func requestPermissions() {
        guard !permissionsPending else { return }
        permissionsPending = true
        Task {
            let allowed = await SpeechCapture.requestPermissions()
            permissionsPending = false
            if !allowed {
                showNotice("Psst needs Microphone and Speech Recognition access. Enable both in System Settings → Privacy & Security, then hold Option–Space.")
            } else if let message = answers.unavailableMessage { showNotice(message) }
            else if !HotKey.hasPermission { showNotice("Enable Psst in System Settings → Privacy & Security → Accessibility to activate Option–Space.") }
            else { showNotice("Hold ⌥ Space, ask a question, then release. Press Esc to dismiss the answer.") }
        }
    }

    private func begin() {
        guard !permissionsPending else { return }
        dismiss()
        overlay.chooseScreen()
        guard SpeechCapture.hasPermissions else { requestPermissions(); return }
        if let message = answers.unavailableMessage { showNotice(message); return }
        performanceActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Answering a voice question")
        answers.prepare()
        pressedAt = ProcessInfo.processInfo.systemUptime
        phase = .starting
        overlay.show(.recording)
        hotKey.setEscapeEnabled(true)
        let id = requestID
        // Paint the orb before synchronous audio-device startup.
        captureStart = Task(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, requestID == id, phase == .starting else { return }
            do {
                try speech.start()
                phase = .recording
                captureStart = nil
                meterTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.overlay.model.level = self.speech.level
                    }
                }
                deadline = Task {
                    try? await Task.sleep(for: .seconds(45))
                    guard !Task.isCancelled, requestID == id, phase == .recording else { return }
                    end()
                }
            } catch { showNotice(error.localizedDescription) }
        }
    }

    private func end() {
        if phase == .starting { dismiss(); return }
        guard phase == .recording else { return }
        // A brief accidental hold cancels immediately, even if background
        // audio produced a partial transcript. Do not wait for ASR finalization.
        guard let pressedAt, ProcessInfo.processInfo.systemUptime - pressedAt >= 0.4 else {
            dismiss()
            return
        }
        phase = .transcribing
        releasedAt = ProcessInfo.processInfo.systemUptime
        firstTextShown = false
        deadline?.cancel()
        meterTimer?.invalidate(); meterTimer = nil
        overlay.show(.transcribing)
        let id = requestID
        speech.finish { [weak self] result in
            guard let self, self.requestID == id, self.phase == .transcribing else { return }
            self.speech.cancel()
            if let released = self.releasedAt {
                self.latencyLog.info("Speech finalized after release: \(ProcessInfo.processInfo.systemUptime - released, privacy: .public)s")
            }
            switch result {
            case .success(let transcript):
                let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if question.isEmpty { self.dismiss() } else { self.respond(to: question, id: id) }
            case .failure(let error):
                self.showNotice(SpeechCapture.userMessage(for: error))
            }
        }
    }

    private func respond(to question: String, id: UUID) {
        phase = .answering
        overlay.updateTranscript(question)
        overlay.show(.thinking)
        deadline = Task {
            try? await Task.sleep(for: .seconds(35))
            guard !Task.isCancelled, requestID == id, phase == .answering else { return }
            showNotice("The on-device model took too long. Hold Option–Space to try again.")
        }
        generation = Task(priority: .userInitiated) {
            do {
                try await answers.answer(question) { [weak self] text in
                    guard let self, self.requestID == id else { return }
                    if !self.firstTextShown {
                        self.firstTextShown = true
                        if let released = self.releasedAt {
                            self.latencyLog.info("Release to first answer text: \(ProcessInfo.processInfo.systemUptime - released, privacy: .public)s")
                        }
                    }
                    self.overlay.show(.streaming, text: text)
                }
                guard !Task.isCancelled, requestID == id else { return }
                phase = .showing
                overlay.finishAnswer()
                endPerformanceActivity()
                deadline?.cancel()
                scheduleDismiss(seconds: 22)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, requestID == id else { return }
                showNotice("Couldn’t answer that on-device. Try a shorter or differently worded question.")
            }
        }
    }

    private func scheduleDismiss(seconds: Double) {
        dismissTask?.cancel()
        let id = requestID
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, requestID == id else { return }
            dismiss()
        }
    }

    private func showNotice(_ text: String, mode: OverlayModel.Mode = .notice) {
        dismiss()
        phase = .showing
        overlay.show(mode, text: text)
        hotKey.setEscapeEnabled(true)
        scheduleDismiss(seconds: 22)
    }

    @objc private func dismiss() {
        requestID = UUID()
        captureStart?.cancel(); captureStart = nil
        generation?.cancel(); generation = nil
        answers.cancel()
        endPerformanceActivity()
        pressedAt = nil
        releasedAt = nil; firstTextShown = false
        deadline?.cancel(); deadline = nil
        dismissTask?.cancel(); dismissTask = nil
        meterTimer?.invalidate(); meterTimer = nil
        speech.cancel()
        overlay.hide()
        hotKey.setEscapeEnabled(false)
        phase = .idle
    }

    private func endPerformanceActivity() {
        if let performanceActivity { ProcessInfo.processInfo.endActivity(performanceActivity) }
        performanceActivity = nil
    }

    @objc private func setUp() {
        if !HotKey.hasPermission {
            HotKey.requestPermission()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        if !shortcutReady { installShortcut() }
        if SpeechCapture.hasPermissions { showNotice(answers.unavailableMessage ?? "Psst is ready. Hold ⌥ Space to ask a question.") }
        else {
            requestPermissions()
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            } else if SFSpeechRecognizer.authorizationStatus() == .denied {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
            }
        }
    }
    @objc private func retryShortcut() { dismiss(); installShortcut() }
    @objc private func preview() {
        overlay.chooseScreen()
        showNotice("A light-year is the distance light travels in one year: about 9.46 trillion kilometres.", mode: .answer)
    }
    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: "didConfigureLogin")
        } catch { showNotice("Couldn’t change Launch at Login. Check System Settings → General → Login Items.") }
    }
    @objc private func suspend() { dismiss(); hotKey.uninstall(); shortcutReady = false }
    @objc private func resume() { if HotKey.hasPermission { installShortcut() } }
    @objc private func audioChanged() {
        if phase == .recording { showNotice("The microphone changed. Hold Option–Space to try again.") }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { permissionWatch?.invalidate(); dismiss(); hotKey.uninstall() }
}

import Speech
