import AppKit
import QuartzCore

@MainActor
final class PetPanel: NSPanel {
    init(size: CGSize, origin: CGPoint) {
        super.init(
            contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        title = "Clawdi"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
protocol PetViewDelegate: AnyObject {
    func petViewDidDrag(to origin: CGPoint)
    func petViewRequestContextMenu(_ event: NSEvent)
    func petViewHoverChanged(overHead: Bool)
    func petViewMouseShakeDetected()
    func petViewStretchDrag(deltaY: CGFloat, deltaX: CGFloat, ended: Bool)
    func petViewTogglePomodoro()
}

@MainActor
final class PetView: NSView {
    weak var delegate: PetViewDelegate?
    var compositor: PixelCompositor
    var state: RenderState { didSet { invalidateForStateChange() } }
    var stretchChain = StretchChain() { didSet { chromeView.needsDisplay = true } }
    /// Height the cat occupied before the window reserved dangle room (`WindowGeometry.restingHeight`).
    /// Keeps the resting square sized/placed as if the window were not taller, so the extra height is
    /// pure hang space below the cat. Zero falls back to `bounds.height` (unconfigured test views).
    var restingHeight: CGFloat = 0 {
        didSet {
            needsLayout = true
            chromeView.needsDisplay = true
        }
    }
    /// Transparent sky band above the resting cat square (`WindowGeometry.skyRoom`), reserved so
    /// edit pops can arc above the pet. Shifts `catDrawRect` down; zero during the temporarily
    /// expanded stretch/focus sequences, which want the cat to fill the whole window.
    var skyRoom: CGFloat = 0 {
        didSet {
            needsLayout = true
            chromeView.needsDisplay = true
        }
    }

    private var dragStartMouse: CGPoint?
    private var dragStartFrame: CGRect?
    private var hasDragged = false
    private var stretchingFromDrag = false
    private var lastDragEndedAt: TimeInterval = 0
    private var shake = ShakeDetector()
    private let pomodoroButton = NSButton()
    private let inlineEditor = InlineEditorOverlay()
    private let catLayers: CatLayerTree
    private let chromeView = ChromeView()
    private let catHost = CatHostView()

    private var lastDisplaySignature: DisplaySignature?
    private static let animatedChromeFramesPerSecond: Double = 24

    /// Chrome-only redraw gate: the cat itself lives in `catLayers` (GPU transforms), so this
    /// signature covers just the CG-drawn overlay — bubbles, badges, name, particles — plus the
    /// state flags that toggle or position them.
    private struct DisplaySignature: Equatable {
        let pose: PetPose
        let lifting: Bool
        let purring: Bool
        let sleeping: Bool
        let mochiStretch: Bool
        let heatBucket: Int
        let jumpLift: Int
        let showName: Bool
        let catName: String
        let speech: String?
        let speechKind: Int
        let pomodoroMode: String
        let pomodoroRunning: Bool
        let thinking: Bool
        let openaiCount: Int
        let anthropicCount: Int
        let bubbleJump: Int
        let jumpSparkle: Int
        let editPops: Int
        let reactionBadge: ReactionBadge
        let reactionBadgePhase: Int
        let animatedChromeFrame: Int
    }
    override var isFlipped: Bool { true }

    init(frame: CGRect, compositor: PixelCompositor, state: RenderState) {
        self.compositor = compositor
        self.state = state
        self.catLayers = CatLayerTree(compositor: compositor)
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        layer?.backgroundColor = NSColor.clear.cgColor
        // The cat's layer tree lives in a non-flipped host view: the pet view is flipped, and
        // AppKit's geometry-flip on its backing layer would otherwise invert the tree's CG
        // (y-up) slot math and mirror every layer's contents.
        catHost.frame = bounds
        catHost.autoresizingMask = [.width, .height]
        catHost.wantsLayer = true
        catHost.layer?.addSublayer(catLayers.containerLayer)
        addSubview(catHost)
        chromeView.host = self
        chromeView.wantsLayer = true
        chromeView.frame = bounds
        chromeView.autoresizingMask = [.width, .height]
        addSubview(chromeView)
        setupButtons()
        updateChrome()
        refreshCatLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Swap the active renderer (e.g. on a character change) and force a recomposite.
    func updateCompositor(_ compositor: PixelCompositor) {
        if let space = screenColorSpace { compositor.colorSpace = space }
        self.compositor = compositor
        catLayers.replaceCompositor(compositor)
        lastDisplaySignature = nil
        needsLayout = true
        refreshCatLayers()
        chromeView.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeScreenProfileNotification] {
            center.removeObserver(self, name: name, object: nil)
            if let window { center.addObserver(self, selector: #selector(syncColorSpace), name: name, object: window) }
        }
        syncColorSpace()
    }

    private var screenColorSpace: CGColorSpace? { window?.screen?.colorSpace?.cgColorSpace }

    /// Renders in the screen's color space so Core Animation composites the cat's rasters without
    /// a per-image conversion; re-rasterizes when the window moves screens or the profile changes.
    @objc private func syncColorSpace() {
        guard let space = screenColorSpace, space != compositor.colorSpace else { return }
        compositor.colorSpace = space
        catLayers.invalidateContents()
        refreshCatLayers()
        chromeView.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let catRect = catDrawRect()
        if let rect = currentSpeechRect(catRect: catRect), state.speechKind == .timer, !(state.speech ?? "").isEmpty {
            pomodoroButton.frame = CGRect(x: rect.maxX - 28, y: rect.minY + 4, width: 24, height: rect.height - 8)
        }
        if !inlineEditor.isHidden {
            inlineEditor.frame = inlineEditorFrame(catRect: catRect, config: inlineEditor.config)
        }
    }

    /// The cat is presented entirely by `catLayers`; the view itself draws nothing. Chrome
    /// (speech, badges, particles) is drawn by `chromeView` above the layer tree.
    fileprivate func drawChrome(in ctx: CGContext) {
        drawParticlesAndChrome(in: ctx, catRect: catDrawRect())
    }

    private func refreshCatLayers() {
        let catRect = catDrawRect()
        catLayers.update(
            state: state, scale: renderScale(for: catRect), catRect: catRect, lifting: isLifting,
            viewHeight: bounds.height)
    }

    /// Non-flipped container for the cat's CALayer tree; hit-testing passes through.
    private final class CatHostView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Transparent overlay hosting the CG-drawn chrome so it composites above the cat's
    /// layer tree; hit-testing passes through to the pet view.
    ///
    /// Renders into its own bitmap and hands that to the layer (`updateLayer`) rather than using
    /// `draw(_:)`: once a window-sized `draw(_:)` view starts redrawing, AppKit's backing store
    /// pins ~230 MB of GPU memory, versus one transient bitmap per redraw here.
    private final class ChromeView: NSView {
        weak var host: PetView?
        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateLayer() {
            guard let host, let layer else { return }
            let scale = window?.backingScaleFactor ?? 2
            let width = Int((bounds.width * scale).rounded(.up))
            let height = Int((bounds.height * scale).rounded(.up))
            guard width > 0, height > 0,
                let ctx = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: host.compositor.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                layer.contents = nil
                return
            }
            // Match the flipped view space `draw(_:)` would have provided.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            host.drawChrome(in: ctx)
            NSGraphicsContext.restoreGraphicsState()
            layer.contents = ctx.makeImage()
        }

        /// Only reached by offscreen captures (`cacheDisplay`); on-screen display uses `updateLayer`.
        override func draw(_ dirtyRect: NSRect) {
            guard let host, let ctx = NSGraphicsContext.current?.cgContext else { return }
            host.drawChrome(in: ctx)
        }
    }

    /// Lifting renders the elongated stretch pose at resting head scale, anchored near the idle head,
    /// so the body hangs *below* the resting square instead of being scaled-to-fit (which shrinks it).
    private var isLifting: Bool { state.mochiStretchActive && state.pose == .stretchEnd && compositor.usesMochiLift }

    func catDrawRect() -> CGRect {
        let usable = max(0, bounds.height - skyRoom)
        let resting = restingHeight > 0 ? min(restingHeight, usable) : usable
        let side = min(bounds.width, resting)
        return CGRect(
            x: (bounds.width - side) * 0.5, y: skyRoom + (resting - side) * WindowGeometry.catTopFraction,
            width: side, height: side)
    }

    /// Render above backing resolution and downsample with high interpolation. The extra sample
    /// margin softens the integer-grid SVG edges without making oversized windows allocate
    /// unbounded bitmaps.
    private static let renderDownsampleFactor: CGFloat = 1
    private static let maxRenderDimension: CGFloat = 768
    func renderScale(for catRect: CGRect, backingScale: CGFloat? = nil) -> CGFloat {
        let backing = backingScale ?? window?.backingScaleFactor ?? 2
        let vb = compositor.viewBox(for: state.pose.rawValue)
        guard vb.width > 0, vb.height > 0 else { return backing }
        let onScreen: CGFloat
        if isLifting {
            onScreen = CatLayout.liftScale(catSide: catRect.height)
        } else {
            let fitted = CatLayout.fittedRect(
                imageWidth: Int(vb.width.rounded()), imageHeight: Int(vb.height.rounded()), in: catRect)
            onScreen = fitted.height / vb.height
        }
        let cap = Self.maxRenderDimension / max(vb.width, vb.height)
        return max(1, min(onScreen * backing * Self.renderDownsampleFactor, cap))
    }

    func visibleInteractiveRects() -> [CGRect] {
        var rects = [pomodoroButton]
            .filter { !$0.isHidden }
            .map { $0.frame.insetBy(dx: -4, dy: -4) }
        if !inlineEditor.isHidden {
            rects.append(inlineEditor.frame.insetBy(dx: -4, dy: -4))
        }
        return rects
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = window?.frame
        hasDragged = false
        stretchingFromDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouse, let frame = dragStartFrame, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        guard hasDragged || abs(dx) > StretchChain.dragStartThreshold || abs(dy) > StretchChain.dragStartThreshold
        else { return }
        hasDragged = true
        // The window always follows the cursor in every direction; pulling upward *additionally*
        // drives the stretch chain rather than replacing the move, so dragging never freezes the
        // cat in place.
        window.setFrameOrigin(CGPoint(x: frame.minX + dx, y: frame.minY + dy))
        if !stretchingFromDrag, dy > StretchChain.dragStartThreshold, dy > abs(dx) * 1.25 {
            stretchingFromDrag = true
        }
        if stretchingFromDrag {
            delegate?.petViewStretchDrag(deltaY: dy, deltaX: dx, ended: false)
        }
        chromeView.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if stretchingFromDrag {
            delegate?.petViewStretchDrag(deltaY: 0, deltaX: 0, ended: true)
        }
        if let window, hasDragged {
            delegate?.petViewDidDrag(to: window.frame.origin)
            lastDragEndedAt = CACurrentMediaTime()
        }
        dragStartMouse = nil
        dragStartFrame = nil
        hasDragged = false
        stretchingFromDrag = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard CACurrentMediaTime() - lastDragEndedAt >= 0.5 else { return }
        delegate?.petViewRequestContextMenu(event)
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { delegate?.petViewHoverChanged(overHead: false) }

    func refreshMouseState() {
        guard let window else { return }
        let global = NSEvent.mouseLocation
        let point = convert(window.convertPoint(fromScreen: global), from: nil)
        delegate?.petViewHoverChanged(overHead: CatHitTester.isHead(point: point, in: catDrawRect()))
        if shake.step(mouse: global, now: CACurrentMediaTime()) { delegate?.petViewMouseShakeDetected() }
    }

    private func setupButtons() {
        pomodoroButton.target = self
        pomodoroButton.action = #selector(togglePomodoro)
        pomodoroButton.toolTip = "Pause or resume pomodoro"
        pomodoroButton.imageScaling = .scaleProportionallyDown
        pomodoroButton.isBordered = false
        pomodoroButton.focusRingType = .none
        pomodoroButton.wantsLayer = true
        pomodoroButton.layer?.cornerRadius = 3
        pomodoroButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        addSubview(pomodoroButton)

        inlineEditor.isHidden = true
        inlineEditor.onCancel = { [weak self] in self?.hideInlineEditor() }
        addSubview(inlineEditor)
    }

    @objc private func togglePomodoro() {
        delegate?.petViewTogglePomodoro()
    }
    func showInlineEditor(
        config: InlineEditorConfig, onCommit: @escaping (String) -> Void, onCancel: (() -> Void)? = nil
    ) {
        inlineEditor.configure(config)
        inlineEditor.onCommit = { [weak self] value in
            self?.hideInlineEditor()
            onCommit(value)
        }
        inlineEditor.onCancel = { [weak self] in
            self?.hideInlineEditor()
            onCancel?()
        }
        inlineEditor.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        inlineEditor.beginEditing()
    }

    func hideInlineEditor() {
        inlineEditor.isHidden = true
        inlineEditor.onCommit = nil
        inlineEditor.onCancel = nil
        window?.makeFirstResponder(nil)
        needsLayout = true
    }

    var isInlineEditorVisible: Bool { !inlineEditor.isHidden }

    private func inlineEditorFrame(catRect: CGRect, config: InlineEditorConfig) -> CGRect {
        let guideHeight: CGFloat = config.guide == nil ? 0 : 40
        let height: CGFloat = guideHeight + 40
        let x = (bounds.width - config.width) * 0.5
        let y: CGFloat
        switch config.anchor {
        case .cat:
            y = catRect.minY + catRect.height * 0.28
        case .top:
            y = skyRoom + 4
        }
        return CGRect(x: max(4, x), y: y, width: min(config.width, bounds.width - 8), height: height)
    }

    private func updateChrome() {
        let timerVisible = state.speechKind == .timer && !(state.speech ?? "").isEmpty
        pomodoroButton.isHidden = !timerVisible
        if timerVisible {
            let symbol = state.pomodoroRunning ? "pause.fill" : "play.fill"
            pomodoroButton.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: state.pomodoroRunning ? "Pause pomodoro" : "Resume pomodoro"
            )
            pomodoroButton.contentTintColor = .white
            pomodoroButton.alphaValue = state.pomodoroRunning ? 1 : 0.72
        }
    }

    private func invalidateForStateChange() {
        refreshCatLayers()
        let signature = displaySignature(for: state)
        guard signature != lastDisplaySignature else { return }
        lastDisplaySignature = signature
        updateChrome()  // speech, its kind, and the pomodoro run state are all in the signature
        needsLayout = true
        chromeView.needsDisplay = true
    }

    private func displaySignature(for state: RenderState) -> DisplaySignature {
        DisplaySignature(
            pose: state.pose,
            lifting: isLifting,
            purring: state.purring,
            sleeping: state.sleeping,
            mochiStretch: state.mochiStretchActive,
            heatBucket: Int((state.heat * 32).rounded()),
            jumpLift: Int((state.jumpY * 1000).rounded()),
            showName: state.showName,
            catName: state.catName,
            speech: state.speech,
            speechKind: speechKindIndex(state.speechKind),
            pomodoroMode: state.pomodoroMode.rawValue,
            pomodoroRunning: state.pomodoroRunning,
            thinking: state.thinking,
            openaiCount: state.openaiCount,
            anthropicCount: state.anthropicCount,
            bubbleJump: Int((state.bubbleJumpY * 1000).rounded()),
            jumpSparkle: Int((state.jumpPhase * 48).rounded()),
            editPops: state.editPops.count,
            reactionBadge: state.reactionBadge,
            reactionBadgePhase: Int((state.reactionBadgePhase * 1000).rounded()),
            animatedChromeFrame: animatedChromeFrame(for: state)
        )
    }

    private func animatedChromeFrame(for state: RenderState) -> Int {
        let heatSteamVisible =
            !(state.mochiStretchActive || state.pose == .stretchDefault || state.pose == .stretchStart
            || state.pose == .stretchEnd) && state.heat > 0.5
        guard state.purring || state.thinking || state.sleeping || heatSteamVisible || !state.editPops.isEmpty
        else { return 0 }
        return Int((state.time * Self.animatedChromeFramesPerSecond).rounded())
    }

    private func speechKindIndex(_ kind: SpeechBubbleKind) -> Int {
        switch kind {
        case .notice: return 0
        case .reminder: return 1
        case .timer: return 2
        case .fixed: return 3
        }
    }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        delegate?.petViewHoverChanged(overHead: CatHitTester.isHead(point: point, in: catDrawRect()))
    }


    private func drawParticlesAndChrome(in ctx: CGContext, catRect: CGRect) {
        drawHeatSteam(in: ctx, catRect: catRect)
        if state.purring { drawPurrHearts(in: ctx, catRect: catRect) }
        if state.sleeping { drawSleepZs(in: ctx, catRect: catRect) }
        if state.jumpPhase > 0 { drawJumpSparkles(in: ctx, catRect: catRect) }
        if !state.editPops.isEmpty { drawEditPops(in: ctx, catRect: catRect) }
        if state.showName && !isLifting {
            drawBadge(state.catName, at: CGPoint(x: catRect.midX, y: catRect.maxY - 26))
        }
        let bubbleLift = state.bubbleJumpY * catRect.height
        if let speech = state.speech, !speech.isEmpty {
            _ = drawSpeech(
                speech, kind: state.speechKind, at: CGPoint(x: catRect.midX, y: catRect.minY + 14 - bubbleLift))
        } else if state.thinking {
            drawThinkingDots(in: ctx, catRect: catRect)
        }
        // Drawn last so it sits above the speech bubble, and offset onto the head's upper-right so
        // the two never overlap.
        drawReactionBadge(in: ctx, catRect: catRect)
    }

    /// Sparkle bursts at the apex of each completion hop, riding the cat's jump offset. Stroke-drawn
    /// plus-shaped stars that radiate, shrink, and fade — the hop itself was previously the entire
    /// celebration.
    private func drawJumpSparkles(in ctx: CGContext, catRect: CGRect) {
        let bursts: [CGFloat] = [0.225, 0.648]
        let scale = catRect.width / 50
        let jumpLift = state.jumpY * catRect.height
        ctx.saveGState()
        ctx.setLineCap(.round)
        for (burstIndex, burstStart) in bursts.enumerated() {
            let local = (state.jumpPhase - burstStart) / 0.18
            guard local > 0, local < 1 else { continue }
            let alpha = (1 - local) * 0.95
            ctx.setStrokeColor(NSColor(srgbRed: 0.98, green: 0.78, blue: 0.22, alpha: alpha).cgColor)
            ctx.setLineWidth(max(1.2, 0.9 * scale))
            for i in 0..<6 {
                let angle = CGFloat(i) / 6 * 2 * .pi + (burstIndex == 1 ? 0.45 : 0)
                let dist = (13 + local * 15) * scale
                let cx = catRect.midX + cos(angle) * dist
                let cy = catRect.minY + 14 * scale + sin(angle) * dist * 0.7 - jumpLift
                let r = (2.6 - local * 1.2) * scale
                ctx.beginPath()
                ctx.move(to: CGPoint(x: cx - r, y: cy))
                ctx.addLine(to: CGPoint(x: cx + r, y: cy))
                ctx.move(to: CGPoint(x: cx, y: cy - r))
                ctx.addLine(to: CGPoint(x: cx, y: cy + r))
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    private static let editPopGreen = NSColor(srgbRed: 0.05, green: 0.52, blue: 0.16, alpha: 1)
    private static let editPopRed = NSColor(srgbRed: 0.83, green: 0.15, blue: 0.12, alpha: 1)
    /// Fixed pill font. The pop-in scale is applied through the context transform, never the font
    /// size: minting a transient NSFont per frame races CoreText's async shaping setup and crashed
    /// with a nil-font NSInvalidArgumentException (TAttributes::ApplyFont).
    private static let editPopFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)

    /// FPS damage numbers for agent edits: each `EditPop` is a white rounded pill reading
    /// `project>file +a -r` (`+` green, `-` red, zero counts omitted upstream) launched off the
    /// head at its random 45°–135° angle on a ballistic arc — apex `rise`× the pet square above
    /// the launch point, into the window's reserved sky room — landing back at the launch height,
    /// then fading out in place over `EditPop.fadeDuration`. Horizontal range follows ballistics
    /// (4·apex/tan(angle)) capped at the window edges. Position and envelope derive purely from
    /// `spawnedAt` vs `state.time`; expired pops are pruned by the controller's frame tick.
    private func drawEditPops(in ctx: CGContext, catRect: CGRect) {
        let t = state.time
        let scale = catRect.width / 50
        for pop in state.editPops {
            let q = t - pop.spawnedAt
            guard q > 0 else { continue }
            let landed = max(0, q - pop.flightTime)
            guard landed < EditPop.fadeDuration else { continue }
            // Airborne progress freezes at 1 on landing, so travel stops where the pill lands.
            let f = CGFloat(min(1, q / pop.flightTime))
            let alpha = min(1, CGFloat(q) / 0.08) * (1 - CGFloat(landed / EditPop.fadeDuration))
            guard alpha > 0.01 else { continue }
            let popIn = 0.7 + 0.3 * easeOutBack(min(1, CGFloat(q) / 0.1))

            var segments: [(text: String, color: NSColor)] = [(pop.label, .black)]
            if pop.added > 0 { segments.append((" +\(pop.added)", Self.editPopGreen)) }
            if pop.removed > 0 { segments.append((" -\(pop.removed)", Self.editPopRed)) }
            let rendered = segments.map { segment in
                NSAttributedString(
                    string: segment.text,
                    attributes: [.font: Self.editPopFont, .foregroundColor: segment.color.withAlphaComponent(alpha)])
            }
            let widths = rendered.map { $0.size().width }
            let textWidth = widths.reduce(0, +)
            let textHeight = rendered[0].size().height
            let padX: CGFloat = 6
            let padY: CGFloat = 2.5
            let pillWidth = textWidth + padX * 2
            let pillHeight = textHeight + padY * 2
            // Launch at the chin (just below the sparkles/speech band); the parabola peaks at
            // mid-flight, `rise` pet-squares above the launch point, and lands back at the launch
            // height for the fade. The ceiling clamp is a safety net for tiny windows only.
            let apex = pop.rise * catRect.height
            let fullRange = 4 * apex * cos(pop.angle) / sin(pop.angle)
            let rangeCap =
                fullRange >= 0
                ? bounds.maxX - pillWidth / 2 - 2 - catRect.midX
                : bounds.minX + pillWidth / 2 + 2 - catRect.midX
            let range = fullRange >= 0 ? min(fullRange, rangeCap) : max(fullRange, rangeCap)
            let centerX = catRect.midX + range * f
            let spawnY = catRect.minY + 20 * scale
            let ceilingY = bounds.minY + pillHeight / 2 + 2
            let arc = 4 * f * (1 - f)
            let centerY = max(ceilingY, spawnY - arc * apex)
            let pill = CGRect(
                x: centerX - pillWidth / 2, y: centerY - pillHeight / 2,
                width: pillWidth, height: pillHeight)
            ctx.saveGState()
            ctx.translateBy(x: centerX, y: centerY)
            ctx.scaleBy(x: popIn, y: popIn)
            ctx.translateBy(x: -centerX, y: -centerY)
            NSColor.white.withAlphaComponent(0.93 * alpha).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
            var cursorX = pill.minX + padX
            for (run, width) in zip(rendered, widths) {
                run.draw(at: CGPoint(x: cursorX, y: pill.minY + padY))
                cursorX += width
            }
            ctx.restoreGState()
        }
    }

    /// Affection hearts while the cursor pets the head: staggered phases, a fade-in/out envelope,
    /// and per-heart size/sway variance, drawn as bezier hearts so they match the line-art chrome
    /// (the old version floated four lock-step system-font ♥ that popped on loop reset).
    private func drawPurrHearts(in ctx: CGContext, catRect: CGRect) {
        let t = CGFloat(state.time)
        let scale = catRect.width / 50
        let period: CGFloat = 1.7
        let delays: [CGFloat] = [0, 0.6, 1.0, 1.35]
        let lefts: [CGFloat] = [-0.28, -0.06, 0.16, 0.34]
        let sizes: [CGFloat] = [7, 9, 6.5, 8]
        ctx.saveGState()
        for i in 0..<4 {
            let raw = (t - delays[i]).truncatingRemainder(dividingBy: period)
            let p = (raw < 0 ? raw + period : raw) / period
            let fadeIn = min(1, p / 0.18)
            let fadeOut = p > 0.7 ? max(0, 1 - (p - 0.7) / 0.3) : 1
            let alpha = 0.85 * fadeIn * fadeOut
            guard alpha > 0.01 else { continue }
            let size = sizes[i] * scale * (0.8 + 0.35 * p)
            let x = catRect.midX + lefts[i] * catRect.width + sin(t * 2.1 + CGFloat(i) * 1.7) * 2.4 * scale
            let y = catRect.minY + 14 * scale - p * 11 * scale
            ctx.setFillColor(NSColor.systemPink.withAlphaComponent(alpha).cgColor)
            ctx.addPath(Self.heartPath(center: CGPoint(x: x, y: y), size: size))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Classic two-lobe heart in this flipped (y-down) view, centered on `center`; `size` is
    /// roughly the overall width.
    private static func heartPath(center: CGPoint, size s: CGFloat) -> CGPath {
        let path = CGMutablePath()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: center.x + x * s, y: center.y + y * s) }
        path.move(to: pt(0, 0.38))
        path.addCurve(to: pt(-0.5, -0.1), control1: pt(-0.3, 0.18), control2: pt(-0.5, 0.08))
        path.addCurve(to: pt(0, -0.12), control1: pt(-0.5, -0.42), control2: pt(-0.06, -0.42))
        path.addCurve(to: pt(0.5, -0.1), control1: pt(0.06, -0.42), control2: pt(0.5, -0.42))
        path.addCurve(to: pt(0, 0.38), control1: pt(0.5, 0.08), control2: pt(0.3, 0.18))
        path.closeSubpath()
        return path
    }

    /// Floating "z z Z" while the cat naps: stroke-drawn z glyphs that rise, grow, and fade above
    /// the head's upper-right, staggered like the heat steam so the loop reset never pops.
    private func drawSleepZs(in ctx: CGContext, catRect: CGRect) {
        let t = CGFloat(state.time)
        let scale = catRect.width / 50
        let period: CGFloat = 3.0
        let delays: [CGFloat] = [0, 1.0, 2.0]
        let ink = NSColor(srgbRed: 0.30, green: 0.34, blue: 0.46, alpha: 1)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for i in 0..<3 {
            let raw = (t - delays[i]).truncatingRemainder(dividingBy: period)
            let p = (raw < 0 ? raw + period : raw) / period
            let fadeIn = min(1, p / 0.15)
            let fadeOut = p > 0.65 ? max(0, 1 - (p - 0.65) / 0.35) : 1
            let alpha = 0.8 * fadeIn * fadeOut
            guard alpha > 0.01 else { continue }
            let size = (3.2 + 3.4 * p) * scale
            let x = catRect.midX + catRect.width * 0.27 + sin(t * 1.3 + CGFloat(i) * 2.1) * 1.8 * scale + p * 4 * scale
            let y = catRect.minY + 13 * scale - p * 11 * scale
            ctx.setStrokeColor(ink.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(max(1.2, 0.16 * size))
            let half = size / 2
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x - half, y: y - half))
            ctx.addLine(to: CGPoint(x: x + half, y: y - half))
            ctx.addLine(to: CGPoint(x: x - half, y: y + half))
            ctx.addLine(to: CGPoint(x: x + half, y: y + half))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawReactionBadge(in ctx: CGContext, catRect: CGRect) {
        let badge = state.reactionBadge
        guard badge != .none else { return }
        let p = max(0, min(1, state.reactionBadgePhase))
        guard p > 0, p < 1 else { return }
        // Pop in with overshoot, hold, then fade the pill out; a gentle rise-and-settle bob throughout.
        let popIn = min(p / 0.16, 1)
        let scale = 0.6 + 0.4 * easeOutBack(popIn)
        let alpha: CGFloat = p > 0.75 ? max(0, 1 - (p - 0.75) / 0.25) : 1
        let bob = -10 * sin(p * .pi)
        let glyphHeight: CGFloat = 26 * scale
        let glyphWidth = glyphHeight * (badge == .plan ? 0.78 : 0.62)
        let pad: CGFloat = 8
        let box = CGRect(
            x: catRect.midX + catRect.width * 0.34 - (glyphWidth + pad * 2) / 2,
            y: catRect.minY + catRect.height * 0.38 + bob,
            width: glyphWidth + pad * 2, height: glyphHeight + pad)
        NSColor.white.withAlphaComponent(0.92 * alpha).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        drawBadgeGlyph(badge, in: ctx, center: CGPoint(x: box.midX, y: box.midY), height: glyphHeight, alpha: alpha)
    }

    /// Stroke-drawn replacements for the old ❓/📋/❗ emoji so the badge matches the cat's
    /// line-art style: an amber question hook, a red exclamation, a slate-blue clipboard.
    private func drawBadgeGlyph(
        _ badge: ReactionBadge, in ctx: CGContext, center: CGPoint, height h: CGFloat, alpha: CGFloat
    ) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: center.x + x * h, y: center.y + y * h) }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(max(1.6, h * 0.13))
        switch badge {
        case .ask:
            let color = NSColor.systemOrange.withAlphaComponent(alpha)
            ctx.setStrokeColor(color.cgColor)
            ctx.beginPath()
            ctx.move(to: pt(-0.17, -0.16))
            ctx.addCurve(to: pt(0.17, -0.16), control1: pt(-0.17, -0.44), control2: pt(0.17, -0.44))
            ctx.addCurve(to: pt(0, 0.06), control1: pt(0.17, 0), control2: pt(0, -0.04))
            ctx.addLine(to: pt(0, 0.14))
            ctx.strokePath()
            ctx.setFillColor(color.cgColor)
            fillDot(at: pt(0, 0.36), radius: h * 0.075, ctx: ctx)
        case .error:
            let color = NSColor.systemRed.withAlphaComponent(alpha)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(max(2, h * 0.16))
            ctx.beginPath()
            ctx.move(to: pt(0, -0.38))
            ctx.addLine(to: pt(0, 0.1))
            ctx.strokePath()
            ctx.setFillColor(color.cgColor)
            fillDot(at: pt(0, 0.36), radius: h * 0.085, ctx: ctx)
        case .plan:
            let color = NSColor(srgbRed: 0.36, green: 0.44, blue: 0.66, alpha: alpha)
            ctx.setStrokeColor(color.cgColor)
            let board = CGRect(
                x: center.x - 0.26 * h, y: center.y - 0.3 * h, width: 0.52 * h, height: 0.7 * h)
            ctx.addPath(CGPath(roundedRect: board, cornerWidth: 0.07 * h, cornerHeight: 0.07 * h, transform: nil))
            ctx.strokePath()
            ctx.setFillColor(color.cgColor)
            let tab = CGRect(x: center.x - 0.11 * h, y: center.y - 0.38 * h, width: 0.22 * h, height: 0.13 * h)
            ctx.addPath(CGPath(roundedRect: tab, cornerWidth: 0.04 * h, cornerHeight: 0.04 * h, transform: nil))
            ctx.fillPath()
            ctx.setLineWidth(max(1.4, h * 0.09))
            ctx.beginPath()
            ctx.move(to: pt(-0.13, -0.05))
            ctx.addLine(to: pt(0.13, -0.05))
            ctx.move(to: pt(-0.13, 0.16))
            ctx.addLine(to: pt(0.13, 0.16))
            ctx.strokePath()
        case .none:
            break
        }
        ctx.restoreGState()
    }

    private func fillDot(at point: CGPoint, radius: CGFloat, ctx: CGContext) {
        ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    private func easeOutBack(_ t: CGFloat) -> CGFloat {
        let x = t - 1
        return 1 + 2.70158 * x * x * x + 1.70158 * x * x
    }

    private func drawHeatSteam(in ctx: CGContext, catRect: CGRect) {
        guard
            !(state.mochiStretchActive || state.pose == .stretchDefault || state.pose == .stretchStart
                || state.pose == .stretchEnd)
        else { return }
        let baseOpacity = min(1, max(0, (state.heat - 0.5) * 2))
        guard baseOpacity > 0 else { return }
        let t = CGFloat(state.time)
        let scale = catRect.width / 50
        let period: CGFloat = 2
        // Five staggered puff columns, each phase-offset so the steam rises continuously.
        let lefts: [CGFloat] = [32, 47, 62, 39, 55]
        let delays: [CGFloat] = [0, 0.4, 0.8, 1.2, 1.6]
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(max(1.5, scale * 0.9))
        let red = NSColor(srgbRed: 255 / 255, green: 69 / 255, blue: 56 / 255, alpha: 1)
        for i in 0..<5 {
            let raw = (t - delays[i]).truncatingRemainder(dividingBy: period)
            let p = (raw < 0 ? raw + period : raw) / period
            // Fade opacity to 0 near the top of each rise so the loop reset doesn't pop.
            let fade = p < 0.85 ? 1 : max(0, 1 - (p - 0.85) / 0.15)
            let alpha = baseOpacity * fade
            guard alpha > 0.01 else { continue }
            let x = catRect.minX + lefts[i] / 100 * catRect.width + sin(t * 3 + CGFloat(i)) * scale
            let baseY = catRect.minY + 14 * scale
            let rise = p * 18 * scale
            ctx.setStrokeColor(red.withAlphaComponent(alpha).cgColor)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x, y: baseY - rise))
            ctx.addCurve(
                to: CGPoint(x: x + 1.5 * scale, y: baseY - (6 * scale) - rise),
                control1: CGPoint(x: x - 3 * scale, y: baseY - 2 * scale - rise),
                control2: CGPoint(x: x + 4 * scale, y: baseY - 4 * scale - rise))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private struct ProviderBadgeSegment {
        let text: NSAttributedString
        let textSize: CGSize
        let logo: NSImage
        let logoWidth: CGFloat
    }

    private static let openaiLogo = loadLogo(named: "openai")
    private static let anthropicLogo = loadLogo(named: "anthropic")

    private static func loadLogo(named name: String) -> NSImage? {
        guard
            let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "logos")
                ?? Bundle.main.url(forResource: name, withExtension: "png")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    /// One `<count><logo>` chunk per running vendor, OpenAI first then Anthropic. A zero count
    /// (or a logo that failed to load) is omitted so the bubble only advertises live vendors.
    private func providerBadgeSegments(
        logoHeight: CGFloat, attributes: [NSAttributedString.Key: Any]
    ) -> [ProviderBadgeSegment] {
        var segments: [ProviderBadgeSegment] = []
        func append(count: Int, logo: NSImage?) {
            guard count > 0, let logo, logo.size.height > 0 else { return }
            let text = NSAttributedString(string: count > 99 ? "99+" : "\(count)", attributes: attributes)
            let width = logoHeight * logo.size.width / logo.size.height
            segments.append(ProviderBadgeSegment(text: text, textSize: text.size(), logo: logo, logoWidth: width))
        }
        append(count: state.openaiCount, logo: Self.openaiLogo)
        append(count: state.anthropicCount, logo: Self.anthropicLogo)
        return segments
    }

    private func drawThinkingDots(in ctx: CGContext, catRect: CGRect) {
        // Real typing hides the dots (the cat is busy at the keyboard); the thinking-time kneading
        // animates the idle pose's paws, so it no longer needs a press-pose carve-out here.
        guard state.pose != .pressLeft, state.pose != .pressRight else { return }
        guard state.pose != .scroll,
            state.pose != .stretchStart, state.pose != .stretchEnd, state.pose != .stretchDefault,
            !state.mochiStretchActive
        else { return }
        let dotSize: CGFloat = 5
        let gap: CGFloat = 4
        let padX: CGFloat = 5
        let padY: CGFloat = 5
        let dotsWidth = dotSize * 3 + gap * 2
        let logoHeight: CGFloat = 13
        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 9), .foregroundColor: NSColor.black,
        ]
        let segments = providerBadgeSegments(logoHeight: logoHeight, attributes: countAttrs)
        let segmentLeadGap: CGFloat = 6
        let numberLogoGap: CGFloat = 2
        var segmentsWidth: CGFloat = 0
        for seg in segments { segmentsWidth += segmentLeadGap + seg.textSize.width + numberLogoGap + seg.logoWidth }
        let boxWidth = padX * 2 + dotsWidth + segmentsWidth
        let boxHeight = dotSize + padY * 2
        // Anchored left of the head, near the top of the cat rect.
        let box = CGRect(
            x: catRect.midX - catRect.width * 0.39 - 19, y: catRect.minY, width: boxWidth, height: boxHeight)
        ctx.saveGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.fill(box)
        let t = CGFloat(state.time)
        let period: CGFloat = 1.05
        let phases: [CGFloat] = [0, 0.16, 0.32]
        for i in 0..<3 {
            let raw = (t - phases[i]).truncatingRemainder(dividingBy: period)
            let p = (raw < 0 ? raw + period : raw) / period
            // opacity ramp 0.25 -> 1 -> 0.45 (@keyframes thinking-dot); bob translateY(-2px) at peak.
            let opacity = p < 0.5 ? 0.25 + 0.75 * (p / 0.5) : 1 - 0.55 * ((p - 0.5) / 0.5)
            let bob = -2 * (p < 0.5 ? p / 0.5 : (1 - p) / 0.5)
            let dx = box.minX + padX + CGFloat(i) * (dotSize + gap)
            let dy = box.minY + padY + bob
            ctx.setFillColor(NSColor.black.withAlphaComponent(opacity).cgColor)
            ctx.fill(CGRect(x: dx, y: dy, width: dotSize, height: dotSize))
        }
        var cursorX = box.minX + padX + dotsWidth
        for seg in segments {
            cursorX += segmentLeadGap
            seg.text.draw(at: CGPoint(x: cursorX, y: box.midY - seg.textSize.height / 2))
            cursorX += seg.textSize.width + numberLogoGap
            seg.logo.draw(
                in: CGRect(x: cursorX, y: box.midY - logoHeight / 2, width: seg.logoWidth, height: logoHeight),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            cursorX += seg.logoWidth
        }
        ctx.restoreGState()
    }

    private func drawBadge(_ text: String, at point: CGPoint) {
        let attr = NSAttributedString(
            string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.black])
        let size = attr.size()
        let rect = CGRect(x: point.x - size.width / 2 - 8, y: point.y, width: size.width + 16, height: 22)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        attr.draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 3))
    }

    private func drawSpeech(_ text: String, kind: SpeechBubbleKind, at point: CGPoint) -> CGRect {
        let rect = speechRect(for: text, kind: kind, at: point)
        switch kind {
        case .timer:
            let background =
                state.pomodoroMode == .focus
                ? NSColor.systemRed.withAlphaComponent(state.pomodoroRunning ? 0.92 : 0.72)
                : NSColor.systemGreen.withAlphaComponent(state.pomodoroRunning ? 0.92 : 0.72)
            background.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 0, yRadius: 0).fill()
            let attr = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white,
                ])
            attr.draw(at: CGPoint(x: rect.minX + 9, y: rect.minY + 6))
        case .notice, .reminder, .fixed:
            let attr = NSAttributedString(
                string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
            NSColor.white.withAlphaComponent(kind == .reminder ? 0.98 : 0.95).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            attr.draw(with: rect.insetBy(dx: 9, dy: 7), options: [.usesLineFragmentOrigin])
        }
        return rect
    }

    private func currentSpeechRect(catRect: CGRect) -> CGRect? {
        guard let speech = state.speech, !speech.isEmpty else { return nil }
        return speechRect(for: speech, kind: state.speechKind, at: CGPoint(x: catRect.midX, y: catRect.minY + 14))
    }

    private func speechRect(for text: String, kind: SpeechBubbleKind, at point: CGPoint) -> CGRect {
        switch kind {
        case .timer:
            let attr = NSAttributedString(
                string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)])
            let size = attr.size()
            let width = size.width + 42
            let height = max(28, size.height + 12)
            return CGRect(x: point.x - width / 2, y: point.y, width: width, height: height)
        case .notice, .reminder, .fixed:
            let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
            let maxWidth: CGFloat = 260
            let box = attr.boundingRect(with: CGSize(width: maxWidth, height: 100), options: [.usesLineFragmentOrigin])
            let width = min(maxWidth, box.width + 18)
            return CGRect(x: point.x - width / 2, y: point.y, width: width, height: box.height + 14)
        }
    }

    private func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor) {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
            .draw(at: point)
    }
}
