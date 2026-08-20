import CoreGraphics
import Foundation

enum PetPose: String, Sendable, CaseIterable {
    case idle = "cat-idle-follow-v2"
    case pressLeft = "press-left"
    case pressRight = "press-right"
    case scroll = "scroll-unroll"
    case jumpStart = "jump-start"
    case jumpIng = "jump-ing"
    case stretchStart = "stretch-start"
    case stretchEnd = "stretch-end"
    case stretchDefault = "stretch-pose-default"
    /// Generated nap pose (see `Tools/gen-sleep-pose/gen-sleep-pose.py`): the idle rig curled into
    /// a loaf — body squashed, head settled low, legs tucked, tail wrapped around the front.
    case sleepCurl = "sleep-curl"
}

enum SpeechBubbleKind: Sendable {
    case notice
    case reminder
    case timer
    case fixed
}

/// Floating glyph shown above the cat for an agent reaction (see `AgentReaction`). The cat body
/// also plays a matching one-shot motion, but the badge is what makes each moment visually distinct.
/// The glyphs themselves are stroke-drawn by the pet view (see `PetView.drawReactionBadge`) so they
/// match the cat's line-art style instead of dropping a system emoji into the scene.
enum ReactionBadge: Equatable, Sendable {
    case none
    case ask
    case plan
    case error
}

/// Body flourish that accompanies an agent reaction so each moment reads on the cat itself, not
/// just the floating badge: an inquisitive ear flick for a question, ears pinned back for an
/// error, a raised tail held through a plan approval, and a quick both-ear perk for the generic
/// "needs attention" nudge that previously played no body animation at all.
enum ReactionFlourish: Equatable, Sendable {
    case none
    case askEars
    case errorEars
    case planTail
    case attentionEars
}

struct TrackingOffsets: Equatable, Sendable {
    var pupils = CGPoint.zero
    var eyes = CGPoint.zero
    var face = CGPoint.zero
    var body = CGPoint.zero
}

struct RenderState: Sendable {
    var pose: PetPose = .idle
    var time: TimeInterval = 0
    var tracking = TrackingOffsets()
    var heat: CGFloat = 0
    var stretchingHeat: CGFloat = 0
    var purring = false
    var sleeping = false
    var hunting = false
    var huntingReturn = false
    var thinking = false
    var openaiCount: Int = 0
    var anthropicCount: Int = 0
    var speech: String?
    var speechKind: SpeechBubbleKind = .notice
    var pomodoroMode: PomodoroMode = .focus
    var pomodoroRunning = false
    var showName = true
    var catName = "Clawdi"
    var scrollProgress: CGFloat = 0
    var stretchProgress: CGFloat = 0
    var pattern = PatternModel.default
    var jumpY: CGFloat = 0
    var shakeX: CGFloat = 0
    var tiltAngle: CGFloat = 0
    var popScale: CGFloat = 0
    var reactionBadge: ReactionBadge = .none
    var reactionBadgePhase: CGFloat = 0
    var bubbleJumpY: CGFloat = 0
    var huntingEnter: CGFloat = 0
    var huntingReturnProgress: CGFloat = 0
    var stretchPoseProgress: CGFloat = 0
    var mochiStretchActive: Bool = false
    var stretchT: CGFloat = 0
    var stretchSegmentDX: [CGFloat] = []
    var purrFaceOffset: CGPoint = .zero
    /// 0..1 intensity of the thinking-time kneading (see `KneadMotion` and
    /// `PixelCompositor.kneadTransform`): while an agent works, the cat rhythmically presses
    /// its front paws like kneading a blanket. The envelope eases the paws in and out of the
    /// motion so it never pops mid-press. Zero whenever the cat is not kneading.
    var kneadPhase: CGFloat = 0
    /// 0..1 over the whole completion-jump sequence; drives the sparkle bursts at the hop apexes.
    var jumpPhase: CGFloat = 0
    var flourish: ReactionFlourish = .none
    /// 0..1 over the reaction badge duration while `flourish` is active.
    var flourishPhase: CGFloat = 0
    /// Live flying diff stats (FPS damage-number style) for successful agent edits; the controller
    /// spawns one per edited file and prunes each once its flight expires.
    var editPops: [EditPop] = []
    /// The cat's eyes are drawn shut both while purring (content squint) and while sleeping; every
    /// renderer visibility/cache decision about the closed-eye rig keys off this, while purr-only
    /// motion (face bob, tail flick, whisker twitch) stays keyed to `purring`.
    var eyesClosed: Bool { purring || sleeping }
}

/// One flying `project>file +a -r` stat launched off the pet's head when an agent lands an edit —
/// the FPS damage-number treatment: it pops in, flies a ballistic arc (up, over, and back down to
/// its launch height) with a lateral drift, then fades out in place over `fadeDuration`. Motion is
/// derived per frame from `spawnedAt` against `RenderState.time`, so the value itself never
/// mutates after spawn.
struct EditPop: Equatable, Sendable {
    /// Seconds airborne (launch to landing) unless a demo event overrides it per volley.
    static let defaultFlight: TimeInterval = 1.1
    /// Landed fade-out appended after the flight; disappearance is implicit, never configured.
    static let fadeDuration: TimeInterval = 0.75

    var label: String
    var added: Int
    var removed: Int
    var spawnedAt: TimeInterval
    /// Seconds airborne for this pop; total lifetime is `flightTime + fadeDuration`.
    var flightTime: TimeInterval
    /// Launch angle in radians, π/4…3π/4 where π/2 is straight up; the horizontal range follows
    /// ballistics (4·apex/tan(angle)), capped at the window edges.
    var angle: CGFloat
    /// Apex height above the launch point as a fraction of the pet square's height (0.5…0.75 by
    /// default; demo tuning may push it to 1, still covered by the window's reserved sky room).
    var rise: CGFloat

    /// `project>file` label for an edited path: the cwd's last component plus the file name
    /// (`/work/pi` + `/work/pi/a/b.ts` → `pi>b.ts`). No cwd → just the file name. Long file
    /// names keep their tail (the extension is the informative part).
    static func label(path: String, cwd: String?) -> String {
        var file = (path as NSString).lastPathComponent
        if file.count > 24 { file = "…" + file.suffix(23) }
        guard let cwd, !cwd.isEmpty else { return file }
        let project = (cwd as NSString).lastPathComponent
        return project.isEmpty ? file : "\(project)>\(file)"
    }
}

enum ScrollReaction {
    static let releaseDuration: TimeInterval = 0.520
    static let unrollDuration: TimeInterval = 0.220
    static let paperMinHeight: CGFloat = 17
    static let paperMaxHeight: CGFloat = 32.5

    static func progress(startedAt: TimeInterval?, now: TimeInterval) -> CGFloat {
        guard let startedAt else { return 0 }
        return min(1, max(0, CGFloat((now - startedAt) / unrollDuration)))
    }

    static func paperHeight(progress: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress))
        let eased = 1 - pow(1 - t, 3)
        return paperMinHeight + (paperMaxHeight - paperMinHeight) * eased
    }
}

struct CursorTracking {
    static let maxRawDist: CGFloat = 400
    private var offsets = TrackingOffsets()

    mutating func step(mouse: CGPoint, windowCenter: CGPoint) -> TrackingOffsets {
        let dx = mouse.x - windowCenter.x
        let dy = mouse.y - windowCenter.y
        // Unit direction toward the cursor, scaled by min(dist,400)/400 so the deflection grows
        // from 0 at the cat to its layer maxOffset at >=400px away. (A dx/min(400,dist) form
        // would pin every layer to full deflection for any cursor within 400px, shoving the
        // pupils out past the sclera.)
        let dist = hypot(dx, dy)
        let clamped = dist > 0 ? min(dist, Self.maxRawDist) / Self.maxRawDist : 0
        let nx = dist > 0 ? (dx / dist) * clamped : 0
        let ny = dist > 0 ? (-dy / dist) * clamped : 0
        offsets.pupils = ease(current: offsets.pupils, target: CGPoint(x: nx * 1.6, y: ny * 1.6), amount: 0.42)
        offsets.eyes = ease(current: offsets.eyes, target: CGPoint(x: nx * 0.8, y: ny * 0.8), amount: 0.30)
        offsets.face = ease(current: offsets.face, target: CGPoint(x: nx * 2.2, y: ny * 2.2), amount: 0.20)
        offsets.body = ease(current: offsets.body, target: CGPoint(x: nx * 0.7, y: ny * 0.7), amount: 0.09)
        // Quantize the OUTPUT only, to whole device pixels. The eased
        // state stays continuous; quantizing it in place would feed rounded values back into the
        // ease and stall convergence below target.
        return TrackingOffsets(
            pupils: quantize(offsets.pupils),
            eyes: quantize(offsets.eyes),
            face: quantize(offsets.face),
            body: quantize(offsets.body)
        )
    }

    private func ease(current: CGPoint, target: CGPoint, amount: CGFloat) -> CGPoint {
        CGPoint(x: current.x + (target.x - current.x) * amount, y: current.y + (target.y - current.y) * amount)
    }

    static func quantize(_ value: CGFloat) -> CGFloat { (value * 8).rounded() / 8 }
    private func quantize(_ point: CGPoint) -> CGPoint { CGPoint(x: Self.quantize(point.x), y: Self.quantize(point.y)) }
}

struct HeatModel: Sendable {
    static let keyWindow: TimeInterval = 1.5
    static let kpsMin: CGFloat = 4
    static let kpsMax: CGFloat = 14
    static let heatCurve: CGFloat = 1.5
    static let heatEase: CGFloat = 0.10
    static let stretchingEase: CGFloat = 0.12
    private var keyTimes: [TimeInterval] = []
    private(set) var heat: CGFloat = 0
    /// Green "resting" tint intensity (0…1), eased toward `stretchingTarget`.
    private(set) var stretchingHeat: CGFloat = 0
    /// Set to 1 while a stretch animation is playing, 0 otherwise.
    var stretchingTarget: CGFloat = 0

    mutating func recordKey(at time: TimeInterval) {
        keyTimes.append(time)
        trim(now: time)
    }

    mutating func step(now: TimeInterval) -> CGFloat {
        trim(now: now)
        let kps = CGFloat(keyTimes.count) / CGFloat(Self.keyWindow)
        let normalized = min(1, max(0, (kps - Self.kpsMin) / (Self.kpsMax - Self.kpsMin)))
        let target = pow(normalized, Self.heatCurve)
        heat += (target - heat) * Self.heatEase
        if heat < 0.005, target == 0 { heat = 0 }
        stretchingHeat += (stretchingTarget - stretchingHeat) * Self.stretchingEase
        if stretchingHeat < 0.005, stretchingTarget == 0 { stretchingHeat = 0 }
        return heat
    }

    private mutating func trim(now: TimeInterval) { keyTimes.removeAll { now - $0 > Self.keyWindow } }
}

struct ShakeDetector: Sendable {
    static let speedThreshold: CGFloat = 11.2
    static let triggerEnergy: CGFloat = 2.34
    static let decay: CGFloat = 0.82
    private var last: CGPoint?
    private var lastTime: TimeInterval?
    private var prevVelocity: CGPoint?
    private var energy: CGFloat = 0

    mutating func step(mouse: CGPoint, now: TimeInterval) -> Bool {
        defer {
            last = mouse
            lastTime = now
        }
        guard let last, let lastTime else { return false }
        // dt-normalized velocity per 16ms, frame-rate independent.
        let dt = max(1, (now - lastTime) * 1000)
        let v = CGPoint(x: (mouse.x - last.x) / dt * 16, y: (mouse.y - last.y) / dt * 16)
        let speed = hypot(v.x, v.y)
        energy *= Self.decay
        if speed > Self.speedThreshold {
            energy += min(0.22, (speed - Self.speedThreshold) / 42)
        }
        if let prevVelocity {
            let prevSpeed = hypot(prevVelocity.x, prevVelocity.y)
            if speed > 0, prevSpeed > 0 {
                let dot = v.x * prevVelocity.x + v.y * prevVelocity.y
                if dot / (speed * prevSpeed) < -0.28, speed > Self.speedThreshold * 1.28 {
                    energy += min(0.42, (speed - Self.speedThreshold) / 34 + 0.12)
                }
            }
            let accel = speed - prevSpeed
            if accel > 14 { energy += min(0.18, accel / 52) }
            if speed > Self.speedThreshold * 3.2, accel > 18 { energy += 0.28 }
        }
        prevVelocity = v
        if energy >= Self.triggerEnergy {
            energy = Self.triggerEnergy * 0.35
            return true
        }
        return false
    }
}

/// Whether the cat is purring while the cursor pets its head. The purr machine is event
/// (mousemove) driven: purring latches TRUE instantly on the first on-head sample (NO start
/// dwell). It STOPS
/// when the cursor sits idle on the head (no movement) longer than `startDelay` (the
/// idle timeout), OR once it has been off the head longer than `leaveGrace`. The off-head grace
/// anchor is RE-ARMED by every off-head movement, so continuous off-head motion keeps the purr
/// alive until motion pauses; a stationary off-head cursor still expires the grace window.
struct PurrState: Sendable {
    static let startDelay: TimeInterval = 0.420
    static let leaveGrace: TimeInterval = 0.260

    private(set) var purring = false
    private var wasOnHead = false
    private var lastOnHeadMove: TimeInterval?
    private var offHeadAnchor: TimeInterval?

    mutating func step(onHead: Bool, moved: Bool, now: TimeInterval) -> Bool {
        defer { wasOnHead = onHead }
        if onHead {
            offHeadAnchor = nil
            if !wasOnHead || moved {
                purring = true
                lastOnHeadMove = now
            } else if let last = lastOnHeadMove, now - last > Self.startDelay {
                purring = false
            }
        } else {
            lastOnHeadMove = nil
            if offHeadAnchor == nil || moved { offHeadAnchor = now }
            if let anchor = offHeadAnchor, now - anchor > Self.leaveGrace { purring = false }
        }
        return purring
    }
}

/// Whether the cat has dozed off. Pure idle-clock logic: the cat falls asleep once no user input
/// has arrived for `idleTimeout` while nothing else is going on (`blocked` covers reactions,
/// thinking, purring, non-idle poses, …). Waking distinguishes *why* sleep ended so the controller
/// can play the wake-up stretch only for real user input — an agent reaction interrupting a nap
/// (`interrupted`) wakes the cat quietly, and once the reaction passes the stale `lastInputAt`
/// simply puts it back to sleep.
struct SleepModel: Sendable {
    static let idleTimeout: TimeInterval = 240

    enum Transition: Equatable {
        case none
        case fellAsleep
        case wokeByInput
        case interrupted
    }

    private(set) var sleeping = false

    mutating func step(now: TimeInterval, lastInputAt: TimeInterval, blocked: Bool) -> Transition {
        let target = !blocked && now - lastInputAt >= Self.idleTimeout
        guard target != sleeping else { return .none }
        sleeping = target
        if target { return .fellAsleep }
        // The wake *reason* keys off input freshness, not `blocked`: a key press flips the pose to
        // a paw-tap before the wake tick runs, and that must still read as woke-by-input.
        return now - lastInputAt < Self.idleTimeout ? .wokeByInput : .interrupted
    }
}

/// Curious head-tilt at a cursor that lingers near the cat. The cursor must sit still inside the
/// nearby band for `lingerDelay`; the cat then cocks its head toward that side, loses interest
/// after `holdDuration`, and won't re-tilt until `cooldown` has passed. The tilt value is eased so
/// the head cocks and settles smoothly; the controller feeds it into `RenderState.tiltAngle`
/// whenever no one-shot reaction owns that field.
struct CuriosityModel: Sendable {
    static let lingerDelay: TimeInterval = 2.0
    static let holdDuration: TimeInterval = 3.5
    static let cooldown: TimeInterval = 9.0
    static let maxTilt: CGFloat = 0.10
    static let ease: CGFloat = 0.10

    private var lingerStart: TimeInterval?
    private var cooldownUntil: TimeInterval = 0
    private(set) var tilt: CGFloat = 0

    mutating func step(now: TimeInterval, nearby: Bool, moved: Bool, side: CGFloat, engaged: Bool) -> CGFloat {
        var target: CGFloat = 0
        if engaged || !nearby {
            endLinger(now: now)
        } else {
            if moved || lingerStart == nil { lingerStart = now }
            if let start = lingerStart, now >= cooldownUntil {
                let lingered = now - start
                if lingered >= Self.lingerDelay + Self.holdDuration {
                    // Lost interest: head eases back and this linger can't re-trigger.
                    endLinger(now: now)
                } else if lingered >= Self.lingerDelay {
                    target = (side < 0 ? -1 : 1) * Self.maxTilt
                }
            }
        }
        tilt += (target - tilt) * Self.ease
        if abs(tilt - target) < 0.001 { tilt = target }
        return tilt
    }

    /// A finished or aborted tilt arms the cooldown so the cat doesn't nod at every pause.
    private mutating func endLinger(now: TimeInterval) {
        if lingerStart != nil, abs(tilt) > 0.01 {
            cooldownUntil = max(cooldownUntil, now + Self.cooldown)
        }
        lingerStart = nil
    }
}

/// Intensity envelope for the thinking-time kneading: while an agent works and the user isn't
/// typing, the cat rhythmically presses its front paws like kneading a blanket (the paw motion
/// itself lives in `PixelCompositor.kneadTransform`, driven by `RenderState.time`). Pure
/// timing logic so it is unit-testable; the controller gates eligibility (thinking, idle pose,
/// the user not having typed within `typingGrace` — real keystrokes own the press poses).
struct KneadMotion: Sendable {
    static let typingGrace: TimeInterval = 2.5
    static let rampIn: TimeInterval = 0.6
    static let rampOut: TimeInterval = 0.45

    private var intensity: CGFloat = 0
    private var lastStepAt: TimeInterval?

    /// Advances the envelope toward 1 while eligible and back to 0 while not, at the ramp rates
    /// above. The compositor scales every knead amplitude by the result, so paws ease into the
    /// rhythm and settle back to rest instead of popping.
    mutating func step(now: TimeInterval, eligible: Bool) -> CGFloat {
        let dt = lastStepAt.map { max(0, now - $0) } ?? 0
        lastStepAt = now
        if eligible {
            intensity = min(1, intensity + CGFloat(dt / Self.rampIn))
        } else if intensity > 0 {
            intensity = max(0, intensity - CGFloat(dt / Self.rampOut))
        }
        return intensity
    }
}
