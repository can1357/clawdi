import Foundation

enum PomodoroMode: String, Codable, Sendable { case focus, rest }
enum PomodoroEvent: Equatable, Sendable { case focusCompleted, restCompleted }

struct PomodoroState: Codable, Equatable, Sendable {
    var visible: Bool = false
    var running: Bool = false
    var mode: PomodoroMode = .focus
    var remainingSec: Int
    var focusMin: Int
    var restSec: Int

    init(
        visible: Bool = false, running: Bool = false, mode: PomodoroMode = .focus, remainingSec: Int? = nil,
        focusMin: Int = 25, restSec: Int = 300
    ) {
        self.visible = visible
        self.running = running
        self.mode = mode
        self.focusMin = min(180, max(1, focusMin))
        self.restSec = min(3600, max(30, restSec))
        self.remainingSec = remainingSec ?? (mode == .focus ? self.focusMin * 60 : self.restSec)
    }

    mutating func configure(focusMin newFocusMin: Int, restSec newRestSec: Int) {
        let clampedFocus = min(180, max(1, newFocusMin))
        let clampedRest = min(3600, max(30, newRestSec))
        let focusChanged = clampedFocus != focusMin
        let restChanged = clampedRest != restSec
        focusMin = clampedFocus
        restSec = clampedRest
        // A field edit reloads the countdown only when paused AND it matches the active mode,
        // so editing the rest length never clobbers a running (or off-mode) countdown.
        if !running {
            if focusChanged && mode == .focus { remainingSec = focusMin * 60 }
            if restChanged && mode == .rest { remainingSec = restSec }
        }
    }

    mutating func startOrResume() {
        visible = true
        if remainingSec <= 0 { remainingSec = mode == .focus ? focusMin * 60 : restSec }
        running = true
    }

    mutating func pause() { running = false }
    mutating func reset() {
        visible = false
        running = false
        mode = .focus
        remainingSec = focusMin * 60
    }

    mutating func tick() -> PomodoroEvent? {
        guard running else { return nil }
        remainingSec -= 1
        guard remainingSec <= 0 else { return nil }
        switch mode {
        case .focus:
            mode = .rest
            remainingSec = restSec
            return .focusCompleted
        case .rest:
            mode = .focus
            remainingSec = focusMin * 60
            return .restCompleted
        }
    }

    var timerText: String {
        let sec = max(0, remainingSec)
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }
}
