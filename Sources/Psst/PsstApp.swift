import AppKit

@main
@MainActor
struct PsstApp {
    static func main() {
        let app = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--pipeline-benchmark"), CommandLine.arguments.count > index + 2 {
            app.setActivationPolicy(.accessory)
            let report = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let fixtures = CommandLine.arguments.dropFirst(index + 2).map { URL(fileURLWithPath: $0) }
            Task(priority: .userInitiated) { await PerformanceBenchmarks.pipeline(fixtures: fixtures, report: report); app.terminate(nil) }
            app.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--benchmark"), CommandLine.arguments.count > index + 1 {
            app.setActivationPolicy(.accessory)
            let report = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task(priority: .userInitiated) { await PerformanceBenchmarks.run(report: report); app.terminate(nil) }
            app.run()
            return
        }
        if let preview = CommandLine.arguments.first(where: { ["--orb-preview", "--thinking-preview", "--answer-preview", "--format-preview", "--long-answer-preview", "--streaming-preview"].contains($0) }) {
            app.setActivationPolicy(.accessory)
            Task {
                let overlay = Overlay()
                overlay.chooseScreen()
                overlay.model.level = 0.25
                if preview != "--orb-preview" { overlay.updateTranscript("Why does the sky look blue during the day?") }
                if preview == "--thinking-preview" { overlay.show(.thinking) }
                else if preview == "--streaming-preview" { overlay.show(.streaming, text: "Air molecules scatter blue sunlight more strongly") }
                else if preview == "--answer-preview" || preview == "--long-answer-preview" || preview == "--format-preview" {
                    overlay.updateTranscript("What is Sony?")
                    let answer = preview == "--format-preview" ? #"**Mass–energy equivalence:** \( E = mc^2 \)."# + "\n" + #"- \(E\): energy in joules (J)"# + "\n" + #"- \(m\): mass in kilograms (kg)"# + "\n" + #"- \(c\): speed of light (\(3 \times 10^8\) m/s)"# : "Sony is a Japanese electronics company known for producing cameras, televisions, and audio equipment."
                    overlay.show(.streaming, text: preview == "--long-answer-preview" ? Array(repeating: answer, count: 8).joined(separator: "\n\n") : answer)
                    try? await Task.sleep(for: .seconds(1))
                    overlay.finishAnswer()
                }
                else { overlay.show(.recording) }
                try? await Task.sleep(for: .seconds(30))
                overlay.hide()
                app.terminate(nil)
            }
            app.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--speech-test"), CommandLine.arguments.count > index + 2 {
            app.setActivationPolicy(.accessory)
            let fixture = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let report = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { await Diagnostics.runSpeechFixture(fixture, report: report); app.terminate(nil) }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            app.setActivationPolicy(.accessory)
            Task { await Diagnostics.run(); app.terminate(nil) }
            app.run()
            return
        }
        let delegate = AppController()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
