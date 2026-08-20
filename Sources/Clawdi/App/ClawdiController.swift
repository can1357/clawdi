import AppKit
import QuartzCore

@MainActor
final class ClawdiController: NSObject, PetViewDelegate {
    let paths: AppPaths
    let settingsStore: JSONFileStore<ClawdiSettings>
    let patternStore: JSONFileStore<PatternModel>
    let library: PoseLibrary
    let mappings: CellMappings
    let sound = SoundPlayer()
    let input = GlobalInputMonitor()
    let agentServer = AgentStateServer()
    let monitors = AgentLogMonitors()
    let shareOverlay = ShareOverlay()

    var shareCancellation: ShareRecorder.Cancellation?
    var sharePreviewTimer: Timer?
    var presets: PresetStore
    var panel: PetPanel!
    var petView: PetView!
    var displayLink: CADisplayLink?
    private var frameRateTier: FrameRateTier = .interactive
    var tracking = CursorTracking()
    var heat = HeatModel()
    var stretchChain = StretchChain()
    var settings: ClawdiSettings
    var pattern: PatternModel
    var pomodoro: PomodoroState
    var lastSecondTick = Date()
    var lastReminderCheck = Date.distantPast
    var hoverHead = false
    var purr = PurrState()
    var huntingUntil: TimeInterval = 0
    var huntingReturnUntil: TimeInterval = 0
    var stretchHeatUntil: TimeInterval = 0
    var poseReleaseAt: TimeInterval = 0
    var scrollStartedAt: TimeInterval?
    var nextPressLeft = true
    var speechUntil: TimeInterval = 0
    var transientSpeech: String?
    var transientSpeechKind: SpeechBubbleKind = .notice
    var stretchRestoreFrame: CGRect?
    var stretchTimer: Timer?
    var stretchInProgress = false
    var stretchPoseStartedAt: TimeInterval?
    var focusStartInProgress = false
    var focusStartTimer: Timer?
    var focusStartStep = 0
    var reminderWindow: NSWindow?
    var patternWindow: PatternEditorWindowController?
    var jumpStartedAt: TimeInterval?
    var reactionStartedAt: TimeInterval?
    var reactionAnimation: AgentReaction.Animation = .none
    var jumpActiveKeyframeIndex = -1
    var jumpTransitionStartedAt: TimeInterval = 0
    var jumpTransitionStartY: CGFloat = 0
    var jumpTransitionStartBubbleY: CGFloat = 0
    var lastMousePosition: CGPoint?
    private var lastInputAt: TimeInterval = CACurrentMediaTime()
    private var sleep = SleepModel()
    private var curiosity = CuriosityModel()
    private var knead = KneadMotion()
    private var pendingWakeStretch = false
    var antigravityThinkingTimer: Timer?
    private var didShutdown = false
    private struct JumpKeyframe {
        var time: TimeInterval
        var pose: PetPose
        var jumpPx: CGFloat
        var bubblePx: CGFloat
    }

    /// The lift renders the stretch pose at resting head scale, so the full morph would hang as an
    /// extreme noodle. Capping `stretchT` (consumed only by the render) keeps the head pinned while the
    /// body droops a natural, bounded amount, proportional to the pull; physics/activity/hit-testing
    /// still use the raw chain value.
    private static let liftElongationMax: CGFloat = 0.5
    private func liftMorphT(_ chainStretchT: CGFloat) -> CGFloat {
        clamp01(chainStretchT) * Self.liftElongationMax
    }

    private static let jumpTotalDuration: TimeInterval = 2.220
    private static let jumpTransitionDuration: TimeInterval = 0.260
    private static let jumpKeyframes = [
        JumpKeyframe(time: 0.000, pose: .jumpStart, jumpPx: 0, bubblePx: 0),
        JumpKeyframe(time: 0.140, pose: .jumpStart, jumpPx: 0, bubblePx: 0),
        JumpKeyframe(time: 0.300, pose: .jumpIng, jumpPx: -16, bubblePx: -18),
        JumpKeyframe(time: 0.500, pose: .jumpIng, jumpPx: -26, bubblePx: -26),
        JumpKeyframe(time: 0.660, pose: .jumpIng, jumpPx: -24, bubblePx: -24),
        JumpKeyframe(time: 0.860, pose: .jumpStart, jumpPx: -5, bubblePx: -8),
        JumpKeyframe(time: 1.040, pose: .jumpStart, jumpPx: 0, bubblePx: 0),
        JumpKeyframe(time: 1.240, pose: .jumpIng, jumpPx: -16, bubblePx: -18),
        JumpKeyframe(time: 1.440, pose: .jumpIng, jumpPx: -26, bubblePx: -26),
        JumpKeyframe(time: 1.600, pose: .jumpIng, jumpPx: -24, bubblePx: -24),
        JumpKeyframe(time: 1.800, pose: .jumpStart, jumpPx: -5, bubblePx: -8),
        JumpKeyframe(time: 1.980, pose: .jumpStart, jumpPx: 0, bubblePx: 0),
    ]

    init(paths: AppPaths, library: PoseLibrary, mappings: CellMappings) {
        self.paths = paths
        self.library = library
        self.mappings = mappings
        settingsStore = JSONFileStore<ClawdiSettings>(url: paths.settings)
        patternStore = JSONFileStore<PatternModel>(url: paths.pattern)
        settings = settingsStore.load(default: .default).sanitized()
        presets = PresetStore(customURL: paths.customPresets)
        pattern = patternStore.load(default: presets.defaultPattern).sanitized()
        if let match = presets.matchingPreset(for: pattern) {
            pattern.selectedPresetId = match.id
        }
        pomodoro = PomodoroState(
            focusMin: settings.pomodoroFocusMin, restSec: settings.pomodoroRestSec)
        super.init()
    }

    func launch() throws {
        guard AlwaysAllowLicenseGate().evaluate() == .ok else { return }
        createWindow()
        showFirstRunNamePromptIfNeeded()
        buildAppMenu()
        reconcileLaunchAtLogin()
        agentServer.onOutput = { [weak self] output in self?.handleAgentOutput(output) }
        agentServer.onSessionsExpired = { [weak self] in self?.handleAgentSessionsExpired() }
        agentServer.enabledExtensions = settings.enabledExtensions
        try? agentServer.start()
        monitors.enabledSources = settings.enabledLogMonitors
        monitors.emit = { [weak self] event in _ = self?.agentServerOutput(event) }
        monitors.start()
        input.onKeyDown = { [weak self] in self?.handleKeyDown() }
        input.onScroll = { [weak self] in self?.handleScroll() }
        input.start(
            promptForPermission: !PermissionGuides.isRunningUnderXCTest,
            retryIfUnauthorized: !PermissionGuides.isRunningUnderXCTest, guideWindow: panel)
        reconcileHooksBestEffort()
        startDisplayLink()
        scheduleStretchTimer()
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true

        NSObject.cancelPreviousPerformRequests(withTarget: self)
        displayLink?.invalidate()
        displayLink = nil
        stretchTimer?.invalidate()
        stretchTimer = nil
        focusStartTimer?.invalidate()
        focusStartTimer = nil
        antigravityThinkingTimer?.invalidate()
        antigravityThinkingTimer = nil
        sharePreviewTimer?.invalidate()
        sharePreviewTimer = nil

        shareCancellation?.cancel()
        shareCancellation = nil
        shareOverlay.onCancel = nil
        shareOverlay.hide()

        input.onKeyDown = nil
        input.onScroll = nil
        input.stop()

        agentServer.onOutput = nil
        agentServer.onSessionsExpired = nil
        agentServer.stop()
        monitors.emit = nil
        monitors.stop()

        sound.stopPurring()

        patternWindow?.close()
        patternWindow = nil
        reminderWindow?.close()
        reminderWindow = nil

        if let panel {
            let frameToPersist = stretchRestoreFrame ?? panel.frame
            settings.petPosition = StoredPoint(x: frameToPersist.origin.x, y: frameToPersist.origin.y)
            panel.close()
        }
        stretchRestoreFrame = nil

        try? saveSettings()
        try? patternStore.save(pattern)
    }

    func setPattern(_ newPattern: PatternModel) {
        var sanitized = newPattern.sanitized()
        sanitized.selectedPresetId =
            presets.matchingPreset(for: sanitized)?.id ?? sanitized.selectedPresetId
        pattern = sanitized
        try? patternStore.save(sanitized)
        guard petView != nil else { return }
        var state = petView.state
        state.pattern = sanitized
        petView.state = state
    }

    private func createWindow() {
        let size = WindowGeometry.windowSize(petSize: settings.petSize)
        let screens: [any NSScreenLike] = NSScreen.screens
        let origin: CGPoint
        if let p = settings.petPosition,
            WindowGeometry.isVisible(CGPoint(x: p.x, y: p.y), size: size, screens: screens)
        {
            origin = CGPoint(x: p.x, y: p.y)
        } else {
            origin = WindowGeometry.defaultPosition(
                displayFrame: NSScreen.main?.visibleFrame
                    ?? CGRect(x: 0, y: 0, width: 1440, height: 900),
                windowSize: size
            )
        }
        panel = PetPanel(size: size, origin: origin)
        let compositor = makeCompositor(for: settings.skin)
        var initial = RenderState()
        initial.pattern = pattern
        initial.catName = settings.catName
        initial.showName = settings.showCatName
        initial.pomodoroMode = pomodoro.mode
        initial.pomodoroRunning = pomodoro.running
        applyBaseSpeech(to: &initial)
        petView = PetView(
            frame: CGRect(origin: .zero, size: size), compositor: compositor, state: initial)
        petView.restingHeight = WindowGeometry.restingHeight(petSize: settings.petSize)
        petView.skyRoom = WindowGeometry.skyRoom(petSize: settings.petSize)
        petView.delegate = self
        panel.contentView = petView
        panel.orderFrontRegardless()
    }

    /// Build the renderer for a character. Every skin uses the same `PixelCompositor`; non-cat skins
    /// swap in their own pose-geometry library and disable the procedural mochi lift.
    func makeCompositor(for skin: PetSkin) -> PixelCompositor {
        guard skin != .cat, let skinLibrary = try? PoseLibrary.load(resource: skin.poseResource) else {
            return PixelCompositor(library: library, mappings: mappings)
        }
        let compositor = PixelCompositor(library: skinLibrary, mappings: mappings)
        compositor.usesMochiLift = false
        compositor.skipUserPatches = true  // fixed-palette skin; ignore the user's cat pattern spots
        return compositor
    }

    private enum FrameRateTier {
        case interactive
        case ambient
    }
    /// Full ProMotion rate: cursor tracking, drags, and one-shot motions stay at up to 120 Hz.
    private static let interactiveFrameRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    /// Ambient rate: chrome (thinking dots, z's, hearts) animates at 24 fps and idle breathing
    /// redraws ~10x/s, so ticking faster than ~30 Hz only burned CPU between redraws.
    private static let ambientFrameRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
    /// How long after the last input the loop keeps the interactive rate (covers the eased
    /// cursor-tracking settle after the mouse stops).
    private static let interactiveInputWindow: TimeInterval = 2

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = panel.displayLink(target: self, selector: #selector(frameTick(_:)))
        link.preferredFrameRateRange = Self.interactiveFrameRange
        frameRateTier = .interactive
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    /// Downshifts the display link when nothing latency-sensitive is running and restores the
    /// interactive rate the moment input or a one-shot animation arrives. The switch happens on
    /// the next tick, so the worst-case wake-up latency is one ambient frame (~33 ms).
    private func updateFrameRateTier(now: TimeInterval, state: RenderState) {
        let interactive =
            now - lastInputAt < Self.interactiveInputWindow
            || jumpStartedAt != nil
            || reactionStartedAt != nil
            || stretchInProgress
            || focusStartInProgress
            || state.hunting || state.huntingReturn
            || state.pose == .scroll
            || now < poseReleaseAt
            || state.mochiStretchActive
            || stretchChain.activity > 0.001
        let tier: FrameRateTier = interactive ? .interactive : .ambient
        guard tier != frameRateTier, let link = displayLink else { return }
        frameRateTier = tier
        link.preferredFrameRateRange =
            tier == .interactive ? Self.interactiveFrameRange : Self.ambientFrameRange
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let mouse = NSEvent.mouseLocation
        let mouseMoved = didMouseMove(to: mouse)
        if mouseMoved { lastInputAt = now }
        if isStretchActive(state: petView.state) {
            hoverHead = false
        } else {
            petView.refreshMouseState()
        }

        var state = petView.state
        state.time = now
        state.pattern = pattern
        state.catName = settings.catName
        state.showName = settings.showCatName
        state.pomodoroMode = pomodoro.mode
        state.pomodoroRunning = pomodoro.running
        if now > speechUntil {
            transientSpeech = nil
            transientSpeechKind = .notice
            applyBaseSpeech(to: &state)
        } else {
            state.speech = transientSpeech
            state.speechKind = transientSpeechKind
        }

        stretchChain.step()
        let chainActivity = stretchChain.activity
        state.stretchProgress = chainActivity
        state.mochiStretchActive = chainActivity > 0.01
        state.stretchT = liftMorphT(stretchChain.stretchT)
        state.stretchSegmentDX = (0..<StretchChain.segmentCount).map {
            stretchChain.cumulativeDX(upTo: $0)
        }
        state.stretchPoseProgress = stretchPoseEnvelope(now: now)
        if chainActivity > 0.001 || petView.stretchChain.activity > 0.001 {
            petView.stretchChain = stretchChain
        }

        state.hunting = now < huntingUntil
        state.huntingReturn = now >= huntingUntil && now < huntingReturnUntil
        if state.hunting {
            let startedAt = huntingUntil - 1.1
            state.huntingEnter = easeOutCubic(clamp01(CGFloat((now - startedAt) / 0.42)))
        } else {
            state.huntingEnter = 0
        }
        if state.huntingReturn {
            state.huntingReturnProgress = easeOutCubic(clamp01(CGFloat((now - huntingUntil) / 0.42)))
        } else {
            state.huntingReturnProgress = 0
        }

        if now > poseReleaseAt, !state.hunting, !state.huntingReturn, jumpStartedAt == nil,
            !stretchInProgress
        {
            if state.pose != .stretchEnd {
                state.pose = .idle
            } else if chainActivity < 0.01 {
                state.pose = .idle
            }
        }
        if state.pose == .scroll {
            state.scrollProgress = ScrollReaction.progress(startedAt: scrollStartedAt, now: now)
        } else {
            state.scrollProgress = 0
            scrollStartedAt = nil
        }

        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        updateSleep(now: now, state: &state)
        // A sleeping cat doesn't watch the cursor: ease the tracking rig back to neutral.
        state.tracking = tracking.step(mouse: sleep.sleeping ? center : mouse, windowCenter: center)
        heat.stretchingTarget = now < stretchHeatUntil ? 1 : 0
        state.heat = heat.step(now: now)
        state.stretchingHeat = heat.stretchingHeat
        updateJump(now: now, state: &state)
        updateReaction(now: now, state: &state)
        state.editPops.removeAll { now - $0.spawnedAt >= $0.flightTime + EditPop.fadeDuration }
        updatePurr(now: now, state: &state, moved: mouseMoved, mouse: mouse)
        updateCuriosity(now: now, state: &state, mouse: mouse, center: center, moved: mouseMoved)
        updateKnead(now: now, state: &state)
        updateClickThrough()
        petView.state = state
        updateFrameRateTier(now: now, state: state)
        if pendingWakeStretch {
            // Deferred past the state write-back: runStretchSequence mutates petView.state itself,
            // and running it mid-tick would be clobbered by the assignment above.
            pendingWakeStretch = false
            runStretchSequence()
        }
        if Date().timeIntervalSince(lastSecondTick) >= 1 {
            tickSecond()
            lastSecondTick = Date()
        }
        if Date().timeIntervalSince(lastReminderCheck) >= 15 {
            checkReminders()
            lastReminderCheck = Date()
        }
    }

    private func updatePurr(now: TimeInterval, state: inout RenderState, moved: Bool, mouse: CGPoint) {
        let canPurr = state.pose == .idle && !state.hunting && !state.huntingReturn
        guard canPurr else {
            purr = PurrState()
            state.purring = false
            state.purrFaceOffset = .zero
            sound.stopPurring()
            return
        }

        if purr.step(onHead: hoverHead, moved: moved, now: now) {
            state.purring = true
            state.purrFaceOffset = purrFaceOffset(for: mouse)
            sound.startPurring()
        } else {
            state.purring = false
            state.purrFaceOffset = .zero
            sound.stopPurring()
        }
    }

    /// Doze off after a long input lull; wake with the stretch only when real input ends the nap.
    /// An agent reaction (jump/shake/thinking) interrupts the nap quietly via `blocked`, and the
    /// still-stale input clock simply puts the cat back to sleep once the reaction passes.
    private func updateSleep(now: TimeInterval, state: inout RenderState) {
        let poseBlocks = state.pose != .idle && state.pose != .sleepCurl
        let blocked =
            poseBlocks || state.thinking || state.hunting || state.huntingReturn
            || state.purring || hoverHead || jumpStartedAt != nil || reactionStartedAt != nil
            || isStretchActive(state: state) || focusStartInProgress || now < speechUntil
        switch sleep.step(now: now, lastInputAt: lastInputAt, blocked: blocked) {
        case .wokeByInput:
            state.sleeping = false
            if state.pose == .sleepCurl { state.pose = .idle }
            pendingWakeStretch = true
        case .interrupted:
            state.sleeping = false
            if state.pose == .sleepCurl { state.pose = .idle }
        case .fellAsleep:
            state.sleeping = true
            state.pose = .sleepCurl
        case .none:
            state.sleeping = sleep.sleeping
            // Re-assert each frame: the pose-release machinery upstream resets to .idle.
            if sleep.sleeping, state.pose == .idle { state.pose = .sleepCurl }
        }
    }

    /// Cock the head toward a cursor that lingers near (but not on) the cat. Applies only while
    /// no one-shot reaction owns `tiltAngle` — those keep priority.
    private func updateCuriosity(
        now: TimeInterval, state: inout RenderState, mouse: CGPoint, center: CGPoint, moved: Bool
    ) {
        let dx = mouse.x - center.x
        let dist = hypot(dx, mouse.y - center.y)
        let width = max(panel.frame.width, 1)
        let nearby = dist > width * 0.9 && dist < width * 3.0
        let engaged =
            state.pose != .idle || state.hunting || state.huntingReturn || state.purring
            || state.sleeping || hoverHead || reactionStartedAt != nil || jumpStartedAt != nil
            || isStretchActive(state: state)
        let tilt = curiosity.step(now: now, nearby: nearby, moved: moved, side: dx, engaged: engaged)
        if reactionStartedAt == nil { state.tiltAngle = tilt }
    }

    /// Thinking-time kneading: while an agent works and the user isn't typing, the cat rhythmically
    /// presses its front paws like kneading a blanket (the paw motion lives in
    /// `PixelCompositor.kneadTransform`, scaled by the `KneadMotion` envelope). Real keystrokes
    /// own the press poses — `KneadMotion.typingGrace` keeps the two from interleaving.
    private func updateKnead(now: TimeInterval, state: inout RenderState) {
        let eligible =
            state.thinking && !state.sleeping && !state.purring && !state.hunting
            && !state.huntingReturn && reactionStartedAt == nil && jumpStartedAt == nil
            && !isStretchActive(state: state) && !stretchInProgress && !focusStartInProgress
            && now - lastInputAt > KneadMotion.typingGrace
            && state.pose == .idle
        state.kneadPhase = knead.step(now: now, eligible: eligible)
    }

    private func applyBaseSpeech(to state: inout RenderState) {
        if settings.fixedMessage.isEmpty {
            state.speech = nil
            state.speechKind = .notice
        } else {
            state.speech = settings.fixedMessage
            state.speechKind = .fixed
        }
    }

    private func showFirstRunNamePromptIfNeeded() {
        guard !PermissionGuides.isRunningUnderXCTest, !settings.catNamePromptShown else { return }
        guard editSettings({ $0.catNamePromptShown = true }) else { return }
        petView.showInlineEditor(
            config: InlineEditorConfig(
                anchor: .cat, width: 220, initialValue: settings.catName, placeholder: "Cat name",
                guide: nil, suffix: nil, maxLength: 24)
        ) { [weak self] value in
            self?.editSettings { $0.catName = value }
        }
    }

    private func reconcileLaunchAtLogin() {
        guard !PermissionGuides.isRunningUnderXCTest else { return }
        #if !DEBUG
            // Honor the persisted preference (default true) so a fresh install starts at login
            // with no setup. Debug builds skip this to avoid registering the DerivedData bundle.
            LaunchAtLogin.apply(settings.launchAtLogin)
        #endif
    }

    private func didMouseMove(to mouse: CGPoint) -> Bool {
        defer { lastMousePosition = mouse }
        guard let lastMousePosition else { return false }
        return abs(mouse.x - lastMousePosition.x) > 0.01 || abs(mouse.y - lastMousePosition.y) > 0.01
    }

    private func purrFaceOffset(for mouse: CGPoint) -> CGPoint {
        guard let window = petView.window else { return .zero }
        let point = petView.convert(window.convertPoint(fromScreen: mouse), from: nil)
        let catRect = petView.catDrawRect()
        guard catRect.width > 0, catRect.height > 0 else { return .zero }
        let nx = (point.x - catRect.minX) / catRect.width
        let ny = (point.y - catRect.minY) / catRect.height
        let dx = max(-1, min(1, (nx - 0.40) / 0.25))
        let dy = max(-1, min(1, (ny - 0.33) / 0.23))
        return CGPoint(x: dx * 1.15, y: dy * 0.75)
    }

    private func isStretchActive(state: RenderState? = nil) -> Bool {
        if stretchInProgress { return true }
        if stretchChain.activity > 0.01 { return true }
        if let state, state.mochiStretchActive { return true }
        return false
    }

    private func isPressPose(_ pose: PetPose) -> Bool {
        pose == .pressLeft || pose == .pressRight
    }

    private func isJumpPose(_ pose: PetPose) -> Bool {
        pose == .jumpStart || pose == .jumpIng
    }

    private func isStretchPose(_ pose: PetPose) -> Bool {
        pose == .stretchStart || pose == .stretchEnd || pose == .stretchDefault
    }

    private func clamp01(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    private func easeOutCubic(_ value: CGFloat) -> CGFloat {
        let t = clamp01(value)
        return 1 - pow(1 - t, 3)
    }

    private func easeInOut(_ value: CGFloat) -> CGFloat {
        let t = clamp01(value)
        return t * t * (3 - 2 * t)
    }

    private func stretchPoseEnvelope(now: TimeInterval) -> CGFloat {
        guard let stretchPoseStartedAt else { return 0 }
        let t = clamp01(CGFloat((now - stretchPoseStartedAt) / 3.0))
        if t < 0.30 { return easeInOut(t / 0.30) }
        if t <= 0.70 { return 1 }
        return 1 - easeInOut((t - 0.70) / 0.30)
    }

    private func updateJump(now: TimeInterval, state: inout RenderState) {
        guard let jumpStartedAt else {
            state.jumpY = 0
            state.bubbleJumpY = 0
            state.jumpPhase = 0
            return
        }
        if isStretchActive(state: state) {
            resetJumpDriver()
            state.jumpY = 0
            state.bubbleJumpY = 0
            state.jumpPhase = 0
            return
        }
        let elapsed = now - jumpStartedAt
        guard elapsed < Self.jumpTotalDuration else {
            resetJumpDriver()
            state.pose = .idle
            state.jumpY = 0
            state.bubbleJumpY = 0
            state.jumpPhase = 0
            return
        }
        state.jumpPhase = CGFloat(elapsed / Self.jumpTotalDuration)
        guard let index = Self.jumpKeyframes.lastIndex(where: { elapsed >= $0.time }) else { return }
        let keyframe = Self.jumpKeyframes[index]
        let targetY = jumpFraction(px: keyframe.jumpPx)
        let targetBubbleY = jumpFraction(px: keyframe.bubblePx)
        if index != jumpActiveKeyframeIndex {
            jumpActiveKeyframeIndex = index
            jumpTransitionStartedAt = now
            jumpTransitionStartY = state.jumpY
            jumpTransitionStartBubbleY = state.bubbleJumpY
        }
        let progress = clamp01(CGFloat((now - jumpTransitionStartedAt) / Self.jumpTransitionDuration))
        let eased = cubicBezier(progress, x1: 0.2, y1: 0.78, x2: 0.25, y2: 1)
        state.jumpY = jumpTransitionStartY + (targetY - jumpTransitionStartY) * eased
        state.bubbleJumpY =
            jumpTransitionStartBubbleY + (targetBubbleY - jumpTransitionStartBubbleY) * eased
        state.pose = keyframe.pose
    }

    private func resetJumpDriver() {
        jumpStartedAt = nil
        jumpActiveKeyframeIndex = -1
        jumpTransitionStartedAt = 0
        jumpTransitionStartY = 0
        jumpTransitionStartBubbleY = 0
    }

    private func jumpFraction(px: CGFloat) -> CGFloat {
        let screenHeight =
            panel.screen?.frame.height ?? NSScreen.main?.frame.height ?? max(panel.frame.height, 1)
        return px * 4.8 / max(screenHeight, 1)
    }

    private func cubicBezier(_ progress: CGFloat, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat)
        -> CGFloat
    {
        let x = clamp01(progress)
        var low: CGFloat = 0
        var high: CGFloat = 1
        var t = x
        for _ in 0..<8 {
            t = (low + high) * 0.5
            let estimate = cubicBezierCoordinate(t, p1: x1, p2: x2)
            if estimate < x { low = t } else { high = t }
        }
        return cubicBezierCoordinate(t, p1: y1, p2: y2)
    }

    private func cubicBezierCoordinate(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private func updateClickThrough() {
        guard let window = panel, let view = petView else { return }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let catHit = CatHitTester.isCatHit(
            point: point, in: view.catDrawRect(), stretched: view.state.pose == .stretchEnd)
        let chromeHit = view.visibleInteractiveRects().contains { $0.contains(point) }
        let shouldIgnoreMouse = !(catHit || chromeHit)
        if window.ignoresMouseEvents != shouldIgnoreMouse {
            window.ignoresMouseEvents = shouldIgnoreMouse
        }
    }

    private func tickSecond() {
        if let event = pomodoro.tick() {
            let name = settings.userName.isEmpty ? "Human" : settings.userName
            switch event {
            case .focusCompleted:
                speak("\(name), take a break!", seconds: 1.8)
                runStretchSequence()
            case .restCompleted:
                speak("\(name), back to focus!", seconds: 1.8)
                runFocusStartSequence()
            }
            return
        }

        guard pomodoro.visible else { return }
        let text = pomodoro.timerText
        let now = CACurrentMediaTime()
        let showingTimer = transientSpeechKind == .timer
        if showingTimer || now >= speechUntil {
            transientSpeech = text
            transientSpeechKind = .timer
            petView.state.speech = text
            petView.state.speechKind = .timer
            speechUntil = now + 1.2
        }
    }

    private func checkReminders() {
        let now = Date()
        let scheduler = ReminderScheduler(reminders: settings.reminders)
        let due = scheduler.due(now: now)
        guard !due.isEmpty else { return }
        for reminder in due {
            speak(
                reminder.speech(userName: settings.userName, date: now), seconds: 5.2, kind: .reminder)
            sound.playReminder(volume: settings.taskCompleteSoundVolume, repeatAfter: true)
            runJumpSequence()
        }
        scheduler.markTriggered(ids: Set(due.map(\.id)), now: now)
        settings.reminders = scheduler.reminders
        try? saveSettings()
    }

    private func handleKeyDown() {
        let now = CACurrentMediaTime()
        lastInputAt = now
        heat.recordKey(at: now)
        let pose = petView.state.pose
        guard !isStretchActive(state: petView.state), !isStretchPose(pose), !isJumpPose(pose),
            pose != .scroll
        else { return }
        petView.state.pose = nextPressLeft ? .pressLeft : .pressRight
        nextPressLeft.toggle()
        poseReleaseAt = now + 0.180
    }

    private func handleScroll() { runScrollReaction() }

    private func runScrollReaction() {
        let now = CACurrentMediaTime()
        lastInputAt = now
        let pose = petView.state.pose
        guard !isStretchActive(state: petView.state), !isStretchPose(pose), !isPressPose(pose),
            !isJumpPose(pose)
        else { return }
        if pose != .scroll {
            petView.state.scrollProgress = 0
            scrollStartedAt = now
        }
        petView.state.pose = .scroll
        poseReleaseAt = now + ScrollReaction.releaseDuration
    }

    private func runJumpSequence() {
        let now = CACurrentMediaTime()
        let pose = petView.state.pose
        guard !isStretchActive(state: petView.state), !isStretchPose(pose) else { return }
        resetJumpDriver()
        scrollStartedAt = nil
        reactionStartedAt = nil
        var state = petView.state
        state.scrollProgress = 0
        state.jumpY = 0
        state.bubbleJumpY = 0
        state.pose = .jumpStart
        petView.state = state
        jumpStartedAt = now
        jumpActiveKeyframeIndex = -1
        jumpTransitionStartedAt = now
        jumpTransitionStartY = 0
        jumpTransitionStartBubbleY = 0
        poseReleaseAt = now + Self.jumpTotalDuration
    }

    private static let reactionMotionDuration: TimeInterval = 0.5
    private static let reactionBadgeDuration: TimeInterval = 1.1

    /// Start a one-shot reaction motion (`tilt`/`pop`/`shake`) plus its floating badge. Unlike the
    /// jump, these drive `RenderState` offset/rotation/scale fields instead of swapping the pose, so
    /// they compose with the idle animation and decay back to rest.
    private func startReaction(_ animation: AgentReaction.Animation) {
        reactionAnimation = animation
        reactionStartedAt = CACurrentMediaTime()
    }

    private static func reactionBadge(for animation: AgentReaction.Animation) -> ReactionBadge {
        switch animation {
        case .tilt: return .ask
        case .pop: return .plan
        case .shake: return .error
        default: return .none
        }
    }

    private static func reactionFlourish(for animation: AgentReaction.Animation) -> ReactionFlourish {
        switch animation {
        case .tilt: return .askEars
        case .shake: return .errorEars
        case .pop: return .planTail
        case .none: return .attentionEars
        case .jump: return .none
        }
    }

    private func updateReaction(now: TimeInterval, state: inout RenderState) {
        state.shakeX = 0
        state.tiltAngle = 0
        state.popScale = 0
        guard let reactionStartedAt else {
            state.reactionBadge = .none
            state.reactionBadgePhase = 0
            state.flourish = .none
            state.flourishPhase = 0
            return
        }
        let elapsed = now - reactionStartedAt
        guard elapsed < Self.reactionBadgeDuration else {
            self.reactionStartedAt = nil
            state.reactionBadge = .none
            state.reactionBadgePhase = 0
            state.flourish = .none
            state.flourishPhase = 0
            return
        }
        if elapsed < Self.reactionMotionDuration {
            let motion = elapsed / Self.reactionMotionDuration
            switch reactionAnimation {
            case .shake: state.shakeX = CGFloat(sin(elapsed / 0.11 * 2 * .pi) * 0.04 * (1 - motion))
            case .tilt: state.tiltAngle = CGFloat(sin(motion * .pi) * 0.14)
            case .pop: state.popScale = CGFloat(sin(motion * .pi) * 0.12)
            default: break
            }
        }
        state.reactionBadge = Self.reactionBadge(for: reactionAnimation)
        state.reactionBadgePhase = CGFloat(elapsed / Self.reactionBadgeDuration)
        state.flourish = Self.reactionFlourish(for: reactionAnimation)
        state.flourishPhase = CGFloat(elapsed / Self.reactionBadgeDuration)
    }

    /// Run the animation, sound, and speech for an agent output's reaction (see `AgentReaction`).
    private func applyReaction(_ reaction: AgentReaction) {
        switch reaction.sound {
        case .completion: sound.playCompletion(volume: settings.taskCompleteSoundVolume)
        case .reminder: sound.playReminder(volume: settings.taskCompleteSoundVolume)
        case .none: break
        }
        switch reaction.animation {
        case .jump: runJumpSequence()
        case .tilt, .pop, .shake: startReaction(reaction.animation)
        case .none: startReaction(.none)
        }
        speak(reaction.speech, seconds: 4, kind: reaction.bubbleKind)
    }

    func runStretchSequence() {
        guard !stretchInProgress, !focusStartInProgress else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(beginStretchPose), object: nil)
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(restoreAfterStretch), object: nil)
        stretchInProgress = true
        stretchRestoreFrame = panel.frame
        stretchPoseStartedAt = nil
        stretchHeatUntil = 0
        let now = CACurrentMediaTime()
        huntingUntil = 0
        huntingReturnUntil = 0
        scrollStartedAt = nil
        resetJumpDriver()
        stretchChain.endDrag()
        petView.stretchChain = stretchChain

        var state = petView.state
        state.hunting = false
        state.huntingReturn = false
        state.huntingEnter = 0
        state.huntingReturnProgress = 0
        state.scrollProgress = 0
        state.jumpY = 0
        state.bubbleJumpY = 0
        state.pose = .stretchDefault
        state.stretchPoseProgress = 0
        petView.state = state
        poseReleaseAt = now + 3.6

        let expanded = expandedSequenceFrame(on: screen)
        petView.restingHeight = expanded.height  // fill the temporarily expanded square (no dangle cap here)
        petView.skyRoom = 0
        panel.setFrame(expanded, display: true, animate: true)
        perform(#selector(beginStretchPose), with: nil, afterDelay: 0.4)
        perform(#selector(restoreAfterStretch), with: nil, afterDelay: 3.6)
    }

    private func runFocusStartSequence() {
        guard !focusStartInProgress, !stretchInProgress else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(beginFocusStartBurst), object: nil)
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(restoreAfterFocusStart), object: nil)
        focusStartInProgress = true
        focusStartTimer?.invalidate()
        focusStartTimer = nil
        focusStartStep = 0
        stretchRestoreFrame = panel.frame
        let expanded = expandedSequenceFrame(on: screen)
        petView.restingHeight = expanded.height  // fill the temporarily expanded square (no dangle cap here)
        petView.skyRoom = 0
        panel.setFrame(expanded, display: true, animate: true)
        perform(#selector(beginFocusStartBurst), with: nil, afterDelay: 0.160)
        perform(#selector(restoreAfterFocusStart), with: nil, afterDelay: 1.400)
    }

    private func expandedSequenceFrame(on screen: NSScreen) -> CGRect {
        let workArea = screen.visibleFrame
        let side = workArea.height * 0.90
        return CGRect(
            x: workArea.midX - side / 2, y: workArea.midY - side / 2, width: side, height: side)
    }

    @objc private func beginStretchPose() {
        let now = CACurrentMediaTime()
        stretchPoseStartedAt = now
        stretchHeatUntil = now + 2.1
        petView.state.pose = .stretchDefault
        petView.state.stretchPoseProgress = 0
    }

    @objc private func beginFocusStartBurst() {
        guard focusStartInProgress else { return }
        focusStartStep = 0
        runFocusStartBurstStep()
        let timer = Timer(timeInterval: 0.110, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.focusStartInProgress else {
                    self?.focusStartTimer?.invalidate()
                    self?.focusStartTimer = nil
                    return
                }
                self.runFocusStartBurstStep()
                if self.focusStartStep >= 10 {
                    self.focusStartTimer?.invalidate()
                    self.focusStartTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusStartTimer = timer
    }

    private func runFocusStartBurstStep() {
        guard focusStartStep < 10 else { return }
        let now = CACurrentMediaTime()
        heat.recordKey(at: now)
        petView.state.pose = nextPressLeft ? .pressLeft : .pressRight
        nextPressLeft.toggle()
        poseReleaseAt = now + 0.180
        focusStartStep += 1
    }

    @objc private func restoreAfterStretch() {
        if let frame = stretchRestoreFrame { panel.setFrame(frame, display: true, animate: true) }
        petView.restingHeight = WindowGeometry.restingHeight(petSize: settings.petSize)
        petView.skyRoom = WindowGeometry.skyRoom(petSize: settings.petSize)
        stretchInProgress = false
        stretchPoseStartedAt = nil
        stretchHeatUntil = 0
        var state = petView.state
        state.pose = .idle
        state.stretchPoseProgress = 0
        petView.state = state
        stretchRestoreFrame = nil
    }

    @objc private func restoreAfterFocusStart() {
        if let frame = stretchRestoreFrame { panel.setFrame(frame, display: true, animate: true) }
        petView.restingHeight = WindowGeometry.restingHeight(petSize: settings.petSize)
        petView.skyRoom = WindowGeometry.skyRoom(petSize: settings.petSize)
        focusStartTimer?.invalidate()
        focusStartTimer = nil
        focusStartInProgress = false
        focusStartStep = 0
        if isPressPose(petView.state.pose) { petView.state.pose = .idle }
        stretchRestoreFrame = nil
    }

    func scheduleStretchTimer() {
        stretchTimer?.invalidate()
        guard settings.stretchIntervalMin > 0 else { return }
        stretchTimer = Timer.scheduledTimer(
            timeInterval: TimeInterval(settings.stretchIntervalMin * 60), target: self,
            selector: #selector(stretchTimerFired(_:)), userInfo: nil, repeats: true)
    }

    @objc private func stretchTimerFired(_ timer: Timer) {
        runStretchSequence()
    }

    func speak(_ text: String, seconds: TimeInterval, kind: SpeechBubbleKind = .notice) {
        let now = CACurrentMediaTime()
        if now < speechUntil, seconds <= 1.5 { return }
        transientSpeech = text
        transientSpeechKind = kind
        petView.state.speech = text
        petView.state.speechKind = kind
        speechUntil = now + seconds
    }

    func saveSettings() throws {
        settings = settings.sanitized()
        try settingsStore.save(settings)
        applySettingsToVisibleState()
    }

    @discardableResult
    func editSettings(_ mutation: (inout ClawdiSettings) -> Void) -> Bool {
        let previous = settings
        mutation(&settings)
        do {
            try saveSettings()
            return true
        } catch {
            settings = previous
            applySettingsToVisibleState()
            NSSound.beep()
            return false
        }
    }

    private func applySettingsToVisibleState() {
        guard petView != nil else { return }
        var state = petView.state
        state.catName = settings.catName
        state.showName = settings.showCatName
        if CACurrentMediaTime() > speechUntil {
            applyBaseSpeech(to: &state)
        }
        petView.state = state
    }

    func reconcileHooksBestEffort() {
        agentServer.enabledExtensions = settings.enabledExtensions
        guard !PermissionGuides.isRunningUnderXCTest else { return }
        guard let helper = try? paths.installedHookHelper() else { return }
        try? HookInstaller(
            home: FileManager.default.homeDirectoryForCurrentUser, helperPath: helper.path
        ).reconcile(enabled: settings.enabledExtensions)
    }

    private func agentServerOutput(_ event: AgentStateEvent) -> AgentOutput {
        agentServer.handle(event)
    }

    private func handleAgentOutput(_ output: AgentOutput) {
        switch output {
        case .active(let event):
            cancelAntigravityThinkingTimer()
            petView.state.thinking = true
            refreshThinkingCounts()
            if let edits = event.edits { spawnEditPops(edits, cwd: event.cwd, tuning: event.editTuning) }
            if event.agentId == "antigravity" { scheduleAntigravityThinkingTimer() }
        case .complete(let event):
            cancelAntigravityThinkingTimer()
            petView.state.thinking = agentServer.hasActiveSessions
            refreshThinkingCounts()
            applyReaction(AgentReaction.completion(for: event))
        case .notification(let event):
            cancelAntigravityThinkingTimer()
            petView.state.thinking = agentServer.hasActiveSessions
            refreshThinkingCounts()
            applyReaction(AgentReaction.notification(for: event))
        case .cleared:
            cancelAntigravityThinkingTimer()
            petView.state.thinking = agentServer.hasActiveSessions
            refreshThinkingCounts()
        case .ignored:
            break
        }
    }

    /// Launch one flying `project>file +a -r` diff stat per edited file (see `EditPop`): staggered
    /// spawn times, a random launch angle in the 45°–135° cone, and an apex 0.5–0.75× the pet
    /// square above the launch point (flying into the window's reserved sky room). Demo events may
    /// override flight time and apex height (see `EditPopTuning`). The live list is capped so an
    /// edit storm can't wallpaper the window; the frame tick prunes each pop once its
    /// flight-plus-fade expires.
    private func spawnEditPops(_ edits: [FileEditStat], cwd: String?, tuning: EditPopTuning?) {
        let now = CACurrentMediaTime()
        var pops = petView.state.editPops
        for (index, edit) in edits.enumerated() {
            pops.append(
                EditPop(
                    label: EditPop.label(path: edit.path, cwd: cwd),
                    added: edit.added,
                    removed: edit.removed,
                    spawnedAt: now + Double(index) * 0.28,
                    flightTime: tuning?.flight ?? EditPop.defaultFlight,
                    angle: CGFloat.random(in: (.pi / 4)...(3 * .pi / 4)),
                    rise: tuning?.rise.map { CGFloat($0) } ?? CGFloat.random(in: 0.5...0.75)))
        }
        if pops.count > 12 { pops.removeFirst(pops.count - 12) }
        petView.state.editPops = pops
    }

    /// Stale sessions aged out with no event arriving (dead agent): drop the thinking flag the
    /// event handlers would normally refresh, or the cat keeps the knead going forever.
    private func handleAgentSessionsExpired() {
        petView.state.thinking = agentServer.hasActiveSessions
        refreshThinkingCounts()
    }

    private func refreshThinkingCounts() {
        let counts = agentServer.activeProviderCounts
        petView.state.openaiCount = counts.openai
        petView.state.anthropicCount = counts.anthropic
    }

    private func cancelAntigravityThinkingTimer() {
        antigravityThinkingTimer?.invalidate()
        antigravityThinkingTimer = nil
    }

    private func scheduleAntigravityThinkingTimer() {
        let timer = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.petView.state.thinking = self.agentServer.hasActiveSessions
                self.refreshThinkingCounts()
                self.antigravityThinkingTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        antigravityThinkingTimer = timer
    }

    func startShareOverlayTracking(screenFrame: CGRect) {
        sharePreviewTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.shareOverlay.update(
                    crop: ShareCrop.rect(display: screenFrame, petFrame: self.panel.frame),
                    display: screenFrame)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sharePreviewTimer = timer
    }

    func stopShareOverlayTracking() {
        sharePreviewTimer?.invalidate()
        sharePreviewTimer = nil
    }

    func petViewDidDrag(to origin: CGPoint) {
        settings.petPosition = StoredPoint(x: origin.x, y: origin.y)
        try? saveSettings()
    }

    func petViewRequestContextMenu(_ event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: petView)
    }

    func petViewHoverChanged(overHead: Bool) {
        hoverHead = overHead
    }

    func petViewMouseShakeDetected() {
        let now = CACurrentMediaTime()
        let pose = petView.state.pose
        guard now >= huntingReturnUntil else { return }
        guard !isStretchActive(state: petView.state), !isStretchPose(pose), !isPressPose(pose),
            pose != .scroll, !isJumpPose(pose)
        else { return }
        sound.stopPurring()
        purr = PurrState()
        petView.state.purring = false
        petView.state.purrFaceOffset = .zero
        huntingUntil = now + 1.1
        huntingReturnUntil = huntingUntil + 0.42
    }

    func petViewStretchDrag(deltaY: CGFloat, deltaX: CGFloat, ended: Bool) {
        if ended {
            stretchChain.endDrag()
            petView.stretchChain = stretchChain
            var state = petView.state
            state.mochiStretchActive = stretchChain.activity > 0.01
            state.stretchT = liftMorphT(stretchChain.stretchT)
            state.stretchSegmentDX = (0..<StretchChain.segmentCount).map {
                stretchChain.cumulativeDX(upTo: $0)
            }
            petView.state = state
            return
        }
        guard !stretchInProgress else { return }
        stretchChain.beginDrag()
        stretchChain.drag(deltaY: deltaY, deltaX: deltaX)
        petView.stretchChain = stretchChain
        var state = petView.state
        state.pose = .stretchEnd
        state.mochiStretchActive = stretchChain.activity > 0.01
        state.stretchT = liftMorphT(stretchChain.stretchT)
        state.stretchSegmentDX = (0..<StretchChain.segmentCount).map {
            stretchChain.cumulativeDX(upTo: $0)
        }
        petView.state = state
    }

    func petViewTogglePomodoro() {
        togglePomodoro()
    }
}
