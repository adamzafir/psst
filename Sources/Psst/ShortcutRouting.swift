import Foundation

/// Pure key-edge state machine, shared by the event filter and regression tests.
struct ShortcutRouting {
    enum Input {
        case spaceDown(optionOnly: Bool, isRepeat: Bool)
        case spaceUp
        case optionReleased
        case escapeDown
        case escapeUp
        case other
    }
    enum Action: Equatable { case press, release, cancel }
    struct Decision: Equatable {
        var consume = false
        var action: Action? = nil
    }
    var escapeEnabled = false
    private(set) var held = false
    private var ownsSpace = false
    private var ownsEscape = false

    mutating func handle(_ input: Input) -> Decision {
        switch input {
        case .spaceDown(let optionOnly, let isRepeat):
            if ownsSpace { return Decision(consume: true) }
            guard optionOnly, !isRepeat else { return Decision() }
            ownsSpace = true
            held = true
            return Decision(consume: true, action: .press)
        case .spaceUp:
            guard ownsSpace else { return Decision() }
            ownsSpace = false
            let action: Action? = held ? .release : nil
            held = false
            return Decision(consume: true, action: action)
        case .optionReleased:
            guard held else { return Decision() }
            held = false
            // Continue swallowing Space repeats/up until it physically comes up.
            return Decision(action: .release)
        case .escapeDown:
            if ownsEscape { return Decision(consume: true) }
            guard escapeEnabled || held else { return Decision() }
            ownsEscape = true
            held = false
            return Decision(consume: true, action: .cancel)
        case .escapeUp:
            guard ownsEscape else { return Decision() }
            ownsEscape = false
            return Decision(consume: true)
        case .other:
            return Decision()
        }
    }
}
