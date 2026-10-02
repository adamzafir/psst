import Foundation

@main
struct ShortcutRoutingTests {
    static func main() {
        testHoldConsumesDownRepeatsAndUp()
        testModifierFirstReleaseDoesNotLeakRepeatsOrDoubleFinish()
        testUnrelatedTypingPassesThrough()
        testEscapeDuringHoldCancelsOnlyOnceAndKeepsSpaceConsumed()
        testEscapeDismissalConsumesUpEvenAfterOverlayHides()
        testAutoRepeatCannotStartRecordingAfterInitialPressWasMissed()
        print("PASS: 6 shortcut regression tests")
    }
    static func testHoldConsumesDownRepeatsAndUp() {
        var routing = ShortcutRouting()
        precondition(routing.handle(.spaceDown(optionOnly: true, isRepeat: false)) == .init(consume: true, action: .press))
        for _ in 0..<50 {
            precondition(routing.handle(.spaceDown(optionOnly: true, isRepeat: true)) == .init(consume: true))
            precondition(routing.held)
        }
        precondition(routing.handle(.spaceUp) == .init(consume: true, action: .release))
        precondition(!(routing.held))
    }
    static func testModifierFirstReleaseDoesNotLeakRepeatsOrDoubleFinish() {
        var routing = ShortcutRouting()
        _ = routing.handle(.spaceDown(optionOnly: true, isRepeat: false))
        precondition(routing.handle(.optionReleased) == .init(action: .release))
        precondition(routing.handle(.spaceDown(optionOnly: false, isRepeat: true)) == .init(consume: true))
        precondition(routing.handle(.spaceUp) == .init(consume: true))
        precondition(routing.handle(.spaceUp) == .init())
    }
    static func testUnrelatedTypingPassesThrough() {
        var routing = ShortcutRouting()
        precondition(routing.handle(.spaceDown(optionOnly: false, isRepeat: false)) == .init())
        precondition(routing.handle(.spaceUp) == .init())
        precondition(routing.handle(.other) == .init())
        precondition(routing.handle(.escapeDown) == .init())
        precondition(routing.handle(.escapeUp) == .init())
    }
    static func testEscapeDuringHoldCancelsOnlyOnceAndKeepsSpaceConsumed() {
        var routing = ShortcutRouting()
        _ = routing.handle(.spaceDown(optionOnly: true, isRepeat: false))
        precondition(routing.handle(.escapeDown) == .init(consume: true, action: .cancel))
        precondition(routing.handle(.escapeDown) == .init(consume: true))
        precondition(routing.handle(.escapeUp) == .init(consume: true))
        precondition(routing.handle(.spaceDown(optionOnly: true, isRepeat: true)) == .init(consume: true))
        precondition(routing.handle(.spaceUp) == .init(consume: true))
        precondition(routing.handle(.spaceDown(optionOnly: true, isRepeat: false)) == .init(consume: true, action: .press))
    }
    static func testEscapeDismissalConsumesUpEvenAfterOverlayHides() {
        var routing = ShortcutRouting()
        routing.escapeEnabled = true
        precondition(routing.handle(.escapeDown) == .init(consume: true, action: .cancel))
        routing.escapeEnabled = false
        precondition(routing.handle(.escapeUp) == .init(consume: true))
        precondition(routing.handle(.escapeDown) == .init())
    }
    static func testAutoRepeatCannotStartRecordingAfterInitialPressWasMissed() {
        var routing = ShortcutRouting()
        precondition(routing.handle(.spaceDown(optionOnly: true, isRepeat: true)) == .init())
        precondition(!(routing.held))
    }
}
