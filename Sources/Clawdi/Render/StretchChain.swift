import CoreGraphics
import Foundation

struct StretchSegment: Equatable, Sendable {
    var x: CGFloat = 0
    var velocity: CGFloat = 0
}

struct StretchChain: Sendable {
    static let segmentCount = 6
    static let spring: CGFloat = 0.10
    static let coupling: CGFloat = 0.28
    static let damping: CGFloat = 0.84
    static let impulse: CGFloat = 0.002
    static let maxDX: CGFloat = 2.5
    static let depthTaper: CGFloat = 0.85
    static let releaseEase: CGFloat = 0.32
    static let maxUpOffset: CGFloat = 140
    static let dragStartThreshold: CGFloat = 4

    private(set) var segments = Array(repeating: StretchSegment(), count: segmentCount)
    private(set) var upOffset: CGFloat = 0
    private(set) var stretchT: CGFloat = 0
    private(set) var dragging = false

    var activity: CGFloat {
        var segmentActivity: CGFloat = 0
        for (i, segment) in segments.enumerated() {
            let localMax = Self.maxDX * pow(Self.depthTaper, CGFloat(i))
            segmentActivity = max(segmentActivity, abs(segment.x) / localMax, abs(segment.velocity) / localMax)
        }
        return min(1, max(stretchT, segmentActivity, upOffset / Self.maxUpOffset))
    }

    mutating func beginDrag() { dragging = true }
    mutating func drag(deltaY: CGFloat, deltaX: CGFloat) {
        guard dragging else { return }
        let positiveDeltaY = max(0, deltaY)
        upOffset = min(Self.maxUpOffset, positiveDeltaY)
        stretchT = max(stretchT, min(1, positiveDeltaY / Self.maxUpOffset))
        segments[0].velocity -= deltaX * Self.impulse
    }
    mutating func endDrag() { dragging = false }

    func cumulativeDX(upTo i: Int) -> CGFloat {
        guard !segments.isEmpty else { return 0 }
        let end = min(max(0, i), segments.count - 1)
        var dx: CGFloat = 0
        for index in 0...end { dx += segments[index].x }
        return dx
    }

    mutating func step() {
        if !dragging {
            upOffset += (0 - upOffset) * Self.releaseEase
            if upOffset < 0.01 { upOffset = 0 }
            stretchT += (0 - stretchT) * Self.releaseEase
            if stretchT < 0.01 { stretchT = 0 }
        }

        var next = segments
        var maxMotion: CGFloat = 0
        for i in segments.indices {
            let parentX = i > 0 ? segments[i - 1].x : 0
            var v = segments[i].velocity
            v += (parentX - segments[i].x) * Self.coupling
            v += (0 - segments[i].x) * Self.spring
            v *= Self.damping
            var x = segments[i].x + v
            let localMax = Self.maxDX * pow(Self.depthTaper, CGFloat(i))
            x = min(localMax, max(-localMax, x))
            next[i] = StretchSegment(x: x, velocity: v)
            maxMotion = max(maxMotion, abs(x), abs(v))
        }
        segments = next

        if !dragging, stretchT == 0, maxMotion < 0.15 {
            upOffset = 0
            segments = Array(repeating: StretchSegment(), count: Self.segmentCount)
        }
    }
}
