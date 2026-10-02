import AppKit
import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    enum Mode { case recording, transcribing, thinking, streaming, answer, notice }
    @Published var mode: Mode = .recording
    @Published var text = ""
    @Published var formattedText = AttributedString("")
    @Published var transcript = ""
    @Published var transcriptHeight: CGFloat = 18
    @Published var responseHeight: CGFloat = 24
    @Published var level: Float = 0
    @Published var stageStarted = Date()
    var dismiss: (() -> Void)?
    var isWorking: Bool { mode == .transcribing || mode == .thinking || mode == .streaming }
    var isCompact: Bool { mode == .recording && transcript.isEmpty }
}

private struct OverlayContent: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        Group {
            if model.isCompact {
                orb.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.mode == .notice {
                HStack(alignment: .top, spacing: 12) {
                    answerText
                    dismissButton
                }.padding(20)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        if !model.transcript.isEmpty {
                            ScrollView {
                                Text("“" + model.transcript + "”")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .scrollIndicators(.never)
                            .frame(height: model.transcriptHeight)
                            .accessibilityLabel("You said: " + model.transcript)
                        } else { Spacer(minLength: 0) }
                        orb.frame(width: 48, height: 48)
                    }
                    if model.mode != .recording {
                        Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
                        HStack(alignment: .top, spacing: 12) {
                            if model.text.isEmpty {
                                WorkingStatus(mode: model.mode, started: model.stageStarted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                answerText
                            }
                            dismissButton
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var orb: some View {
        VoiceOrb(level: Double(model.level), thinking: model.isWorking, resting: model.mode == .answer)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.mode == .recording ? "Listening" : model.isWorking ? "Thinking" : "Answer complete")
    }

    private var answerText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.formattedText)
                    .font(.system(size: 15, weight: .medium))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if model.mode == .streaming {
                    ProgressView().controlSize(.mini).scaleEffect(0.75)
                        .frame(width: 12, height: 12)
                        .accessibilityLabel("Answer still arriving")
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
        .frame(height: model.responseHeight, alignment: .top)
        // Keep the key fact visible; following the streaming tail left a stale
        // scroll offset when the spinner disappeared and the panel shrank.
        .defaultScrollAnchor(.top)
    }

    private var dismissButton: some View {
        Button { model.dismiss?() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dismiss (Esc)")
        .accessibilityLabel("Dismiss answer")
    }
}

private struct WorkingStatus: View {
    let mode: OverlayModel.Mode
    let started: Date
    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(mode == .transcribing ? "Finishing transcript…" : context.date.timeIntervalSince(started) >= 6 ? "Still thinking…" : "Thinking…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 22)
        }
    }
}

/// Flowing colour lobes inside a gently deforming glass membrane.
private struct VoiceOrb: View {
    let level: Double
    let thinking: Bool
    var resting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let speed = resting ? 0.35 : thinking ? 1.8 : 0.8
            let phase = time * speed
            let energy = reduceMotion ? 0 : resting ? 0.1 : thinking ? 0.5 : level
            let membrane = FluidMembrane(phase: phase, energy: energy)
            ZStack {
                membrane.fill(.black.opacity(0.22))
                ZStack {
                    Color.indigo.opacity(0.65)
                    ForEach(0..<4) { index in
                        let angle = phase + Double(index) * .pi / 2
                        Ellipse()
                            .fill([Color.cyan, .pink, .purple, .blue][index])
                            .frame(width: 26 + energy * 10, height: 18 + energy * 9)
                            .rotationEffect(.radians(angle * 1.3))
                            .offset(x: cos(angle) * (9 + energy * 3), y: sin(angle * 1.17) * 10)
                            .blur(radius: 5)
                            .blendMode(.screen)
                    }
                }
                .clipShape(membrane)
                membrane.fill(RadialGradient(colors: [.white.opacity(0.48), .clear], center: .init(x: 0.25, y: 0.16), startRadius: 0, endRadius: 28))
                membrane.stroke(LinearGradient(colors: [.white.opacity(0.75), .cyan.opacity(0.2), .pink.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
            }
            .frame(width: 42, height: 42)
            .scaleEffect(reduceMotion ? 1 : 0.94 + energy * 0.09 + sin(phase * 2) * 0.02)
            .shadow(color: .cyan.opacity(0.12 + energy * 0.2), radius: 3 + energy * 2)
            .animation(.easeOut(duration: 0.16), value: level)
        }
    }
}

private struct FluidMembrane: Shape {
    var phase: Double
    var energy: Double
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, energy) }
        set { phase = newValue.first; energy = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) * 0.46
        for step in 0...96 {
            let angle = Double(step) / 96 * .pi * 2
            let ripple = sin(angle * 3 + phase) * 0.035 + sin(angle * 5 - phase * 1.4) * 0.018
            let r = radius * (1 + ripple * (0.3 + energy))
            let point = CGPoint(x: rect.midX + cos(angle) * r, y: rect.midY + sin(angle) * r)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

private final class GlancePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class Overlay {
    let model = OverlayModel()
    private let panel: GlancePanel
    private let glass = NSGlassEffectView()
    private var screen: NSScreen?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    var isVisible: Bool { panel.isVisible }

    init() {
        panel = GlancePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        glass.style = .regular
        glass.cornerRadius = 22
        glass.contentView = NSHostingView(rootView: OverlayContent(model: model))
        panel.contentView = glass
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    func chooseScreen() {
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    func show(_ mode: OverlayModel.Mode, text: String = "") {
        if screen == nil { chooseScreen() }
        if model.mode != mode { model.stageStarted = Date() }
        model.mode = mode
        model.text = text
        layout()
        reposition()
        panel.orderFrontRegardless()
        installClickMonitors()
    }

    func updateTranscript(_ text: String) {
        guard text != model.transcript else { return }
        model.transcript = text
        if panel.isVisible { layout() }
    }

    func finishAnswer() {
        model.mode = .answer
        layout()
    }

    private func layout() {
        let compact = model.isCompact
        panel.ignoresMouseEvents = compact
        glass.cornerRadius = compact ? 26 : 24
        let width: CGFloat = compact ? 52 : 360
        func textHeight(_ text: String, width: CGFloat, size: CGFloat, weight: NSFont.Weight, spacing: CGFloat) -> CGFloat {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            let rect = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .paragraphStyle: paragraph])
            return ceil(rect.height) + 2
        }
        // Use the same widths and line spacing as SwiftUI, and give each scroll
        // view its own height so it cannot absorb space from the answer/header.
        model.transcriptHeight = min(86, max(18, textHeight("“" + model.transcript + "”", width: 268, size: 13, weight: .regular, spacing: 3)))
        let questionHeight = max(48, model.transcriptHeight)
        let answerWidth: CGFloat = model.mode == .notice ? 290 : 298
        let formatted = AnswerFormatting.render(model.text)
        model.formattedText = AttributedString(formatted)
        let measured = formatted.boundingRect(with: NSSize(width: answerWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        model.responseHeight = min(232, max(24, ceil(measured) + 2 + (model.mode == .streaming ? 18 : 0)))
        let height: CGFloat
        if compact { height = 52 }
        else if model.mode == .notice { height = model.responseHeight + 40 }
        else if model.mode == .recording { height = questionHeight + 32 }
        else { height = questionHeight + 56.5 + (model.text.isEmpty ? 22 : model.responseHeight) }
        let size = NSSize(width: width, height: height)
        if panel.frame.size != size {
            panel.setContentSize(size)
            reposition()
        }
    }

    private func reposition() {
        let display = NSScreen.screens.first { $0 == screen } ?? NSScreen.main ?? NSScreen.screens.first
        guard let display else { return }
        let visible = display.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20, y: visible.maxY - panel.frame.height - 16))
    }

    private func installClickMonitors() {
        guard globalClickMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfOutside() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissIfOutside() }
            return event // The underlying app still receives the click.
        }
    }

    private func dismissIfOutside() {
        guard panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        if let dismiss = model.dismiss { dismiss() } else { hide() }
    }

    func hide() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil; localClickMonitor = nil
        panel.orderOut(nil); model.mode = .notice; model.text = ""; model.transcript = ""; model.level = 0 }
}
