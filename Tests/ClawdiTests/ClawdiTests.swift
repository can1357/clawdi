import AppKit
@preconcurrency import Network
import XCTest

@testable import Clawdi

final class ClawdiTests: XCTestCase {
    private func phase4Reminder(
        id: String = "reminder",
        time: String,
        message: String,
        repeatRule: ReminderRepeat = .none,
        days: [Int] = [],
        enabled: Bool = true,
        lastTriggeredDate: String? = nil
    ) -> Reminder {
        Reminder(
            id: id,
            time: time,
            message: message,
            repeatRule: repeatRule,
            days: days,
            enabled: enabled,
            lastTriggeredDate: lastTriggeredDate,
            createdAt: "2026-06-01T00:00:00Z"
        )
    }

    func testResourcesLoad() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        XCTAssertEqual(poses.poses.count, 10)
        XCTAssertNotNil(poses.poses[PetPose.sleepCurl.rawValue])
        let mappings = try CellMappings.load(bundle: Bundle.main)
        XCTAssertGreaterThanOrEqual(mappings.mappings.count, 68)
        XCTAssertNotNil(mappings.pixels(svgName: "cat-idle-follow-v2", elementId: "head", cellX: 0, cellY: 0))
        XCTAssertNotNil(mappings.pixels(svgName: "sleep-curl", elementId: "head", cellX: 0, cellY: 0))
        for logo in ["openai", "anthropic"] {
            XCTAssertNotNil(
                Bundle.main.url(forResource: logo, withExtension: "png", subdirectory: "logos")
                    ?? Bundle.main.url(forResource: logo, withExtension: "png"),
                "missing bundled \(logo) logo")
        }
    }

    func testPoseLayerPlanBuildsIdleLayerOrder() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let pose = poses.pose(named: PetPose.idle.rawValue)
        let plan = PoseLayerPlan.build(pose: pose, scale: 1, viewBox: pose.viewBoxRect)
        let defaultIDs = plan.slots.filter { $0.visibility.includes(RenderState()) }.map(\.id)

        XCTAssertEqual(
            defaultIDs,
            [
                "tail", "body", "leg-fl", "leg-fr", "whiskers", "ear-left", "ear-right",
                "head", "eye-left", "pupil-left", "eye-right", "pupil-right",
            ])
        XCTAssertEqual(plan.hoistedBreatheIndexPath, [1, 0])
        XCTAssertTrue(plan.slots.first { $0.id == "body" }?.part == .body)
        XCTAssertFalse(plan.slots.first { $0.id == "pupil-left" }?.silhouette ?? true)
    }

    func testPoseLayerPlanClassifiesPurringVisibility() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let pose = poses.pose(named: PetPose.idle.rawValue)
        let plan = PoseLayerPlan.build(pose: pose, scale: 1, viewBox: pose.viewBoxRect)
        var purring = RenderState()
        purring.purring = true
        let purringIDs = plan.slots.filter { $0.visibility.includes(purring) }.map(\.id)

        XCTAssertFalse(purringIDs.contains("eye-left"))
        XCTAssertFalse(purringIDs.contains("pupil-left"))
        XCTAssertTrue(purringIDs.contains("closed-eye-line-left"))
        XCTAssertTrue(purringIDs.contains("closed-eye-line-right"))
    }

    func testPoseLayerPlanClosesEyesWhileSleeping() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let pose = poses.pose(named: PetPose.idle.rawValue)
        let plan = PoseLayerPlan.build(pose: pose, scale: 1, viewBox: pose.viewBoxRect)
        var sleeping = RenderState()
        sleeping.sleeping = true
        let sleepingIDs = plan.slots.filter { $0.visibility.includes(sleeping) }.map(\.id)

        XCTAssertFalse(sleepingIDs.contains("eye-left"))
        XCTAssertFalse(sleepingIDs.contains("pupil-right"))
        XCTAssertTrue(sleepingIDs.contains("closed-eye-line-left"))
        XCTAssertTrue(sleepingIDs.contains("closed-eye-line-right"))
    }

    func testLayeredCompositorMatchesMonolithicAffinePoses() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let presetStore = PresetStore(
            bundle: Bundle.main,
            customURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        )
        let brownTabby = try XCTUnwrap(presetStore.builtIns.first { $0.id == "brown-tabby" })

        var tracked = RenderState()
        tracked.time = 1.25
        tracked.tracking.body = CGPoint(x: 0.5, y: -0.25)
        tracked.tracking.face = CGPoint(x: 1.25, y: -0.75)
        tracked.tracking.eyes = CGPoint(x: 0.5, y: -0.375)
        tracked.tracking.pupils = CGPoint(x: 1.25, y: -1)

        var purring = tracked
        purring.purring = true
        purring.purrFaceOffset = CGPoint(x: 0.5, y: -0.25)

        var hunting = tracked
        hunting.hunting = true
        hunting.huntingEnter = 1

        var huntingReturn = tracked
        huntingReturn.huntingReturn = true
        huntingReturn.huntingReturnProgress = 0.4

        var pressLeft = RenderState()
        pressLeft.pose = .pressLeft
        pressLeft.time = 0.9

        var pressRight = pressLeft
        pressRight.pose = .pressRight

        var jumpStart = RenderState()
        jumpStart.pose = .jumpStart
        jumpStart.time = 0.12

        var jumpIng = RenderState()
        jumpIng.pose = .jumpIng
        jumpIng.time = 0.18

        var stretchDefault = RenderState()
        stretchDefault.pose = .stretchDefault
        stretchDefault.time = 0.54
        stretchDefault.stretchPoseProgress = 0.6

        var patterned = tracked
        patterned.pattern = brownTabby.pattern

        var heated = patterned
        heated.heat = 0.8
        heated.stretchingHeat = 0.5

        var sleeping = tracked
        sleeping.sleeping = true

        var thinkingTail = tracked
        thinkingTail.thinking = true

        var askFlourish = tracked
        askFlourish.flourish = .askEars
        askFlourish.flourishPhase = 0.15

        var errorFlourish = tracked
        errorFlourish.flourish = .errorEars
        errorFlourish.flourishPhase = 0.5

        var sleepCurl = RenderState()
        sleepCurl.pose = .sleepCurl
        sleepCurl.sleeping = true
        sleepCurl.time = 0.42

        let cases: [(String, RenderState)] = [
            ("idle rest", RenderState()),
            ("tracked idle", tracked),
            ("purring", purring),
            ("sleeping", sleeping),
            ("thinking tail", thinkingTail),
            ("ask flourish", askFlourish),
            ("error flourish", errorFlourish),
            ("sleep curl", sleepCurl),
            ("hunting", hunting),
            ("hunting return", huntingReturn),
            ("press left", pressLeft),
            ("press right", pressRight),
            ("jump start", jumpStart),
            ("jump ing", jumpIng),
            ("stretch default", stretchDefault),
            ("brown tabby", patterned),
            ("heated brown tabby", heated),
        ]

        for scale in [CGFloat(1), CGFloat(8)] {
            for (name, state) in cases {
                try assertLayeredMatchesMonolithic(
                    poses: poses,
                    mappings: mappings,
                    state: state,
                    scale: scale,
                    label: "\(name) @\(Int(scale))x"
                )
            }
        }
    }

    func testLayerCachesReuseAndInvalidateVisualInputs() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)

        var state = RenderState()
        state.time = 0.1
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        let initialMisses = compositor.cacheStats.layerRasterMisses
        XCTAssertGreaterThan(initialMisses, 0)

        state.time = 0.35
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertGreaterThan(compositor.cacheStats.layerRasterHits, 0)

        let missesBeforeColor = compositor.cacheStats.layerRasterMisses
        state.time = 0.6
        state.pattern.baseColor = "#222222"
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertGreaterThan(compositor.cacheStats.layerRasterMisses, missesBeforeColor)

        let missesBeforeHeat = compositor.cacheStats.layerRasterMisses
        state.time = 0.85
        state.heat = 0.5
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertGreaterThan(compositor.cacheStats.layerRasterMisses, missesBeforeHeat)

        let missesBeforeVisibility = compositor.cacheStats.layerRasterMisses
        state.time = 1.1
        state.purring = true
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertGreaterThan(compositor.cacheStats.layerRasterMisses, missesBeforeVisibility)

        let missesBeforeScale = compositor.cacheStats.layerRasterMisses
        state.time = 1.35
        XCTAssertNotNil(compositor.render(state: state, scale: 7))
        XCTAssertGreaterThan(compositor.cacheStats.layerRasterMisses, missesBeforeScale)
    }

    func testFrameAndOutlineCachesReuseStableImages() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)

        var state = RenderState()
        state.time = 0.2
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertEqual(compositor.cacheStats.frameHits, 1)

        let outlineHitsBefore = compositor.cacheStats.outlineHits
        state.pattern.eyeColor = "#333333"
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertGreaterThan(compositor.cacheStats.outlineHits, outlineHitsBefore)
    }

    func testMonolithicCompositorCachesFramesAndOutlineUnderlays() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        compositor.forceMonolithic = true

        var state = RenderState()
        state.time = 0.2
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertEqual(compositor.cacheStats.frameHits, 1)

        let outlineHitsBefore = compositor.cacheStats.outlineHits
        state.pattern.eyeColor = "#333333"
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertGreaterThan(compositor.cacheStats.outlineHits, outlineHitsBefore)
    }

    func testOutlineUnderlayTracksFlowerFaceMovement() throws {
        let poses = try PoseLibrary.load(bundle: .main, resource: "flower-poses")
        let mappings = try CellMappings.load(bundle: .main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        compositor.forceMonolithic = true
        compositor.skipUserPatches = true

        var state = RenderState()
        state.time = 0.2
        XCTAssertNotNil(compositor.render(state: state, scale: 8))

        let missesBefore = compositor.cacheStats.outlineMisses
        state.tracking.face = CGPoint(x: 2, y: 0)
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertGreaterThan(compositor.cacheStats.outlineMisses, missesBefore)
    }

    func testOutlineUnderlayCoalescesSubpixelCursorTracking() throws {
        let poses = try PoseLibrary.load(bundle: .main, resource: "flower-poses")
        let mappings = try CellMappings.load(bundle: .main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        compositor.forceMonolithic = true
        compositor.skipUserPatches = true

        var state = RenderState()
        state.time = 0.2
        XCTAssertNotNil(compositor.render(state: state, scale: 8))

        let outlineHitsBefore = compositor.cacheStats.outlineHits
        state.tracking.face = CGPoint(x: 0.1, y: 0)
        state.tracking.eyes = CGPoint(x: 1, y: 0)
        state.tracking.pupils = CGPoint(x: 1, y: 0)
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertGreaterThan(compositor.cacheStats.outlineHits, outlineHitsBefore)
    }

    func testScrollUnrollReusesCachedFramesWithoutFreezingTheAnimation() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)

        var state = RenderState()
        state.pose = .scroll
        state.time = 0.1
        state.scrollProgress = ScrollReaction.progress(startedAt: 0, now: 0.05)
        let early = try XCTUnwrap(compositor.render(state: state, scale: 8))
        // A later gesture replaying the same step (at a different clock time) hits the cache.
        state.time = 7.3
        XCTAssertTrue(compositor.render(state: state, scale: 8) === early)

        state.scrollProgress = ScrollReaction.progress(startedAt: 0, now: 0.2)
        let late = try XCTUnwrap(compositor.render(state: state, scale: 8))
        XCTAssertNotEqual(early.dataProvider?.data, late.dataProvider?.data, "the paper must keep unrolling")
    }

    func testStretchDefaultFrameCacheIgnoresCursorTracking() throws {
        let poses = try PoseLibrary.load(bundle: .main, resource: "flower-poses")
        let mappings = try CellMappings.load(bundle: .main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        compositor.skipUserPatches = true

        var state = RenderState()
        state.pose = .stretchDefault
        state.time = 0.5
        state.stretchPoseProgress = 0.6
        XCTAssertNotNil(compositor.render(state: state, scale: 8))

        state.tracking.face = CGPoint(x: 2, y: 1)
        state.tracking.eyes = CGPoint(x: 1, y: 0.5)
        state.tracking.pupils = CGPoint(x: 1.5, y: 1)
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertEqual(compositor.cacheStats.frameHits, 1)
    }

    func testIdleAnimationFrameCacheQuantizes120HzTicks() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)

        for index in 0..<120 {
            var state = RenderState()
            state.time = Double(index) / 120
            XCTAssertNotNil(compositor.render(state: state, scale: 8))
        }

        XCTAssertGreaterThan(compositor.cacheStats.frameHits, 80)
    }

    /// Mirrors PetView's invalidation loop: computes the frame key at 120 Hz and renders only when
    /// the key changes, exactly like `invalidateForStateChange` -> `draw`.
    private struct ChurnReport {
        var ticks = 0
        var renders = 0
        var renderWall: TimeInterval = 0
        var uniqueKeys: Set<FrameKey> = []
    }

    private func simulateFrameLoop(
        compositor: PixelCompositor, scale: CGFloat, seconds: Double, thinking: Bool,
        kneading: Bool = false, startAt: Double = 0, report: inout ChurnReport
    ) {
        let hz = 120.0
        var lastKey: FrameKey?
        for tick in 0..<Int(seconds * hz) {
            var state = RenderState()
            state.time = startAt + Double(tick) / hz
            state.thinking = thinking
            state.kneadPhase = kneading ? 1 : 0
            let key = compositor.renderFrameKey(state: state, scale: scale)
            report.ticks += 1
            report.uniqueKeys.insert(key)
            guard key != lastKey else { continue }
            lastKey = key
            let start = CFAbsoluteTimeGetCurrent()
            _ = compositor.render(state: state, scale: scale)
            report.renderWall += CFAbsoluteTimeGetCurrent() - start
            report.renders += 1
        }
    }

    /// Diagnostic harness and regression net: runs consecutive idle/thinking windows at live
    /// geometry and asserts the compositor reaches a warm steady state — layer rasters must
    /// stop missing after the first window (empty rasters cache too), and recomposites forced
    /// by fresh frame keys must not re-rasterize any layer. Timing prints are local profiling
    /// output, not assertions.
    @MainActor
    func testCompositorSteadyStateCacheChurnReport() throws {
        let mappings = try CellMappings.load(bundle: .main)
        let scenarios: [(label: String, resource: String?, thinking: Bool, kneading: Bool)] = [
            ("cat-idle", nil, false, false),
            ("flower-idle", "flower-poses", false, false),
            ("flower-thinking", "flower-poses", true, false),
            ("flower-knead", "flower-poses", true, true),
        ]
        let windowSeconds = 50.0
        let windowCount = 4

        for scenario in scenarios {
            let library: PoseLibrary
            if let resource = scenario.resource {
                library = try PoseLibrary.load(bundle: .main, resource: resource)
            } else {
                library = try PoseLibrary.load(bundle: .main)
            }
            let compositor = PixelCompositor(library: library, mappings: mappings)
            if scenario.resource != nil {
                compositor.skipUserPatches = true
                compositor.usesMochiLift = false
            }

            // Live geometry: settings petSize drives the window and resting square, and the
            // view derives the supersample scale from them (backing 2x like a Retina display).
            let petSize = 40
            let view = PetView(
                frame: CGRect(origin: .zero, size: WindowGeometry.windowSize(petSize: petSize)),
                compositor: compositor, state: RenderState())
            view.restingHeight = WindowGeometry.restingHeight(petSize: petSize)
            let scale = view.renderScale(for: view.catDrawRect(), backingScale: 2)

            let pose = library.pose(named: PetPose.idle.rawValue)
            let plan = PoseLayerPlan.build(pose: pose, scale: scale, viewBox: pose.viewBoxRect)
            print(
                "[churn] \(scenario.label) scale=\(String(format: "%.2f", scale)) idleSlots=\(plan.slots.count) ids=\(plan.slots.map(\.id))"
            )

            var report = ChurnReport()
            var last = compositor.cacheStats
            for window in 0..<windowCount {
                simulateFrameLoop(
                    compositor: compositor, scale: scale, seconds: windowSeconds,
                    thinking: scenario.thinking, kneading: scenario.kneading,
                    startAt: Double(window) * windowSeconds, report: &report)
                let stats = compositor.cacheStats
                let layerMisses = stats.layerRasterMisses - last.layerRasterMisses
                print(
                    "[churn]   w\(window): keys=\(report.uniqueKeys.count) frameMiss=\(stats.frameMisses - last.frameMisses) outlineMiss=\(stats.outlineMisses - last.outlineMisses) layerMiss=\(layerMisses) wall=\(String(format: "%.0f", report.renderWall * 1000))ms renders=\(report.renders)"
                )
                if window > 0 {
                    XCTAssertEqual(
                        layerMisses, 0,
                        "\(scenario.label) w\(window): steady-state layer rasters must all be cached")
                }
                last = stats
                report.renderWall = 0
            }

            // Fresh-frame-key probe: force recomposites whose frame keys were never rendered
            // while the layer inputs stay identical. Every layer lookup must hit — including
            // slots that rasterize to empty; a nonzero delta reproduces the flower-skin bug
            // where transparent rasters were never cached and re-rasterized every frame.
            let layerMissesBeforeProbe = compositor.cacheStats.layerRasterMisses
            var probeTime = 987_654.321
            var forced = 0
            var attempts = 0
            while forced < 2 && attempts < 4000 {
                attempts += 1
                var state = RenderState()
                state.time = probeTime
                state.thinking = scenario.thinking
                state.kneadPhase = scenario.kneading ? 1 : 0
                probeTime += 0.371
                let key = compositor.renderFrameKey(state: state, scale: scale)
                guard report.uniqueKeys.insert(key).inserted else { continue }
                _ = compositor.render(state: state, scale: scale)
                forced += 1
            }
            let probeLayerMisses = compositor.cacheStats.layerRasterMisses - layerMissesBeforeProbe
            print("[churn]   probe: forcedRenders=\(forced) layerMissDelta=\(probeLayerMisses)")
            XCTAssertEqual(forced, 2, "\(scenario.label): probe could not force fresh frame keys")
            XCTAssertEqual(
                probeLayerMisses, 0,
                "\(scenario.label): a recomposite with unchanged layer inputs re-rasterized a layer")

            XCTAssertGreaterThan(report.renders, 0, "\(scenario.label): harness produced no renders")
        }
    }

    /// The GPU layer tree must assemble the same picture as the CPU compositor: same slots,
    /// same blit transforms, same per-slot outline union, same breathe transform. Renders the
    /// tree offscreen in device space and diffs it against `render(state:scale:)`. Offscreen
    /// CALayer rendering may resolve contents with either vertical parity, so the diff takes
    /// the better of the two orientations; a real regression (missing slot, wrong transform,
    /// broken outline) blows past the tolerance in both.
    @MainActor
    func testCatLayerTreeMatchesCompositorComposite() throws {
        let mappings = try CellMappings.load(bundle: .main)
        for resource in [String?.none, "flower-poses"] {
            let library: PoseLibrary
            if let resource {
                library = try PoseLibrary.load(bundle: .main, resource: resource)
            } else {
                library = try PoseLibrary.load(bundle: .main)
            }
            let compositor = PixelCompositor(library: library, mappings: mappings)
            if resource != nil {
                compositor.skipUserPatches = true
                compositor.usesMochiLift = false
            }
            let tree = CatLayerTree(compositor: compositor)
            let label = resource ?? "cat"

            var rest = RenderState()
            rest.time = 0.2
            var tracked = rest
            tracked.tracking.body = CGPoint(x: 0.5, y: -0.25)
            tracked.tracking.face = CGPoint(x: 1, y: -0.5)
            tracked.tracking.eyes = CGPoint(x: 0.5, y: -0.25)
            tracked.tracking.pupils = CGPoint(x: 1.25, y: -1)
            var purring = rest
            purring.purring = true
            var kneading = rest
            kneading.time = 0.53
            kneading.thinking = true
            kneading.kneadPhase = 1
            var breathing = rest
            breathing.time = 1.75

            let scale: CGFloat = 7.68
            for (name, state) in [
                ("rest", rest), ("tracked", tracked), ("purring", purring),
                ("kneading", kneading), ("breathing", breathing),
            ] {
                let frame = try XCTUnwrap(
                    compositor.layeredFrame(state: state, scale: scale), "\(label)/\(name): no layered frame")
                tree.update(
                    state: state, scale: scale, catRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                    lifting: false, viewHeight: 100)

                let reference = try XCTUnwrap(compositor.render(state: state, scale: scale))
                let mismatch = try treeMismatchFraction(
                    tree: tree, reference: reference, width: frame.width, height: frame.height)
                XCTAssertLessThan(mismatch, 0.05, "\(label)/\(name): layer tree diverged from compositor")
            }
        }
    }

    /// Renders `tree` offscreen and returns the smaller mismatched-pixel fraction between the
    /// two vertical parities, measured against the pixels where either image is visible.
    @MainActor
    private func treeMismatchFraction(
        tree: CatLayerTree, reference: CGImage, width: Int, height: Int
    ) throws -> Double {
        func bitmap(_ draw: (CGContext) -> Void) throws -> [UInt8] {
            let ctx = try XCTUnwrap(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            draw(ctx)
            let data = try XCTUnwrap(ctx.data)
            return [UInt8](UnsafeRawBufferPointer(start: data, count: width * height * 4))
        }

        let treePixels = try bitmap { tree.containerLayer.render(in: $0) }
        let refPixels = try bitmap { $0.draw(reference, in: CGRect(x: 0, y: 0, width: width, height: height)) }

        func mismatch(flipTree: Bool) -> Double {
            var different = 0
            var visible = 0
            for row in 0..<height {
                let treeRow = flipTree ? height - 1 - row : row
                for col in 0..<width {
                    let ti = (treeRow * width + col) * 4
                    let ri = (row * width + col) * 4
                    let ta = Int(treePixels[ti + 3])
                    let ra = Int(refPixels[ri + 3])
                    guard ta > 16 || ra > 16 else { continue }
                    visible += 1
                    if abs(ta - ra) > 64 || abs(Int(treePixels[ti]) - Int(refPixels[ri])) > 64
                        || abs(Int(treePixels[ti + 1]) - Int(refPixels[ri + 1])) > 64
                        || abs(Int(treePixels[ti + 2]) - Int(refPixels[ri + 2])) > 64
                    {
                        different += 1
                    }
                }
            }
            guard visible > 0 else { return 1 }
            return Double(different) / Double(visible)
        }

        return min(mismatch(flipTree: false), mismatch(flipTree: true))
    }

    @MainActor
    func testPetViewSkipsDisplayInvalidationWhenRenderSignatureIsStable() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        let view = PetView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100), compositor: compositor, state: RenderState())
        view.restingHeight = 100

        var state = RenderState()
        state.time = 0
        view.state = state
        view.needsDisplay = false
        state.time = 1 / 120
        view.state = state

        XCTAssertFalse(view.needsDisplay)
    }

    @MainActor
    func testPetViewQuantizesThinkingDisplayInvalidation() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let view = PetView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            compositor: PixelCompositor(library: poses, mappings: mappings),
            state: RenderState())
        view.restingHeight = 100

        var state = RenderState()
        state.thinking = true
        state.time = 0
        view.state = state
        view.needsDisplay = false
        state.time = 1.0 / 120.0
        view.state = state
        XCTAssertFalse(view.needsDisplay)
    }

    func testDynamicVocabularyCoversAffineTransformBranches() {
        XCTAssertEqual(
            DynamicVocabulary.ids,
            [
                "body", "cat-content", "face-js", "eyes-js", "head-group", "pupil-left",
                "pupil-right", "tail", "leg-fl", "leg-fr", "leg-rl", "leg-rr",
            ])
        XCTAssertEqual(
            DynamicVocabulary.classes,
            [
                "pupil-left", "pupil-right", "breathe-anim", "tail-sway", "whiskers-flex",
                "ear-twitch-l", "ear-twitch-r", "eye-l-blink", "eye-r-blink",
                "hunting-body-grow", "hunting-tail-rise",
            ])
    }

    /// The layered fast path's value is cache effectiveness, not one-shot speed: a Debug-build
    /// wall-clock race against the monolithic path was flaky (and failing) on fast machines, so
    /// this asserts the deterministic contract instead — replaying a tracked idle sequence must
    /// re-rasterize zero layers and re-render zero frames.
    func testLayeredCompositorStaysCacheEffectiveUnderTracking() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let layered = PixelCompositor(library: poses, mappings: mappings)

        let frames = (0..<30).map { index -> RenderState in
            var state = RenderState()
            state.time = Double(index) / 60
            state.tracking.body = CGPoint(x: 0.5, y: -0.25)
            state.tracking.face = CGPoint(x: 1, y: -0.5)
            state.tracking.eyes = CGPoint(x: 0.5, y: -0.25)
            state.tracking.pupils = CGPoint(x: 1.25, y: -1)
            return state
        }

        for state in frames {
            XCTAssertNotNil(layered.render(state: state, scale: 8))
        }
        let warm = layered.cacheStats
        XCTAssertGreaterThan(warm.layerRasterHits, 0)

        for state in frames {
            XCTAssertNotNil(layered.render(state: state, scale: 8))
        }
        let replay = layered.cacheStats
        XCTAssertEqual(replay.layerRasterMisses, warm.layerRasterMisses, "replay re-rasterized a layer")
        XCTAssertEqual(replay.frameMisses, warm.frameMisses, "replay re-rendered a cached frame")
        XCTAssertEqual(replay.outlineMisses, warm.outlineMisses, "replay re-dilated a cached outline")
    }

    func testIdleCompositorRendersPixels() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        var state = RenderState()
        state.pattern.head = [Spot(x: 1, y: 1, color: "#FF0000")]
        let image = try XCTUnwrap(compositor.render(state: state))
        XCTAssertEqual(image.width, 50)
        XCTAssertEqual(image.height, 50)
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        var alphaPixels = 0
        for i in stride(from: 3, to: CFDataGetLength(data), by: 4) where bytes[i] > 0 { alphaPixels += 1 }
        XCTAssertGreaterThan(alphaPixels, 80)
    }

    func testFlowerRigRendersEveryPoseWithFaceRig() throws {
        func find(_ node: SceneNode, _ id: String) -> Bool {
            node.attrs["id"] == id || node.children.contains { find($0, id) }
        }
        let library = try PoseLibrary.load(bundle: .main, resource: "flower-poses")
        XCTAssertEqual(Set(library.poses.keys), Set(PetPose.allCases.map(\.rawValue)))
        // The flower reuses the cat's eye rig verbatim, so blink / cursor tracking / typing animate it.
        let idle = library.pose(named: PetPose.idle.rawValue)
        XCTAssertTrue(find(idle.root, "face-js"))
        XCTAssertTrue(find(idle.root, "eyes-js"))
        XCTAssertTrue(find(idle.root, "pupil-left"))
        XCTAssertTrue(find(idle.root, "pupil-right"))
        let compositor = PixelCompositor(library: library, mappings: try CellMappings.load(bundle: .main))
        compositor.forceMonolithic = true
        let scale: CGFloat = 6
        for pose in PetPose.allCases {
            var state = RenderState()
            state.pose = pose
            let box = library.pose(named: pose.rawValue).viewBoxRect
            let image = try XCTUnwrap(compositor.render(state: state, scale: scale), "pose \(pose)")
            XCTAssertEqual(image.width, Int((box.width * scale).rounded(.up)), "pose \(pose)")
            // Every pose with a head wears the petal crown (stretch-start is the headless noodle frame).
            if pose != .stretchStart {
                XCTAssertTrue(find(library.pose(named: pose.rawValue).root, "petals"), "pose \(pose) missing crown")
            }
            let data = try XCTUnwrap(image.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            var opaque = 0
            for offset in stride(from: 3, to: CFDataGetLength(data), by: 4) where bytes[offset] > 0 { opaque += 1 }
            XCTAssertGreaterThan(opaque, 500, "pose \(pose) drew too few pixels")
        }
    }

    func testFlowerIdleUsesLayeredRendererCache() throws {
        let library = try PoseLibrary.load(bundle: .main, resource: "flower-poses")
        let mappings = try CellMappings.load(bundle: .main)
        var state = RenderState()
        state.time = 0.2
        try assertLayeredMatchesMonolithic(
            poses: library,
            mappings: mappings,
            state: state,
            scale: 8,
            label: "flower idle layered"
        )
        try assertLayeredMatchesMonolithic(
            poses: library,
            mappings: mappings,
            state: state,
            scale: 2,
            label: "flower idle layered small"
        )

        let compositor = PixelCompositor(library: library, mappings: mappings)
        compositor.skipUserPatches = true
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertGreaterThan(compositor.cacheStats.layerRasterMisses, 0)
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertEqual(compositor.cacheStats.frameHits, 1)

        state.time = 0.35
        XCTAssertNotNil(compositor.render(state: state, scale: 8))
        XCTAssertGreaterThan(compositor.cacheStats.layerRasterHits, 0)
    }

    @MainActor
    func testFlowerSkinIgnoresUserCatPattern() throws {
        // Regression: with a brown-tabby cat pattern (orange base, orange eyes, dark spots), the
        // flower-claude skin used to bleed those colors through and looked like a bee. Baked colors
        // must win — the canonical Claude palette (purple shirt, terracotta tail/petals) renders
        // regardless of what the user's cat preset is.
        let library = try PoseLibrary.load(bundle: .main, resource: "flower-poses")
        let compositor = PixelCompositor(library: library, mappings: try CellMappings.load(bundle: .main))
        compositor.forceMonolithic = true
        compositor.skipUserPatches = true
        var tabby = PatternModel()
        tabby.baseColor = "#b35a2a"
        tabby.eyeColor = "#ff8800"
        tabby.outlineColor = "#552200"
        tabby.head = [Spot(x: 5, y: 6, color: "#000000")]
        tabby.body = [Spot(x: 4, y: 22, color: "#000000")]
        var state = RenderState()
        state.pose = .idle
        state.pattern = tabby
        let image = try XCTUnwrap(compositor.render(state: state, scale: 6))
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let length = CFDataGetLength(data)
        var purple = 0
        var terracotta = 0
        for offset in stride(from: 0, to: length, by: 4) {
            let red = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let blue = Int(bytes[offset + 2])
            let alpha = Int(bytes[offset + 3])
            guard alpha > 200 else { continue }
            // Body shirt is #9b7cb8 — red ~155, green ~124, blue ~184 (red < blue, distinctly purple).
            if abs(red - 0x9b) < 18 && abs(green - 0x7c) < 18 && abs(blue - 0xb8) < 18 { purple += 1 }
            // Tail + petals are #c8552f — red ~200, green ~85, blue ~47 (clearly terracotta).
            if abs(red - 0xc8) < 18 && abs(green - 0x55) < 18 && abs(blue - 0x2f) < 18 { terracotta += 1 }
        }
        XCTAssertGreaterThan(purple, 200, "flower body should render the Claude purple shirt, not the user's cat color")
        XCTAssertGreaterThan(terracotta, 200, "petals + terracotta tail should render")
    }

    func testSettingsSkinDefaultsToFlowerClaudeWhenKeyMissing() throws {
        let missing = Data(#"{"catName":"K"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ClawdiSettings.self, from: missing).skin, .flowerClaude)
        var settings = ClawdiSettings.default
        settings.skin = .cat
        let round = try JSONDecoder().decode(ClawdiSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(round.skin, .cat, "an explicit cat choice must survive, not snap back to the default")
    }

    func testSettingsLaunchAtLoginDefaultsTrueAndRoundTrips() throws {
        let missing = Data(#"{"catName":"K"}"#.utf8)
        XCTAssertTrue(
            try JSONDecoder().decode(ClawdiSettings.self, from: missing).launchAtLogin,
            "a missing key must default to launch-at-login enabled")
        var off = ClawdiSettings.default
        off.launchAtLogin = false
        let round = try JSONDecoder().decode(ClawdiSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(round.launchAtLogin, "an explicit false must survive, not snap back to the default")
    }

    func testSettingsStretchIntervalDefaultsAndRoundTrips() throws {
        let missing = Data(#"{"catName":"K"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ClawdiSettings.self, from: missing).stretchIntervalMin, 30,
            "a missing stretchIntervalMin keeps the default cadence")
        var off = ClawdiSettings.default
        off.stretchIntervalMin = 0
        let round = try JSONDecoder().decode(ClawdiSettings.self, from: JSONEncoder().encode(off))
        XCTAssertEqual(
            round.stretchIntervalMin, 0, "an explicit Off must survive, not snap back to 30")
    }

    func testSettingsMalformedFieldDoesNotDiscardDisabledStretch() throws {
        // A present-but-wrong-type field (a hand-edit or a future schema) can ride along in
        // settings.json. The whole file must not be thrown away:
        // a disabled stretch (`stretchIntervalMin: 0`) has to survive, or the cat starts stretching
        // every launch despite the user turning it Off.
        let blob = Data(
            #"{"stretchIntervalMin":0,"catName":"Tofu","skin":"bogus","reminders":"oops"}"#.utf8)
        let decoded = try JSONDecoder().decode(ClawdiSettings.self, from: blob)
        XCTAssertEqual(
            decoded.stretchIntervalMin, 0, "an explicit Off must survive a malformed sibling field")
        XCTAssertEqual(decoded.catName, "Tofu", "valid fields beside the bad one must be preserved")
        XCTAssertEqual(decoded.skin, .flowerClaude, "an unknown skin falls back to the default, not the whole file")
        XCTAssertEqual(decoded.reminders, [], "a malformed reminders array degrades to empty")
    }
    func testHitTesterAndShakeDetector() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(CatHitTester.isCatHit(point: CGPoint(x: 40, y: 30), in: bounds))
        XCTAssertTrue(CatHitTester.isHead(point: CGPoint(x: 40, y: 30), in: bounds))
        XCTAssertFalse(CatHitTester.isCatHit(point: CGPoint(x: 5, y: 95), in: bounds))
        var shake = ShakeDetector()
        var triggered = false
        for i in 0..<12 {
            triggered =
                triggered
                || shake.step(mouse: CGPoint(x: i * 40, y: i.isMultiple(of: 2) ? 0 : 80), now: Double(i) * 0.016)
        }
        XCTAssertTrue(triggered)
    }

    @MainActor
    func testContextMenuContainsNativeFeatureItems() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let paths = AppPaths(
            base: base, settings: base.appendingPathComponent("settings.json"),
            pattern: base.appendingPathComponent("pattern.json"),
            customPresets: base.appendingPathComponent("custom-presets.json"),
            hooks: base.appendingPathComponent("hooks"))
        let controller = ClawdiController(
            paths: paths, library: try PoseLibrary.load(bundle: Bundle.main),
            mappings: try CellMappings.load(bundle: Bundle.main))
        let menu = controller.contextMenu()
        let titles = Set(menu.items.map(\.title))
        XCTAssertTrue(titles.contains("Share cat…"))
        XCTAssertTrue(titles.contains("Pattern editor…"))
        XCTAssertTrue(titles.contains("Show cat name"))
        let pomodoro = try XCTUnwrap(menu.items.first { $0.title == "Pomodoro" }?.submenu)
        XCTAssertTrue(pomodoro.items.contains { $0.title == "Focus time" && $0.submenu != nil })
        XCTAssertTrue(pomodoro.items.contains { $0.title == "Break time" && $0.submenu != nil })
        let reminders = try XCTUnwrap(menu.items.first { $0.title == "Reminders" }?.submenu)
        XCTAssertTrue(reminders.items.contains { $0.title == "Open reminders…" })
        let launchAtLogin = try XCTUnwrap(menu.items.first { $0.title == "Launch at login" })
        XCTAssertEqual(launchAtLogin.action, #selector(ClawdiController.toggleLaunchAtLogin))
        let extensions = try XCTUnwrap(menu.items.first { $0.title == "Extensions" }?.submenu)
        XCTAssertEqual(extensions.items.count, AgentEventSource.extensions.count)
        for source in AgentEventSource.allCases where source.isExtension {
            let item = try XCTUnwrap(extensions.items.first { $0.tag == Int(source.rawValue) })
            XCTAssertEqual(item.title, source.displayName)
            XCTAssertEqual(item.action, #selector(ClawdiController.toggleExtension(_:)))
            XCTAssertEqual(item.state, .on)
        }
    }

    @MainActor
    func testCharacterMenuListsSkinsAndCompositorSwaps() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let paths = AppPaths(
            base: base, settings: base.appendingPathComponent("settings.json"),
            pattern: base.appendingPathComponent("pattern.json"),
            customPresets: base.appendingPathComponent("custom-presets.json"),
            hooks: base.appendingPathComponent("hooks"))
        let controller = ClawdiController(
            paths: paths, library: try PoseLibrary.load(bundle: Bundle.main),
            mappings: try CellMappings.load(bundle: Bundle.main))
        let character = try XCTUnwrap(controller.contextMenu().items.first { $0.title == "Character" }?.submenu)
        XCTAssertEqual(character.items.count, PetSkin.allCases.count)
        XCTAssertEqual(
            Set(character.items.compactMap { $0.representedObject as? String }),
            Set(PetSkin.allCases.map(\.rawValue)))
        let flowerItem = try XCTUnwrap(
            character.items.first { ($0.representedObject as? String) == PetSkin.flowerClaude.rawValue })
        XCTAssertEqual(flowerItem.state, .on)  // Flowery Claude is the default skin and starts checked
        XCTAssertEqual(flowerItem.action, #selector(ClawdiController.setSkin(_:)))
        let catItem = try XCTUnwrap(
            character.items.first { ($0.representedObject as? String) == PetSkin.cat.rawValue })
        XCTAssertEqual(catItem.state, .off)
        // The cat keeps the procedural mochi lift; the flower uses its own pose library with the lift
        // disabled while retaining the shared layered renderer/cache for idle CPU.
        let cat = controller.makeCompositor(for: .cat)
        XCTAssertTrue(cat.usesMochiLift)
        XCTAssertFalse(cat.forceMonolithic)
        let flower = controller.makeCompositor(for: .flowerClaude)
        XCTAssertFalse(flower.usesMochiLift)
        XCTAssertFalse(flower.forceMonolithic)
    }

    @MainActor
    func testControllerLaunchCreatesVisiblePetPanel() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let paths = AppPaths(
            base: base, settings: base.appendingPathComponent("settings.json"),
            pattern: base.appendingPathComponent("pattern.json"),
            customPresets: base.appendingPathComponent("custom-presets.json"),
            hooks: base.appendingPathComponent("hooks"))
        let controller = ClawdiController(
            paths: paths, library: try PoseLibrary.load(bundle: Bundle.main),
            mappings: try CellMappings.load(bundle: Bundle.main))
        try controller.launch()
        defer { controller.shutdown() }

        XCTAssertNotNil(controller.panel)
        XCTAssertNotNil(controller.petView)
        XCTAssertEqual(controller.panel.contentView as? PetView, controller.petView)
        XCTAssertEqual(controller.panel.title, "Clawdi")
        XCTAssertTrue(controller.panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(controller.panel.level, .statusBar)
        let frameRate = controller.displayLink?.preferredFrameRateRange
        XCTAssertEqual(frameRate?.preferred, 120)
        XCTAssertEqual(frameRate?.maximum, 120)
    }

    @MainActor
    func testInputCallbacksDriveTypingAndScrollPoses() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let paths = AppPaths(
            base: base,
            settings: base.appendingPathComponent("settings.json"),
            pattern: base.appendingPathComponent("pattern.json"),
            customPresets: base.appendingPathComponent("custom-presets.json"),
            hooks: base.appendingPathComponent("hooks")
        )
        let controller = ClawdiController(
            paths: paths,
            library: try PoseLibrary.load(bundle: Bundle.main),
            mappings: try CellMappings.load(bundle: Bundle.main)
        )
        try controller.launch()
        defer { controller.shutdown() }

        controller.input.onKeyDown?()
        XCTAssertEqual(controller.petView.state.pose, .pressLeft)

        controller.petView.state.pose = .idle
        controller.input.onScroll?()
        XCTAssertEqual(controller.petView.state.pose, .scroll)
        XCTAssertNotNil(controller.scrollStartedAt)
    }

    @MainActor
    func testPetViewTimerChromeAndInlineEditorInteractiveRects() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        var state = RenderState()
        state.speech = "25:00"
        state.speechKind = .timer
        state.pomodoroRunning = true
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 500, height: 480), compositor: compositor, state: state)
        let panel = PetPanel(size: view.frame.size, origin: .zero)
        panel.contentView = view
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.visibleInteractiveRects().count, 1)

        view.showInlineEditor(
            config: InlineEditorConfig(
                anchor: .cat, width: 220, initialValue: "Clawdi", placeholder: "Cat name", guide: nil, suffix: nil,
                maxLength: 24), onCommit: { _ in })
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.visibleInteractiveRects().count, 2)

        view.hideInlineEditor()
        XCTAssertEqual(view.visibleInteractiveRects().count, 1)
        panel.close()
    }

    @MainActor
    func testPetViewRenderScaleDownsamplesToReducePixelation() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        let view = PetView(
            frame: CGRect(x: 0, y: 0, width: 250, height: 250), compositor: compositor, state: RenderState())

        let scale = view.renderScale(for: view.catDrawRect(), backingScale: 2)
        let capped = view.renderScale(for: CGRect(x: 0, y: 0, width: 1_000, height: 1_000), backingScale: 2)

        XCTAssertEqual(scale, 10, accuracy: 0.001)
        XCTAssertLessThanOrEqual(capped * 50, 768.1)
    }

    func testRenderSupersamplesBitmapToRequestedScale() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        let state = RenderState()
        let base = try XCTUnwrap(compositor.render(state: state, scale: 1))
        let hi = try XCTUnwrap(compositor.render(state: state, scale: 4))
        // Supersampling renders the vector artwork into a proportionally larger bitmap (the fix for
        // the nearest-neighbour blow-up); scale 1 stays at native viewBox size for compatibility.
        XCTAssertEqual(hi.width, base.width * 4)
        XCTAssertEqual(hi.height, base.height * 4)
    }

    func testCompositorRendersStrokeOnlySvgPaths() throws {
        let root = SceneNode(
            tag: "svg", attrs: ["fill": "none"],
            children: [
                SceneNode(
                    tag: "path",
                    attrs: [
                        "d": "M1 4H7",
                        "fill": "none",
                        "stroke": "#FF0000",
                        "stroke-width": "1",
                    ], children: [])
            ])
        let library = PoseLibrary(
            components: PoseComponents(earLeftPathD: "", earRightPathD: "", tailPathD: ""),
            poses: [
                "cat-idle-follow-v2": Pose(
                    name: "cat-idle-follow-v2", file: "inline.svg", viewBox: "0 0 8 8", root: root)
            ]
        )
        let compositor = PixelCompositor(library: library, mappings: CellMappings(mappings: [:]))

        let image = try XCTUnwrap(compositor.render(state: RenderState()))

        XCTAssertGreaterThan(
            countPixels(in: image) { red, green, blue, alpha in
                alpha > 0 && red > green && red > blue
            }, 0)
    }

    func testCompositorUsesPatternOutlineColor() throws {
        let root = SceneNode(
            tag: "svg", attrs: [:],
            children: [
                SceneNode(
                    tag: "rect",
                    attrs: [
                        "x": "2",
                        "y": "2",
                        "width": "4",
                        "height": "4",
                        "fill": "var(--cat-color)",
                    ], children: [])
            ])
        let library = PoseLibrary(
            components: PoseComponents(earLeftPathD: "", earRightPathD: "", tailPathD: ""),
            poses: [
                "cat-idle-follow-v2": Pose(
                    name: "cat-idle-follow-v2", file: "inline.svg", viewBox: "0 0 8 8", root: root)
            ]
        )
        let compositor = PixelCompositor(library: library, mappings: CellMappings(mappings: [:]))
        var state = RenderState()
        state.pattern.outlineColor = "#00FF00"

        let image = try XCTUnwrap(compositor.render(state: state))

        XCTAssertGreaterThan(countPixels(in: image, matching: (0, 255, 0)), 0)
    }

    func testExtractedSvgStrokeAttributesSurviveResourceGeneration() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)

        XCTAssertTrue(
            containsNode(poses.pose(named: "jump-ing").root) {
                $0.attr("stroke") == "var(--cat-outline, #FFFFFF)"
            })
        XCTAssertTrue(
            containsNode(poses.pose(named: "stretch-pose-default").root) {
                $0.attr("stroke-linecap") == "round" && $0.attr("stroke-linejoin") == "round"
            })
    }

    func testStretchBandsTileFittedRectAndReassembleHeadUp() throws {
        let fitted = CGRect(x: 174, y: 0, width: 132, height: 480)  // 40×145 fit into a 480 square
        let count = 6
        let bands = (0..<count).map {
            CatLayout.stretchBand(index: $0, count: count, imageWidth: 40, imageHeight: 145, fitted: fitted)
        }
        // Source crops tile the full image height with no gaps or overlaps.
        XCTAssertEqual(bands.first?.source.minY, 0)
        XCTAssertEqual(bands.last.map { $0.source.maxY }, 145)
        for (lower, upper) in zip(bands, bands.dropFirst()) {
            XCTAssertEqual(lower.source.maxY, upper.source.minY)
        }
        // Destinations tile `fitted` exactly, top to bottom.
        XCTAssertEqual(try XCTUnwrap(bands.map { $0.dest.minY }.min()), fitted.minY, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(bands.map { $0.dest.maxY }.max()), fitted.maxY, accuracy: 0.001)
        // The crux: the band cropped from the image TOP is drawn at the BOTTOM of `fitted` (the
        // compositor bitmap is stored bottom-up), so the cat reassembles head-up, not head-down.
        let topCrop = bands[0]
        XCTAssertEqual(topCrop.source.minY, 0)
        XCTAssertEqual(topCrop.dest.maxY, fitted.maxY, accuracy: 0.001)
        let bottomCrop = bands[count - 1]
        XCTAssertEqual(bottomCrop.source.maxY, 145)
        XCTAssertEqual(bottomCrop.dest.minY, fitted.minY, accuracy: 0.001)
    }
    @MainActor
    func testShareOverlayShowUpdateHideLifecycle() {
        let overlay = ShareOverlay()
        overlay.show(
            crop: CGRect(x: 100, y: 100, width: 180, height: 320), display: CGRect(x: 0, y: 0, width: 800, height: 600),
            seconds: 10)
        XCTAssertTrue(overlay.isShowing)
        overlay.update(
            crop: CGRect(x: 120, y: 110, width: 180, height: 320), display: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(overlay.isShowing)
        overlay.hide()
        XCTAssertFalse(overlay.isShowing)
    }
    func testSettingsSanitizesClampableFieldsAndReminders() {
        let longName = String(repeating: "C", count: 30)
        let longUser = String(repeating: "U", count: 30)
        let longMessage = String(repeating: "M", count: 90)
        let validReminder = phase4Reminder(
            time: "7:05", message: longMessage, repeatRule: .custom, days: [-1, 3, 3, 9])
        let invalidReminder = phase4Reminder(time: "25:00", message: "drop")

        let settings = ClawdiSettings(
            stretchIntervalMin: -10,
            reminders: [validReminder, invalidReminder],
            catName: longName,
            userName: longUser,
            fixedMessage: longMessage,
            taskCompleteSoundVolume: 1.7,
            petSize: 401,
            petPosition: StoredPoint(x: 10.4, y: -2.6),
            pomodoroFocusMin: 0,
            pomodoroRestSec: 12
        ).sanitized()

        XCTAssertEqual(settings.stretchIntervalMin, 0)
        XCTAssertEqual(settings.catName.count, 24)
        XCTAssertEqual(settings.userName.count, 24)
        XCTAssertEqual(settings.fixedMessage.count, 80)
        XCTAssertEqual(settings.taskCompleteSoundVolume, 1)
        XCTAssertEqual(settings.petSize, 400)
        XCTAssertEqual(settings.petPosition?.x, 10)
        XCTAssertEqual(settings.petPosition?.y, -3)
        XCTAssertEqual(settings.pomodoroFocusMin, 1)
        XCTAssertEqual(settings.pomodoroRestSec, 30)
        XCTAssertEqual(settings.reminders.count, 1)
        XCTAssertEqual(settings.reminders[0].time, "07:05")
        XCTAssertEqual(settings.reminders[0].message.count, 80)
        XCTAssertEqual(settings.reminders[0].days, [3])
    }

    func testSettingsSanitizesUpperPomodoroAndLowerVolumeEdges() {
        let settings = ClawdiSettings(
            taskCompleteSoundVolume: -0.5,
            petSize: 19,
            pomodoroFocusMin: 181,
            pomodoroRestSec: 3601
        ).sanitized()

        XCTAssertEqual(settings.taskCompleteSoundVolume, 0)
        XCTAssertEqual(settings.petSize, 20)
        XCTAssertEqual(settings.pomodoroFocusMin, 180)
        XCTAssertEqual(settings.pomodoroRestSec, 3600)
    }

    func testPomodoroClampsTransitionsAndTimerText() {
        var p = PomodoroState(visible: true, running: true, mode: .focus, remainingSec: 1, focusMin: 0, restSec: 12)
        XCTAssertEqual(p.focusMin, 1)
        XCTAssertEqual(p.restSec, 30)
        XCTAssertEqual(p.timerText, "00:01")
        XCTAssertEqual(p.tick(), .focusCompleted)
        XCTAssertEqual(p.mode, .rest)
        XCTAssertEqual(p.remainingSec, 30)
        XCTAssertEqual(p.timerText, "00:30")

        p.configure(focusMin: 181, restSec: 3601)
        XCTAssertEqual(p.focusMin, 180)
        XCTAssertEqual(p.restSec, 3600)
        XCTAssertEqual(p.remainingSec, 30)

        p.remainingSec = 1
        XCTAssertEqual(p.tick(), .restCompleted)
        XCTAssertEqual(p.mode, .focus)
        XCTAssertEqual(p.remainingSec, 180 * 60)
        XCTAssertEqual(p.timerText, "180:00")

        p.pause()
        p.mode = .rest
        p.configure(focusMin: 2, restSec: 60)
        XCTAssertEqual(p.focusMin, 2)
        XCTAssertEqual(p.restSec, 60)
        XCTAssertEqual(p.remainingSec, 60)

        p.remainingSec = -9
        XCTAssertEqual(p.timerText, "00:00")
        p.pause()
        XCTAssertNil(p.tick())
        XCTAssertFalse(p.running)
    }

    func testReminderRulesDedupNoneDisablingCustomDaysAndFormatting() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let monday = try XCTUnwrap(
            DateComponents(
                calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 6, day: 1, hour: 9, minute: 30
            ).date)
        let saturday = try XCTUnwrap(
            DateComponents(
                calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 6, day: 6, hour: 9, minute: 30
            ).date)
        let sundayNoon = try XCTUnwrap(
            DateComponents(
                calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 6, day: 7, hour: 12, minute: 0
            ).date)

        XCTAssertTrue(
            phase4Reminder(time: "09:30", message: "Daily", repeatRule: .daily).appliesToday(
                calendar: calendar, date: monday))
        XCTAssertTrue(
            phase4Reminder(time: "09:30", message: "Weekday", repeatRule: .weekdays).appliesToday(
                calendar: calendar, date: monday))
        XCTAssertFalse(
            phase4Reminder(time: "09:30", message: "Weekday", repeatRule: .weekdays).appliesToday(
                calendar: calendar, date: saturday))
        XCTAssertTrue(
            phase4Reminder(time: "09:30", message: "Weekend", repeatRule: .weekends).appliesToday(
                calendar: calendar, date: saturday))
        XCTAssertFalse(
            phase4Reminder(time: "09:30", message: "Weekend", repeatRule: .weekends).appliesToday(
                calendar: calendar, date: monday))
        XCTAssertTrue(
            phase4Reminder(time: "09:30", message: "Custom", repeatRule: .custom, days: [1]).appliesToday(
                calendar: calendar, date: monday))
        XCTAssertFalse(
            phase4Reminder(time: "09:30", message: "Custom", repeatRule: .custom, days: [6]).appliesToday(
                calendar: calendar, date: monday))

        var once = phase4Reminder(id: "once", time: "09:30", message: "Stand", repeatRule: .none)
        XCTAssertTrue(once.shouldTrigger(now: monday, calendar: calendar))
        once.markTriggered(now: monday, calendar: calendar)
        XCTAssertEqual(once.lastTriggeredDate, "2026-6-1")
        XCTAssertFalse(once.enabled)
        XCTAssertFalse(once.shouldTrigger(now: monday, calendar: calendar))

        var repeated = phase4Reminder(id: "daily", time: "09:30", message: "Hydrate", repeatRule: .daily)
        repeated.markTriggered(now: monday, calendar: calendar)
        XCTAssertTrue(repeated.enabled)
        XCTAssertFalse(repeated.shouldTrigger(now: monday, calendar: calendar))
        XCTAssertTrue(repeated.shouldTrigger(now: saturday, calendar: calendar))

        let scheduler = ReminderScheduler(reminders: [once, repeated])
        XCTAssertEqual(scheduler.due(now: saturday, calendar: calendar).map(\.id), ["daily"])
        scheduler.markTriggered(ids: ["daily"], now: saturday, calendar: calendar)
        XCTAssertEqual(scheduler.reminders.first { $0.id == "daily" }?.lastTriggeredDate, "2026-6-6")

        XCTAssertEqual(ReminderTime.format12Hour("00:05"), "12:05 AM")
        XCTAssertEqual(ReminderTime.format12Hour("12:00"), "12:00 PM")
        XCTAssertEqual(
            phase4Reminder(time: "12:00", message: "Lunch").speech(userName: "", date: sundayNoon),
            "Human, 12:00 PM \"Lunch\"")
        XCTAssertEqual(
            phase4Reminder(time: "09:30", message: "Stand").speech(userName: "Ada", date: monday),
            "Ada, 9:30 AM \"Stand\"")
    }

    func testHeatCurveAndTrackingQuantization() {
        var heat = HeatModel()
        XCTAssertEqual(heat.step(now: 0), 0)

        for i in 0..<21 { heat.recordKey(at: Double(i) * 0.05) }
        let hot = heat.step(now: 1.0)
        XCTAssertGreaterThan(hot, 0)

        let cooling = heat.step(now: HeatModel.keyWindow + 2.0)
        XCTAssertLessThan(cooling, hot)
        for i in 0..<30 { _ = heat.step(now: HeatModel.keyWindow + 2.1 + Double(i) * 0.1) }
        XCTAssertLessThan(heat.heat, cooling)

        XCTAssertEqual(CursorTracking.quantize(0.19), 0.25)
        XCTAssertEqual(CursorTracking.quantize(-0.19), -0.25)

        var tracking = CursorTracking()
        let offsets = tracking.step(
            mouse: CGPoint(x: 333, y: 137), windowCenter: CGPoint(x: 100, y: 100),
            elapsed: CursorTracking.referenceTick)
        for value in [
            offsets.pupils.x, offsets.pupils.y, offsets.eyes.x, offsets.eyes.y, offsets.face.x, offsets.face.y,
            offsets.body.x, offsets.body.y,
        ] {
            XCTAssertEqual(value * 8, (value * 8).rounded(), accuracy: 0.000_001)
        }
    }

    func testCursorTrackingDeflectionScalesWithDistanceAndStaysBounded() {
        let center = CGPoint(x: 100, y: 100)

        // Cursor far to the right (>= 400px): pupils converge to the full maxOffset (1.6, quantized
        // to 1.625), never the runaway dx/min(400,dist) overshoot (which gave 4.0 here).
        var far = CursorTracking()
        var farOut = TrackingOffsets()
        for _ in 0..<200 {
            farOut = far.step(
                mouse: CGPoint(x: 1100, y: 100), windowCenter: center, elapsed: CursorTracking.referenceTick)
        }
        XCTAssertEqual(farOut.pupils.x, 1.625, accuracy: 0.0001)
        XCTAssertEqual(farOut.pupils.y, 0, accuracy: 0.0001)

        // Cursor close (40px): deflection scales down with distance (1.6 * 40/400 = 0.16 -> 0.125),
        // so the pupil stays inside the sclera instead of being pinned to the edge.
        var near = CursorTracking()
        var nearOut = TrackingOffsets()
        for _ in 0..<200 {
            nearOut = near.step(
                mouse: CGPoint(x: 140, y: 100), windowCenter: center, elapsed: CursorTracking.referenceTick)
        }
        XCTAssertEqual(nearOut.pupils.x, 0.125, accuracy: 0.0001)
        XCTAssertLessThan(hypot(nearOut.pupils.x, nearOut.pupils.y), 0.3)
    }

    func testCursorTrackingSettlesAtSameWallClockSpeedAcrossFrameRates() {
        let center = CGPoint(x: 100, y: 100)
        let mouse = CGPoint(x: 1100, y: 100)
        var fast = CursorTracking()
        var fastOut = TrackingOffsets()
        for _ in 0..<12 { fastOut = fast.step(mouse: mouse, windowCenter: center, elapsed: 1.0 / 120) }
        var slow = CursorTracking()
        var slowOut = TrackingOffsets()
        for _ in 0..<3 { slowOut = slow.step(mouse: mouse, windowCenter: center, elapsed: 1.0 / 30) }
        // 0.1 s at 120 Hz vs 30 Hz: the body (slowest layer) is mid-ease, so a per-tick ease
        // would leave the 30 Hz rig visibly behind.
        XCTAssertGreaterThan(fastOut.body.x, 0.25)
        XCTAssertEqual(slowOut.body.x, fastOut.body.x, accuracy: 0.125)
        XCTAssertEqual(slowOut.face.x, fastOut.face.x, accuracy: 0.125)
    }

    func testScrollReactionProgressAndVisualState() {
        XCTAssertEqual(ScrollReaction.releaseDuration, 0.520)
        XCTAssertEqual(ScrollReaction.unrollDuration, 0.220)
        XCTAssertEqual(ScrollReaction.progress(startedAt: nil, now: 10), 0)
        XCTAssertEqual(ScrollReaction.progress(startedAt: 10, now: 9.5), 0)
        XCTAssertEqual(ScrollReaction.progress(startedAt: 10, now: 10.110), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(ScrollReaction.progress(startedAt: 10, now: 10.520), 1)

        XCTAssertEqual(ScrollReaction.paperHeight(progress: -1), 17)
        XCTAssertEqual(ScrollReaction.paperHeight(progress: 0.5), 30.5625, accuracy: 0.000_001)
        XCTAssertEqual(ScrollReaction.paperHeight(progress: 2), 32.5)

        var state = RenderState()
        state.pose = .scroll
        state.scrollProgress = ScrollReaction.progress(startedAt: 10, now: 10.110)
        XCTAssertEqual(state.pose, .scroll)
        XCTAssertGreaterThan(ScrollReaction.paperHeight(progress: state.scrollProgress), ScrollReaction.paperMinHeight)
    }

    func testStretchChainRatchetsHorizontalWobbleAndReleases() {
        var chain = StretchChain()
        chain.beginDrag()
        chain.drag(deltaY: 70, deltaX: 0)
        XCTAssertEqual(chain.stretchT, 0.5, accuracy: 0.0001)  // 70 / maxUpOffset(140)
        chain.drag(deltaY: 200, deltaX: 40)  // full lift + horizontal kick on segment 0
        XCTAssertEqual(chain.upOffset, StretchChain.maxUpOffset)
        XCTAssertEqual(chain.stretchT, 1, accuracy: 0.0001)
        for _ in 0..<4 { chain.step() }
        // Horizontal wobble propagated downstream and stays within the depth-tapered cap per segment.
        XCTAssertGreaterThan(abs(chain.cumulativeDX(upTo: StretchChain.segmentCount - 1)), 0)
        for (i, seg) in chain.segments.enumerated() {
            let localMax = StretchChain.maxDX * pow(StretchChain.depthTaper, CGFloat(i))
            XCTAssertLessThanOrEqual(abs(seg.x), localMax + 0.000_001)
        }

        chain.endDrag()
        chain.step()
        XCTAssertLessThan(chain.upOffset, StretchChain.maxUpOffset)  // release eases the lift down
        for _ in 0..<160 { chain.step() }
        XCTAssertEqual(chain.upOffset, 0, accuracy: 0.000_001)  // fully settled
        XCTAssertEqual(chain.stretchT, 0, accuracy: 0.000_001)
        XCTAssertEqual(chain.segments.map(\.x).map(abs).max() ?? 0, 0, accuracy: 0.000_001)
    }

    func testPurrLatchesOnHeadAndReleasesByIdleAndLeaveGrace() {
        var purr = PurrState()
        // Latches TRUE instantly on the first on-head sample (no start dwell).
        XCTAssertTrue(purr.step(onHead: true, moved: false, now: 0))
        XCTAssertTrue(purr.purring)

        // Sitting idle on the head (no movement) past the idle timeout stops the purr.
        XCTAssertTrue(purr.step(onHead: true, moved: false, now: PurrState.startDelay - 0.01))
        XCTAssertFalse(purr.step(onHead: true, moved: false, now: PurrState.startDelay + 0.01))
        XCTAssertFalse(purr.purring)

        // Movement on the head re-engages immediately.
        XCTAssertTrue(purr.step(onHead: true, moved: true, now: 1.0))

        // Off-head: per-frame polling of a STATIONARY cursor must NOT keep purring alive forever —
        // the grace anchor is pinned to the first off-head sample (the bug this guards against).
        let leftAt = 1.0
        XCTAssertTrue(purr.step(onHead: false, moved: false, now: leftAt + 0.001))
        var now = leftAt + 0.001
        for _ in 0..<5 {
            now += 1.0 / 60.0
            XCTAssertTrue(purr.step(onHead: false, moved: false, now: now))
        }
        XCTAssertFalse(purr.step(onHead: false, moved: false, now: leftAt + PurrState.leaveGrace + 0.02))
        XCTAssertFalse(purr.purring)

        // Off-head MOVEMENT re-arms the grace, so a cursor that keeps moving keeps the purr alive
        // until the motion pauses.
        var moving = PurrState()
        XCTAssertTrue(moving.step(onHead: true, moved: false, now: 0))
        var t = 0.0
        for _ in 0..<30 {
            t += 0.1
            XCTAssertTrue(moving.step(onHead: false, moved: true, now: t))
        }
        XCTAssertFalse(moving.step(onHead: false, moved: false, now: t + PurrState.leaveGrace + 0.01))
    }

    func testSleepModelFallsAsleepWakesAndDistinguishesInterruption() {
        var sleep = SleepModel()
        let timeout = SleepModel.idleTimeout

        // Stays awake while input is fresh; falls asleep once the idle clock crosses the timeout.
        XCTAssertEqual(sleep.step(now: 10, lastInputAt: 0, blocked: false), .none)
        XCTAssertEqual(sleep.step(now: timeout + 1, lastInputAt: 0, blocked: false), .fellAsleep)
        XCTAssertTrue(sleep.sleeping)
        XCTAssertEqual(sleep.step(now: timeout + 2, lastInputAt: 0, blocked: false), .none)

        // Fresh input wakes with the stretch even when that input already flipped the pose
        // (a key press becomes a paw-tap before the wake tick runs — still woke-by-input).
        XCTAssertEqual(sleep.step(now: timeout + 3, lastInputAt: timeout + 3, blocked: true), .wokeByInput)
        XCTAssertFalse(sleep.sleeping)

        // Being blocked (agent thinking, reactions, …) never lets the cat doze, however stale the clock.
        XCTAssertEqual(sleep.step(now: timeout * 2, lastInputAt: 0, blocked: true), .none)
        XCTAssertFalse(sleep.sleeping)

        // An agent reaction interrupting a nap wakes quietly (stale input clock, no stretch), and
        // the still-stale clock puts the cat back to sleep once the reaction passes.
        XCTAssertEqual(sleep.step(now: timeout * 3, lastInputAt: 0, blocked: false), .fellAsleep)
        XCTAssertEqual(sleep.step(now: timeout * 3 + 1, lastInputAt: 0, blocked: true), .interrupted)
        XCTAssertFalse(sleep.sleeping)
        XCTAssertEqual(sleep.step(now: timeout * 3 + 5, lastInputAt: 0, blocked: false), .fellAsleep)
    }

    func testCuriosityTiltsTowardLingeringCursorAndArmsCooldown() {
        var curiosity = CuriosityModel()

        // Nothing before the linger delay.
        XCTAssertEqual(curiosity.step(now: 0, nearby: true, moved: true, side: 80, engaged: false), 0)
        XCTAssertEqual(curiosity.step(now: 1.0, nearby: true, moved: false, side: 80, engaged: false), 0)

        // Past the delay the tilt eases up to +maxTilt (cursor to the right of the cat).
        var tilt: CGFloat = 0
        for _ in 0..<200 { tilt = curiosity.step(now: 3.0, nearby: true, moved: false, side: 80, engaged: false) }
        XCTAssertEqual(tilt, CuriosityModel.maxTilt, accuracy: 0.001)

        // A cursor on the left tilts the other way.
        var left = CuriosityModel()
        _ = left.step(now: 0, nearby: true, moved: true, side: -50, engaged: false)
        var leftTilt: CGFloat = 0
        for _ in 0..<200 { leftTilt = left.step(now: 3.0, nearby: true, moved: false, side: -50, engaged: false) }
        XCTAssertEqual(leftTilt, -CuriosityModel.maxTilt, accuracy: 0.001)

        // The cat loses interest after the hold window: tilt settles back to zero…
        let after = CuriosityModel.lingerDelay + CuriosityModel.holdDuration + 0.2
        var settled: CGFloat = 1
        for _ in 0..<300 { settled = curiosity.step(now: after, nearby: true, moved: false, side: 80, engaged: false) }
        XCTAssertEqual(settled, 0)

        // …and the cooldown stops an immediate re-tilt from a fresh linger.
        var cooled: CGFloat = 0
        let during = after + CuriosityModel.lingerDelay + 1
        for _ in 0..<50 { cooled = curiosity.step(now: during, nearby: true, moved: false, side: 80, engaged: false) }
        XCTAssertEqual(cooled, 0)
    }

    func testEarFlickStepPulsesTwicePerPeriod() {
        let period = PixelCompositor.earFlickLeftPeriod
        // Rest for the bulk of the period.
        XCTAssertEqual(PixelCompositor.earFlickStep(time: 0, period: period, offset: 0), 0)
        XCTAssertEqual(PixelCompositor.earFlickStep(time: period / 2, period: period, offset: 0), 0)
        // Two distinct pulses inside the final 0.42s window — flick, rest, flick, rest.
        let windowStart = period - 0.42
        XCTAssertEqual(PixelCompositor.earFlickStep(time: windowStart + 0.05, period: period, offset: 0), 1)
        XCTAssertEqual(PixelCompositor.earFlickStep(time: windowStart + 0.14, period: period, offset: 0), 0)
        XCTAssertEqual(PixelCompositor.earFlickStep(time: windowStart + 0.25, period: period, offset: 0), 1)
        XCTAssertEqual(PixelCompositor.earFlickStep(time: windowStart + 0.35, period: period, offset: 0), 0)
        // The offset shifts the cycle so the two ears never flick in sync.
        XCTAssertEqual(PixelCompositor.earFlickStep(time: windowStart + 0.05 - 1, period: period, offset: 1), 1)
    }

    func testKneadMotionEnvelopeRampsInAndOut() {
        var knead = KneadMotion()
        // The first step has no elapsed time to integrate.
        XCTAssertEqual(knead.step(now: 10, eligible: true), 0)
        XCTAssertEqual(knead.step(now: 10 + KneadMotion.rampIn * 0.5, eligible: true), 0.5, accuracy: 0.01)
        XCTAssertEqual(knead.step(now: 10 + KneadMotion.rampIn * 2, eligible: true), 1)
        // Ineligibility decays the envelope instead of cutting it, then clamps at rest.
        XCTAssertEqual(
            knead.step(now: 10 + KneadMotion.rampIn * 2 + KneadMotion.rampOut * 0.5, eligible: false),
            0.5, accuracy: 0.01)
        XCTAssertEqual(knead.step(now: 20, eligible: false), 0)
        XCTAssertEqual(knead.step(now: 21, eligible: false), 0)
    }

    func testKneadingLiftsAlternatingFrontPaws() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        struct PawPixelsMissing: Error {}

        // The paws' ground edge inside a device-x band: the CGImage byte buffer is bottom-up
        // relative to the svg's y-down rig (PetPanel flips at draw time), so the paws sit at the
        // *lowest* byte rows and a lifted paw moves its edge to a *higher* row index. Alpha-based
        // so the sticker outline (which travels with the paw) counts too.
        func render(time: TimeInterval, kneadPhase: CGFloat) throws -> CGImage {
            var state = RenderState()
            state.pattern.baseColor = "#C8A66E"
            state.time = time
            state.kneadPhase = kneadPhase
            return try XCTUnwrap(compositor.render(state: state, scale: 4))
        }
        func pawGroundRow(time: TimeInterval, kneadPhase: CGFloat, band: ClosedRange<Int>) throws -> Int {
            let image = try render(time: time, kneadPhase: kneadPhase)
            let data = try XCTUnwrap(image.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            for row in 0..<image.height {
                for column in band where column < image.width {
                    if bytes[row * image.bytesPerRow + column * 4 + 3] > 0 { return row }
                }
            }
            throw PawPixelsMissing()
        }
        // Top of the head dome (between the ears) — the *highest* byte row with alpha in the band.
        func headTopRow(time: TimeInterval, kneadPhase: CGFloat, band: ClosedRange<Int>) throws -> Int {
            let image = try render(time: time, kneadPhase: kneadPhase)
            let data = try XCTUnwrap(image.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            for row in stride(from: image.height - 1, through: 0, by: -1) {
                for column in band where column < image.width {
                    if bytes[row * image.bytesPerRow + column * 4 + 3] > 0 { return row }
                }
            }
            throw PawPixelsMissing()
        }

        // Device bands under each front paw (idle viewBox -8 -10, scale 4): leg-fl spans
        // svg x 6-14, leg-fr 15-23, leaving each band clear of the other leg's outline.
        let leftBand = 66...86
        let rightBand = 94...114
        // Quarter cycle in, the left paw is at peak lift while the right presses; rest baselines
        // are sampled at the same `time` so the breathe animation cancels out exactly.
        let liftLeftAt = PixelCompositor.kneadPeriod * 0.25
        let liftRightAt = PixelCompositor.kneadPeriod * 0.75

        let restLeft = try pawGroundRow(time: liftLeftAt, kneadPhase: 0, band: leftBand)
        let kneadLeft = try pawGroundRow(time: liftLeftAt, kneadPhase: 1, band: leftBand)
        XCTAssertGreaterThanOrEqual(kneadLeft - restLeft, 4, "lifted left paw should rise off the ground")
        let restRight = try pawGroundRow(time: liftLeftAt, kneadPhase: 0, band: rightBand)
        let kneadRight = try pawGroundRow(time: liftLeftAt, kneadPhase: 1, band: rightBand)
        XCTAssertGreaterThanOrEqual(restRight - kneadRight, 1, "pressing right paw pushes into the ground")

        // Half a cycle later the paws swap roles.
        let restLeft2 = try pawGroundRow(time: liftRightAt, kneadPhase: 0, band: leftBand)
        let kneadLeft2 = try pawGroundRow(time: liftRightAt, kneadPhase: 1, band: leftBand)
        XCTAssertGreaterThanOrEqual(restLeft2 - kneadLeft2, 1, "pressing left paw pushes into the ground")
        let restRight2 = try pawGroundRow(time: liftRightAt, kneadPhase: 0, band: rightBand)
        let kneadRight2 = try pawGroundRow(time: liftRightAt, kneadPhase: 1, band: rightBand)
        XCTAssertGreaterThanOrEqual(kneadRight2 - restRight2, 4, "lifted right paw should rise off the ground")

        // The arch: at a press peak the head dips down between the hunched shoulders
        // (lower byte row index = lower on screen in the flipped buffer).
        let domeBand = 82...98
        let restDome = try headTopRow(time: liftLeftAt, kneadPhase: 0, band: domeBand)
        let kneadDome = try headTopRow(time: liftLeftAt, kneadPhase: 1, band: domeBand)
        XCTAssertGreaterThanOrEqual(restDome - kneadDome, 3, "head should dip while kneading")
    }

    func testEarAnglesFlourishesOverrideAmbientFlicks() {
        // Ask: only the ear on the tilt side flicks, twice, inside the badge window.
        XCTAssertEqual(PixelCompositor.earAngles(time: 0, flourish: .askEars, phase: 0.1).right, 16)
        XCTAssertEqual(PixelCompositor.earAngles(time: 0, flourish: .askEars, phase: 0.1).left, 0)
        XCTAssertEqual(PixelCompositor.earAngles(time: 0, flourish: .askEars, phase: 0.3).right, 0)
        XCTAssertEqual(PixelCompositor.earAngles(time: 0, flourish: .askEars, phase: 0.45).right, 16)

        // Error: both ears pin back through the hold and release near the end.
        let pinned = PixelCompositor.earAngles(time: 0, flourish: .errorEars, phase: 0.5)
        XCTAssertEqual(pinned.left, -20)
        XCTAssertEqual(pinned.right, 20)
        let released = PixelCompositor.earAngles(time: 0, flourish: .errorEars, phase: 0.999)
        XCTAssertEqual(released.left, 0)
        XCTAssertEqual(released.right, 0)

        // Attention: a single early both-ear perk.
        XCTAssertEqual(PixelCompositor.earAngles(time: 0, flourish: .attentionEars, phase: 0.1).left, -12)
        XCTAssertEqual(PixelCompositor.earAngles(time: 0, flourish: .attentionEars, phase: 0.6).left, 0)

        // No flourish: the ambient double flicks pass through.
        let window = PixelCompositor.earFlickLeftPeriod - 0.42 + 0.05
        XCTAssertEqual(PixelCompositor.earAngles(time: window, flourish: .none, phase: 0).left, -10)
        XCTAssertEqual(PixelCompositor.earAngles(time: 0, flourish: .none, phase: 0).left, 0)
    }

    func testIdleTailAngleThinkingMetronomeSleepAndPlanRaise() {
        // Thinking: slow deliberate metronome — full deflection a quarter into the 2.4s period.
        let metronome = PixelCompositor.idleTailAngle(
            time: 0.6, hunting: false, purring: false, sleeping: false, thinking: true,
            flourish: .none, flourishPhase: 0)
        XCTAssertEqual(metronome, 7, accuracy: 0.001)

        // Sleeping: the tail is nearly still — a slow breathing twitch, never the mood swish.
        let asleep = PixelCompositor.idleTailAngle(
            time: 1.25, hunting: false, purring: false, sleeping: true, thinking: false,
            flourish: .none, flourishPhase: 0)
        XCTAssertEqual(asleep, 1.5, accuracy: 0.001)

        // Plan approval: the raised tail overrides the metronome, holds, and drops by the end.
        let raised = PixelCompositor.idleTailAngle(
            time: 0.6, hunting: false, purring: false, sleeping: false, thinking: true,
            flourish: .planTail, flourishPhase: 0.5)
        XCTAssertEqual(raised, 22, accuracy: 0.001)
        let dropped = PixelCompositor.idleTailAngle(
            time: 0.6, hunting: false, purring: false, sleeping: false, thinking: false,
            flourish: .planTail, flourishPhase: 1.0)
        XCTAssertEqual(dropped, 0, accuracy: 0.001)
    }

    func testSleepCurlPoseRendersCurledNap() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        let presetStore = PresetStore(
            bundle: Bundle.main,
            customURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        )
        let brownTabby = try XCTUnwrap(presetStore.builtIns.first { $0.id == "brown-tabby" })

        var nap = RenderState()
        nap.pose = .sleepCurl
        nap.sleeping = true
        nap.time = 0.3
        nap.pattern = brownTabby.pattern
        let napImage = try XCTUnwrap(compositor.render(state: nap, scale: 8))

        var idle = nap
        idle.pose = .idle
        idle.sleeping = false
        let idleImage = try XCTUnwrap(compositor.render(state: idle, scale: 8))

        // The curl is a genuinely different silhouette: same canvas, different pixels.
        XCTAssertEqual(napImage.width, idleImage.width)
        XCTAssertNotEqual(napImage.dataProvider?.data, idleImage.dataProvider?.data)

        // The flower skin re-derives from poses.json, so it must carry the nap pose too.
        let flower = try PoseLibrary.load(bundle: .main, resource: "flower-poses")
        let flowerCompositor = PixelCompositor(library: flower, mappings: mappings)
        flowerCompositor.skipUserPatches = true
        let flowerNap = try XCTUnwrap(flowerCompositor.render(state: nap, scale: 8))
        XCTAssertEqual(flowerNap.width, napImage.width)
    }

    func testCatLayoutPreservesPoseAspectRatio() {
        let square = CGRect(x: 10, y: 0, width: 480, height: 480)

        // Idle pose (50×50, 1:1) fills the square draw rect exactly.
        let idle = CatLayout.fittedRect(imageWidth: 50, imageHeight: 50, in: square)
        XCTAssertEqual(idle, square)

        // Stretch pose (40×145) is height-constrained: full height, narrow centered width.
        let stretch = CatLayout.fittedRect(imageWidth: 40, imageHeight: 145, in: square)
        XCTAssertEqual(stretch.height, 480, accuracy: 0.001)
        XCTAssertEqual(stretch.width, 480 * 40 / 145, accuracy: 0.001)
        XCTAssertEqual(stretch.midX, square.midX, accuracy: 0.001)
        XCTAssertEqual(stretch.minY, square.minY, accuracy: 0.001)
        // Aspect ratio is preserved (NOT squished to the square).
        XCTAssertEqual(stretch.width / stretch.height, 40.0 / 145.0, accuracy: 0.0001)

        // Wide pose (72×56) is width-constrained: full width, shorter centered height.
        let wide = CatLayout.fittedRect(imageWidth: 72, imageHeight: 56, in: square)
        XCTAssertEqual(wide.width, 480, accuracy: 0.001)
        XCTAssertEqual(wide.height, 480 * 56 / 72, accuracy: 0.001)
        XCTAssertEqual(wide.midY, square.midY, accuracy: 0.001)
    }

    func testPatternSanitizeNormalizesAndSignatureIgnoresSpotOrder() {
        var unordered = PatternModel.default
        unordered.selectedPresetId = "preset-a"
        unordered.baseColor = "bad"
        unordered.eyeColor = "#abcdef"
        unordered.eyeBgColor = "also bad"
        unordered.outlineColor = "outline bad"
        unordered.eyeColorLeft = "left bad"
        unordered.eyeColorRight = "#123abc"
        unordered.head = [
            Spot(x: 3, y: 1, color: "#00ff00"),
            Spot(x: -2, y: 4, color: "bad spot"),
            Spot(x: 1, y: 1, color: "#ff0000"),
        ]

        var reordered = unordered
        reordered.head = [unordered.head[1], unordered.head[2], unordered.head[0]]

        let sanitized = unordered.sanitized()
        XCTAssertEqual(sanitized.baseColor, "#1A1A1A")
        XCTAssertEqual(sanitized.eyeColor, "#ABCDEF")
        XCTAssertEqual(sanitized.eyeBgColor, "#FFFFFF")
        XCTAssertEqual(sanitized.eyeColorLeft, "#ABCDEF")
        XCTAssertEqual(sanitized.outlineColor, "#FFFFFF")
        XCTAssertEqual(sanitized.eyeColorRight, "#123ABC")
        XCTAssertEqual(
            sanitized.head,
            [
                Spot(x: 1, y: 1, color: "#FF0000"),
                Spot(x: 3, y: 1, color: "#00FF00"),
                Spot(x: 0, y: 4, color: "#1A1A1A"),
            ])
        XCTAssertEqual(unordered.signature(), reordered.signature())
    }

    func testPresetExportImportAppTagsFilenameAndNameCollisionSuffixes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = PresetStore(bundle: Bundle.main, customURL: dir.appendingPathComponent("custom-presets.json"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pattern = PatternModel(head: [Spot(x: 1, y: 2, color: "#FF00AA")])

        let original = try store.add(name: "Round Trip", pattern: pattern, now: now)
        let exported = try XCTUnwrap(store.exportData(id: original.id, now: now))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(json["app"] as? String, "clawdi")
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
        XCTAssertEqual(clawdiPatternExportFilename(name: "Round Trip!"), "clawdi-pattern-round-trip.json")

        let clawdiImported = try store.importData(exported, now: now)
        XCTAssertEqual(clawdiImported.count, 1)
        let clawdiPreset = try XCTUnwrap(clawdiImported.first)
        XCTAssertEqual(clawdiPreset.name, "Round Trip (1)")
        XCTAssertEqual(clawdiPreset.pattern.signature(), pattern.signature())

        let reimported = try store.importData(exported, now: now)
        XCTAssertEqual(try XCTUnwrap(reimported.first).name, "Round Trip (2)")
        XCTAssertEqual(try XCTUnwrap(reimported.first).pattern.signature(), pattern.signature())

        let foreignExport = PatternExport(
            schemaVersion: 2,
            app: "other-pet-app",
            exportedAt: ISO8601DateFormatter().string(from: now),
            preset: .init(name: "Round Trip", createdAt: "old", updatedAt: "old", pattern: pattern)
        )
        XCTAssertThrowsError(try store.importData(JSONEncoder.stable.encode(foreignExport), now: now)) { error in
            XCTAssertEqual(error as? PresetImportError, .unsupportedApp, "a foreign app tag must be rejected")
        }
    }

    func testPresetStoreDefaultPatternIsBrownTabby() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = PresetStore(bundle: Bundle.main, customURL: dir.appendingPathComponent("custom-presets.json"))
        let brown = try XCTUnwrap(store.builtIns.first { $0.id == PresetStore.defaultPresetId })
        XCTAssertEqual(store.defaultPattern.signature(), brown.pattern.signature())
        XCTAssertEqual(store.defaultPattern.selectedPresetId, "brown-tabby")
    }

    @MainActor
    func testFreshInstallDefaultsToBrownTabby() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(
            base: base, settings: base.appendingPathComponent("settings.json"),
            pattern: base.appendingPathComponent("pattern.json"),
            customPresets: base.appendingPathComponent("custom-presets.json"),
            hooks: base.appendingPathComponent("hooks"))
        let controller = ClawdiController(
            paths: paths, library: try PoseLibrary.load(bundle: Bundle.main),
            mappings: try CellMappings.load(bundle: Bundle.main))
        // No pattern.json on disk -> the brown-tabby built-in is the seeded pattern.
        let brown = try XCTUnwrap(controller.presets.builtIns.first { $0.id == "brown-tabby" })
        XCTAssertEqual(controller.pattern.signature(), brown.pattern.signature())
        XCTAssertEqual(controller.pattern.selectedPresetId, "brown-tabby")
    }

    func testBuiltInPresetLoadsDistinctlyAndRendersFromMappedCells() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = PresetStore(bundle: Bundle.main, customURL: dir.appendingPathComponent("custom-presets.json"))

        // Ships all 8 built-in presets.
        XCTAssertEqual(store.builtIns.count, 8)
        let brown = try XCTUnwrap(store.builtIns.first { $0.id == "brown-tabby" })
        XCTAssertEqual(brown.name, "Brown tabby")
        XCTAssertEqual(brown.pattern.baseColor, "#C8A66E")
        XCTAssertEqual(brown.pattern.resolvedEyeColor, "#A8761F")

        let mackerel = try XCTUnwrap(store.builtIns.first { $0.id == "mackerel-tabby" })
        XCTAssertEqual(mackerel.name, "Mackerel tabby")
        XCTAssertTrue(mackerel.builtIn)
        XCTAssertEqual(mackerel.pattern.baseColor, "#FFFFFF")
        XCTAssertFalse(mackerel.pattern.head.isEmpty)
        XCTAssertFalse(mackerel.pattern.body.isEmpty)

        // Spots land on mapped cells: the dominant stripe color must paint real pixels.
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        var state = RenderState()
        state.pattern = mackerel.pattern
        let image = try XCTUnwrap(compositor.render(state: state))
        XCTAssertGreaterThan(countPixels(in: image, matching: (136, 105, 67)), 0)
    }

    func testCellMappingsRepresentativeLookupAndMissingBehavior() throws {
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let dimensions = try XCTUnwrap(mappings.dimensions(svgName: "cat-idle-follow-v2", elementId: "head"))
        XCTAssertEqual(dimensions.0, 22)
        XCTAssertEqual(dimensions.1, 18)
        let originPixels = try XCTUnwrap(
            mappings.pixels(svgName: "cat-idle-follow-v2", elementId: "head", cellX: 0, cellY: 0))
        XCTAssertEqual(originPixels, [CGPoint(x: 3, y: 5)])
        let outOfRangePixels = try XCTUnwrap(
            mappings.pixels(svgName: "cat-idle-follow-v2", elementId: "head", cellX: 999, cellY: 999))
        XCTAssertEqual(outOfRangePixels, [])
        XCTAssertNil(mappings.pixels(svgName: "missing-pose", elementId: "head", cellX: 0, cellY: 0))
        XCTAssertNil(mappings.dimensions(svgName: "cat-idle-follow-v2", elementId: "missing-element"))
    }

    func testCompositorRendersPatternSpotAndOddEyeColors() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        var state = RenderState()
        state.pattern.oddEye = true
        state.pattern.eyeColorLeft = "#00FF00"
        state.pattern.eyeColorRight = "#0000FF"
        state.pattern.head = [Spot(x: 1, y: 1, color: "#FF0000")]

        let image = try XCTUnwrap(compositor.render(state: state))
        XCTAssertGreaterThan(countPixels(in: image, matching: (255, 0, 0)), 0)
        XCTAssertGreaterThan(countPixels(in: image, matching: (0, 255, 0)), 0)
        XCTAssertGreaterThan(countPixels(in: image, matching: (0, 0, 255)), 0)
    }

    func testHuntingPupilTrackingStaysInCrouchedEyes() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        var state = RenderState()
        state.pattern.baseColor = "#C8A66E"
        state.pattern.eyeBgColor = "#FF0000"
        state.pattern.eyeColor = "#000000"
        state.hunting = true
        state.huntingEnter = 1
        state.tracking.pupils = CGPoint(x: 1.625, y: 1.625)

        let image = try XCTUnwrap(compositor.render(state: state))
        let pupilBounds = try XCTUnwrap(self.pixelBounds(in: image, matching: (0, 0, 0)))
        XCTAssertGreaterThanOrEqual(pupilBounds.minX, 15)
        XCTAssertLessThanOrEqual(pupilBounds.maxX, 30)
        XCTAssertGreaterThanOrEqual(pupilBounds.minY, 13)
        XCTAssertLessThanOrEqual(pupilBounds.maxY, 21)
    }

    func testAgentStateMachineTTLCompleteGateClearAndNotificationDedup() {
        var machine = AgentStateMachine()
        let active = AgentStateEvent(
            agentId: "claude-code", sessionId: "s", event: "PreToolUse", state: .thinking, cwd: "/repo")
        let complete = AgentStateEvent(
            agentId: "claude-code", sessionId: "s", event: "Stop", state: .complete, cwd: "/repo")
        let otherSessionComplete = AgentStateEvent(
            agentId: "claude-code", sessionId: "other", event: "Stop", state: .complete, cwd: "/repo")

        XCTAssertEqual(machine.handle(complete, now: 0), .ignored)
        XCTAssertEqual(machine.handle(active, now: 0), .active(active))
        XCTAssertEqual(machine.handle(otherSessionComplete, now: 1), .ignored)
        XCTAssertEqual(machine.handle(complete, now: AgentStateMachine.activeTTL - 0.001), .complete(complete))
        XCTAssertEqual(machine.handle(complete, now: AgentStateMachine.activeTTL), .ignored)

        XCTAssertEqual(machine.handle(active, now: 10), .active(active))
        XCTAssertEqual(machine.handle(complete, now: 10 + AgentStateMachine.activeTTL), .ignored)

        XCTAssertEqual(machine.handle(active, now: 20), .active(active))
        let idle = AgentStateEvent(
            agentId: "claude-code", sessionId: "s", event: "SessionEnd", state: .idle, cwd: "/repo")
        XCTAssertEqual(machine.handle(idle, now: 21), .cleared(idle))
        XCTAssertEqual(machine.handle(complete, now: 22), .ignored)

        XCTAssertEqual(machine.handle(active, now: 30), .active(active))
        let error = AgentStateEvent(agentId: "claude-code", sessionId: "s", event: "Error", state: .error, cwd: "/repo")
        XCTAssertEqual(machine.handle(error, now: 31), .cleared(error))
        XCTAssertEqual(machine.handle(complete, now: 32), .ignored)

        let notification = AgentStateEvent(
            agentId: "cursor", sessionId: "cursor", event: "approval", state: .notification, cwd: "/repo")
        XCTAssertEqual(machine.handle(notification, now: 40), .notification(notification))
        XCTAssertEqual(machine.handle(notification, now: 44.999), .ignored)
        XCTAssertEqual(machine.handle(notification, now: 45), .notification(notification))

        let otherNotification = AgentStateEvent(
            agentId: "cursor", sessionId: "cursor", event: "approval", state: .notification, cwd: "/other")
        XCTAssertEqual(machine.handle(otherNotification, now: 46), .notification(otherNotification))
    }

    func testAgentStateMachineActiveCountTracksDistinctSessions() {
        var machine = AgentStateMachine()
        XCTAssertEqual(machine.activeCount, 0)
        let a1 = AgentStateEvent(
            agentId: "claude-code", sessionId: "s1", event: "PreToolUse", state: .thinking, cwd: "/r")
        let a2 = AgentStateEvent(agentId: "cursor", sessionId: "s2", event: "working", state: .working, cwd: "/r")
        _ = machine.handle(a1, now: 0)
        _ = machine.handle(a2, now: 0)
        XCTAssertEqual(machine.activeCount, 2)
        XCTAssertTrue(machine.hasActiveSessions)
        // Re-thinking an already-active session must not double count.
        _ = machine.handle(a1, now: 1)
        XCTAssertEqual(machine.activeCount, 2)
        // Completing one session decrements the count.
        let c1 = AgentStateEvent(agentId: "claude-code", sessionId: "s1", event: "Stop", state: .complete, cwd: "/r")
        XCTAssertEqual(machine.handle(c1, now: 2), .complete(c1))
        XCTAssertEqual(machine.activeCount, 1)
        // Idle clears the remaining session.
        let i2 = AgentStateEvent(agentId: "cursor", sessionId: "s2", event: "SessionEnd", state: .idle, cwd: "/r")
        XCTAssertEqual(machine.handle(i2, now: 3), .cleared(i2))
        XCTAssertEqual(machine.activeCount, 0)
        // Stale sessions are pruned out of the count past the TTL.
        _ = machine.handle(a1, now: 10)
        XCTAssertEqual(machine.activeCount, 1)
        machine.prune(now: 10 + AgentStateMachine.activeTTL + 1)
        XCTAssertEqual(machine.activeCount, 0)
    }

    func testActiveCountsSplitByModelAndAgent() {
        var machine = AgentStateMachine()
        func active(_ agent: String, _ session: String, model: String? = nil) -> AgentStateEvent {
            AgentStateEvent(
                agentId: agent, sessionId: session, event: "thinking", state: .thinking, cwd: "/r", model: model)
        }
        // First-party CLIs classify by agent id; model-agnostic agents (omp) classify by the running model.
        _ = machine.handle(active("claude-code", "a1"), now: 0)
        _ = machine.handle(active("omp", "o1", model: "openai-codex/gpt-5.3-codex"), now: 0)
        _ = machine.handle(active("omp", "o2", model: "anthropic/claude-sonnet-4-5"), now: 0)
        _ = machine.handle(active("omp", "o3", model: "google/gemini-3-pro"), now: 0)  // neither vendor
        _ = machine.handle(active("cursor", "x1"), now: 0)  // no model: neither
        let counts = machine.activeCounts()
        XCTAssertEqual(counts.openai, 1)  // omp gpt
        XCTAssertEqual(counts.anthropic, 2)  // claude-code + omp claude
        // Completing the OpenAI omp session drops only that vendor.
        let done = AgentStateEvent(agentId: "omp", sessionId: "o1", event: "session_stop", state: .complete, cwd: "/r")
        _ = machine.handle(done, now: 1)
        XCTAssertEqual(machine.activeCounts().openai, 0)
        XCTAssertEqual(machine.activeCounts().anthropic, 2)
    }

    func testProviderClassification() {
        XCTAssertEqual(AgentProvider(agentId: "claude-code", model: nil), .anthropic)
        XCTAssertNil(AgentProvider(agentId: "cursor", model: nil))
        XCTAssertNil(AgentProvider(agentId: "omp", model: nil))
        // A reported model wins over the agent's default vendor (model-agnostic agents).
        XCTAssertEqual(AgentProvider(agentId: "omp", model: "anthropic/claude-opus-4-6"), .anthropic)
        XCTAssertEqual(AgentProvider(agentId: "omp", model: "openai/gpt-5.3"), .openai)
        XCTAssertEqual(AgentProvider(agentId: "cursor", model: "claude-haiku-4-5"), .anthropic)
        XCTAssertNil(AgentProvider(agentId: "omp", model: "google/gemini-3-pro"))
    }

    @MainActor
    func testThinkingProviderBadgesRenderBesideDots() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)

        func render(openai: Int, anthropic: Int) throws -> NSBitmapImageRep {
            var state = RenderState()
            state.thinking = true
            state.openaiCount = openai
            state.anthropicCount = anthropic
            let view = PetView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), compositor: compositor, state: state)
            let panel = PetPanel(size: view.frame.size, origin: .zero)
            panel.contentView = view
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            panel.close()
            return rep
        }

        func counts(_ rep: NSBitmapImageRep) -> (white: Int, dark: Int) {
            var white = 0
            var dark = 0
            for row in 0..<rep.pixelsHigh {
                for col in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: col, y: row), color.alphaComponent > 0.5 else { continue }
                    if color.redComponent > 0.8, color.greenComponent > 0.8, color.blueComponent > 0.8 { white += 1 }
                    if color.redComponent < 0.25, color.greenComponent < 0.25, color.blueComponent < 0.25 { dark += 1 }
                }
            }
            return (white, dark)
        }

        // The cat artwork is identical across renders, so any pixel delta is purely the count badge.
        let baseRep = try render(openai: 0, anthropic: 0)
        let badgeRep = try render(openai: 3, anthropic: 2)
        if ProcessInfo.processInfo.environment["CLAWDI_DUMP"] != nil {
            try badgeRep.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/tmp/clawdi-thinking-badge.png"))
            try baseRep.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/tmp/clawdi-thinking-base.png"))
        }
        let base = counts(baseRep)
        let withCount = counts(badgeRep)
        XCTAssertGreaterThan(withCount.white, base.white, "count badge should widen the white thinking box")
        XCTAssertGreaterThan(withCount.dark, base.dark, "count digit should add dark glyph pixels")
    }

    @MainActor
    func testAnthropicBadgeLogoIsColoredAndUpright() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)

        func render(anthropic: Int) throws -> NSBitmapImageRep {
            var state = RenderState()
            state.thinking = true
            state.anthropicCount = anthropic
            let view = PetView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), compositor: compositor, state: state)
            let panel = PetPanel(size: view.frame.size, origin: .zero)
            panel.contentView = view
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            panel.close()
            return rep
        }

        // Claude terra-cotta (#D97757): clearly warm, red-dominant, with a mid-green and low blue.
        func orangePixels(_ rep: NSBitmapImageRep) -> Set<[Int]> {
            var pixels = Set<[Int]>()
            for row in 0..<rep.pixelsHigh {
                for col in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: col, y: row), color.alphaComponent > 0.5 else { continue }
                    let red = color.redComponent
                    let green = color.greenComponent
                    let blue = color.blueComponent
                    if red > 0.6, green > 0.3, green < 0.65, blue < 0.5, red > blue + 0.25 {
                        pixels.insert([col, row])
                    }
                }
            }
            return pixels
        }

        // The cat artwork is identical across renders, so subtracting the base cancels any warm
        // tabby pixels and leaves only the Anthropic badge logo — which must be the brand-colored
        // terra-cotta "A", not the old flat-black silhouette.
        let logoPixels = orangePixels(try render(anthropic: 1)).subtracting(orangePixels(try render(anthropic: 0)))
        XCTAssertFalse(logoPixels.isEmpty, "Anthropic badge should render the colored Anthropic 'A', not a black glyph")

        // Upright "A": the splayed legs make the base wider, so the colored mass sits below the
        // glyph's vertical midpoint. The pre-fix (flipped) draw would invert this and fail.
        let ys = logoPixels.map { $0[1] }
        let bboxMid = CGFloat(ys.min()! + ys.max()!) / 2
        let centroid = CGFloat(ys.reduce(0, +)) / CGFloat(ys.count)
        XCTAssertGreaterThan(centroid, bboxMid, "Anthropic 'A' should be upright (base-heavy), not vertically flipped")
    }

    /// A session whose agent dies without a terminal hook only ages out via the TTL; the sweep
    /// must notice and notify exactly once, since no further event will ever arrive to prune it.
    @MainActor
    func testAgentStateServerSweepExpiresStaleSessionsAndNotifies() {
        let server = AgentStateServer()
        var expirations = 0
        server.onSessionsExpired = { expirations += 1 }

        let start = Date().timeIntervalSince1970
        let active = AgentStateEvent(
            agentId: "claude-code", sessionId: "stale", event: "PreToolUse", state: .thinking, cwd: "/repo")
        _ = server.handle(active)
        XCTAssertTrue(server.hasActiveSessions)

        // Within the TTL nothing expires and the controller is not poked.
        server.sweepExpiredSessions(now: start + 1)
        XCTAssertTrue(server.hasActiveSessions)
        XCTAssertEqual(expirations, 0)

        // Past the TTL the dead session ages out and notifies exactly once.
        server.sweepExpiredSessions(now: start + AgentStateMachine.activeTTL + 5)
        XCTAssertFalse(server.hasActiveSessions)
        XCTAssertEqual(expirations, 1)
        server.sweepExpiredSessions(now: start + AgentStateMachine.activeTTL + 6)
        XCTAssertEqual(expirations, 1)
    }

    @MainActor
    func testAgentStateServerReceivesLargeUnixStreamMessage() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("clawdi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("agent-state.sock").path
        let server = AgentStateServer()
        let received = expectation(description: "stream message received")
        var completion: AgentOutput?
        server.onOutput = { output in
            if case .complete = output {
                completion = output
                received.fulfill()
            }
        }

        try server.start(socketPath: socketPath)
        defer { server.stop() }

        let active = AgentStateEvent(
            agentId: "omp", sessionId: "omp-s", event: "agent_start", state: .thinking, cwd: "/repo"
        )
        _ = server.handle(active)

        let title = String(repeating: "Eye issues with hunting ", count: 400)
        let complete = AgentStateEvent(
            agentId: "omp", sessionId: "omp-s", event: "session_stop", state: .complete, cwd: "/repo", title: title
        )
        let data = try JSONEncoder().encode(complete)
        XCTAssertGreaterThan(data.count, 8 * 1024)

        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socketPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let conn = NWConnection(to: NWEndpoint.unix(path: socketPath), using: .tcp)
        conn.start(queue: .global(qos: .utility))
        conn.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { _ in conn.cancel() }
        )

        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(completion, .complete(complete))
    }

    @MainActor
    func testAgentStateServerIgnoresDisabledAndLegacyHookSources() throws {
        let server = AgentStateServer()
        server.enabledExtensions = []

        let disabledHook = AgentStateEvent(
            agentId: "omp", sessionId: "disabled", event: "agent_start", state: .thinking, cwd: "/repo", source: .omp)
        XCTAssertEqual(server.handle(message: try JSONEncoder().encode(disabledHook)), .ignored)

        let direct = AgentStateEvent(
            agentId: "omp", sessionId: "direct", event: "agent_start", state: .thinking, cwd: "/repo")
        XCTAssertEqual(server.handle(message: try JSONEncoder().encode(direct)), .active(direct))

        let legacyJSON = try JSONSerialization.data(
            withJSONObject: [
                "agentId": "omp",
                "sessionId": "legacy",
                "event": "agent_start",
                "state": "thinking",
            ])
        XCTAssertEqual(server.handle(message: legacyJSON), .ignored)
    }

    @MainActor
    func testAgentStateServerRebindsWhenSocketNodeRemoved() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("clawdi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("agent-state.sock").path
        let server = AgentStateServer()
        defer { server.stop() }
        try server.start(socketPath: socketPath)

        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socketPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        // Simulate another Clawdi instance unlinking the shared socket path out from under us.
        try FileManager.default.removeItem(atPath: socketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))

        // Self-heal must recreate the node so new hook clients can connect again.
        server.ensureListening()
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socketPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let received = expectation(description: "event delivered after rebind")
        var output: AgentOutput?
        server.onOutput = { out in
            if case .active = out {
                output = out
                received.fulfill()
            }
        }
        let event = AgentStateEvent(
            agentId: "omp", sessionId: "omp-s", event: "turn_start", state: .thinking, cwd: "/repo"
        )
        let data = try JSONEncoder().encode(event)
        let conn = NWConnection(to: NWEndpoint.unix(path: socketPath), using: .tcp)
        conn.start(queue: .global(qos: .utility))
        conn.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { _ in conn.cancel() }
        )

        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(output, .active(event))
    }

    @MainActor
    func testEnsureListeningLeavesHealthySocketUntouched() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("clawdi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("agent-state.sock").path
        let server = AgentStateServer()
        defer { server.stop() }
        try server.start(socketPath: socketPath)

        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socketPath) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let before = try FileManager.default.attributesOfItem(atPath: socketPath)[.systemFileNumber] as? Int
        XCTAssertNotNil(before)

        // While the node is present, ensureListening must not tear down / rebind the live listener.
        server.ensureListening()
        try await Task.sleep(nanoseconds: 50_000_000)

        let after = try FileManager.default.attributesOfItem(atPath: socketPath)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "healthy socket should keep the same inode (no rebind)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    func testHookMapsAndRequiredStdoutResponses() throws {
        let claudeWorking = try XCTUnwrap(
            HookMapping.event(
                agent: "claude", event: "PreToolUse", input: ["session_id": "claude-session", "cwd": "/repo"]))
        XCTAssertEqual(claudeWorking.agentId, "claude-code")
        XCTAssertEqual(claudeWorking.sessionId, "claude-session")
        XCTAssertEqual(claudeWorking.cwd, "/repo")
        XCTAssertEqual(claudeWorking.state, .working)
        XCTAssertEqual(claudeWorking.source, .claudeCode)
        XCTAssertEqual(HookMapping.event(agent: "claude", event: "SessionStart", input: [:])?.state, .idle)
        XCTAssertEqual(HookMapping.event(agent: "claude", event: "SessionEnd", input: [:])?.state, .idle)
        XCTAssertEqual(HookMapping.event(agent: "claude", event: "UserPromptSubmit", input: [:])?.state, .thinking)
        XCTAssertEqual(
            HookMapping.event(agent: "claude", event: "PostToolUse", input: ["sessionId": "s"])?.state, .working)
        XCTAssertEqual(HookMapping.event(agent: "claude", event: "Stop", input: ["session_id": "s"])?.state, .complete)
        XCTAssertEqual(HookMapping.event(agent: "claude", event: "Notification", input: [:])?.state, .notification)
        XCTAssertEqual(HookMapping.event(agent: "claude", event: "PermissionRequest", input: [:])?.state, .notification)
        XCTAssertEqual(HookMapping.event(agent: "claude", event: "Elicitation", input: [:])?.state, .notification)
        XCTAssertEqual(HookMapping.event(agent: "claude", event: "PostToolUseFailure", input: [:])?.state, .error)
        XCTAssertEqual(HookMapping.event(agent: "claude", event: "StopFailure", input: [:])?.state, .error)
        // SRC maps exactly 11 events; everything else is ignored (no message).
        XCTAssertNil(HookMapping.event(agent: "claude", event: "SubagentStop", input: [:]))
        XCTAssertNil(HookMapping.event(agent: "claude", event: "Unknown", input: [:]))
        XCTAssertNil(HookMapping.response(agent: "claude", event: "Stop"))

        let antigravity = try XCTUnwrap(
            HookMapping.event(agent: "antigravity", event: "PostInvocation", input: ["projectPath": "/anti"]))
        XCTAssertEqual(antigravity.agentId, "antigravity")
        XCTAssertEqual(antigravity.sessionId, "/anti")
        XCTAssertEqual(antigravity.cwd, "/anti")
        XCTAssertEqual(antigravity.state, .complete)
        XCTAssertEqual(antigravity.source, .antigravity)
        XCTAssertEqual(HookMapping.event(agent: "antigravity", event: "PreInvocation", input: [:])?.state, .thinking)
        XCTAssertEqual(HookMapping.event(agent: "antigravity", event: "PostToolUse", input: [:])?.state, .working)
        XCTAssertEqual(
            HookMapping.event(agent: "antigravity", event: "PostToolUse", input: ["error": "boom"])?.state, .error)
        XCTAssertEqual(HookMapping.event(agent: "antigravity", event: "Stop", input: [:])?.state, .complete)
        XCTAssertEqual(
            HookMapping.event(agent: "antigravity", event: "Stop", input: ["fullyIdle": false])?.state, .working)
        // PreToolUse is response-only; PermissionRequest is not reported for Antigravity.
        XCTAssertNil(HookMapping.event(agent: "antigravity", event: "PreToolUse", input: [:]))
        XCTAssertNil(HookMapping.event(agent: "antigravity", event: "PermissionRequest", input: [:]))
        XCTAssertEqual(
            HookMapping.response(agent: "antigravity", event: "PreToolUse"),
            #"{"decision":"ask","reason":"Clawdi does not approve Antigravity tool calls automatically."}"#)
        XCTAssertEqual(HookMapping.response(agent: "antigravity", event: "PreInvocation"), "{}")
        XCTAssertEqual(HookMapping.response(agent: "antigravity", event: "Stop"), #"{"decision":"allow"}"#)
        XCTAssertEqual(
            HookMapping.response(agent: "antigravity", event: "PostInvocation"),
            #"{"injectSteps":[],"terminationBehavior":""}"#)
        XCTAssertEqual(HookMapping.response(agent: "antigravity", event: "PostToolUse"), "{}")

        let cursor = try XCTUnwrap(
            HookMapping.event(agent: "cursor", event: "beforeShellExecution", input: ["workspace": "/cursor"]))
        XCTAssertEqual(cursor.agentId, "cursor")
        XCTAssertEqual(cursor.sessionId, "/cursor")
        XCTAssertEqual(cursor.cwd, "/cursor")
        XCTAssertEqual(cursor.state, .notification)
        XCTAssertEqual(cursor.source, .cursor)
        XCTAssertNil(HookMapping.event(agent: "cursor", event: "afterFileEdit", input: [:]))
        XCTAssertEqual(
            HookMapping.response(agent: "cursor", event: "beforeShellExecution"),
            #"{"permission":"ask","user_message":"Clawdi noticed a Cursor shell command needs your approval.","agent_message":"Wait for the user to approve or deny this shell command."}"#
        )
        XCTAssertEqual(
            HookMapping.response(agent: "cursor", event: "beforeMCPExecution"),
            #"{"permission":"ask","user_message":"Clawdi noticed a Cursor MCP tool needs your approval.","agent_message":"Wait for the user to approve or deny this MCP tool call."}"#
        )

        let omp = try XCTUnwrap(
            HookMapping.event(
                agent: "omp",
                event: "tool_call",
                input: ["cwd": "/omp-repo", "session_id": "omp-s", "title": "Fix flaky tests"]
            ))
        XCTAssertEqual(omp.agentId, "omp")
        XCTAssertEqual(omp.sessionId, "omp-s")
        XCTAssertEqual(omp.cwd, "/omp-repo")
        XCTAssertEqual(omp.title, "Fix flaky tests")
        XCTAssertEqual(omp.state, .working)
        XCTAssertEqual(omp.source, .omp)
        XCTAssertEqual(HookMapping.event(agent: "omp", event: "session_start", input: [:])?.state, .idle)
        XCTAssertEqual(HookMapping.event(agent: "omp", event: "session_shutdown", input: [:])?.state, .idle)
        XCTAssertEqual(HookMapping.event(agent: "omp", event: "agent_start", input: [:])?.state, .thinking)
        XCTAssertEqual(HookMapping.event(agent: "omp", event: "turn_start", input: [:])?.state, .thinking)
        XCTAssertEqual(
            HookMapping.event(agent: "omp", event: "tool_result", input: ["session_id": "s"])?.state, .working)
        XCTAssertEqual(
            HookMapping.event(agent: "omp", event: "tool_result", input: ["error": true])?.state, .working,
            "per-tool failures keep the session working; the turn continues")
        // A successful edit is re-emitted as file_edit: still .working, but carrying per-file
        // ±line counts the pet throws as flying diff stats.
        let fileEdit = try XCTUnwrap(
            HookMapping.event(
                agent: "omp", event: "file_edit",
                input: [
                    "session_id": "s", "cwd": "/work/pi",
                    "files": [
                        ["path": "/work/pi/a/b/c.ts", "added": 12, "removed": 12],
                        ["path": "/work/pi/only-adds.ts", "added": 3, "removed": 0],
                    ],
                ]))
        XCTAssertEqual(fileEdit.state, .working)
        XCTAssertEqual(
            fileEdit.edits,
            [
                FileEditStat(path: "/work/pi/a/b/c.ts", added: 12, removed: 12),
                FileEditStat(path: "/work/pi/only-adds.ts", added: 3, removed: 0),
            ])
        // Only file_edit carries edits; a plain tool_result never does.
        XCTAssertNil(
            HookMapping.event(agent: "omp", event: "tool_result", input: ["session_id": "s"])?.edits)
        // Real omp events carry no flight tuning; demo-only flight/rise numbers ride along clamped.
        XCTAssertNil(fileEdit.editTuning)
        XCTAssertEqual(
            HookMapping.popTuning(["flight": 99.0, "rise": 0.0]),
            EditPopTuning(flight: 6, rise: 0.1))
        XCTAssertEqual(HookMapping.popTuning(["flight": 1.8]), EditPopTuning(flight: 1.8, rise: nil))
        XCTAssertNil(HookMapping.popTuning(["files": []]))
        XCTAssertEqual(HookMapping.event(agent: "omp", event: "ask_prompt", input: [:])?.state, .notification)
        XCTAssertEqual(HookMapping.event(agent: "omp", event: "plan_approval", input: [:])?.state, .notification)
        // Errors clear silently — no shake/alert reaction (the prior "omp hit an error" bubble was
        // removed because it fired mostly on transient subagent/queue noise the user couldn't act on).
        XCTAssertEqual(
            HookMapping.event(agent: "omp", event: "agent_error", input: ["session_id": "s"])?.state, .idle)
        // Completion comes from the main-session session_stop event carrying a session title.
        XCTAssertEqual(
            HookMapping.event(agent: "omp", event: "session_stop", input: ["session_id": "s", "title": "Fix tests"])?
                .state, .complete)
        // A no-title session_stop has nothing to announce: clear silently, no "finished" bubble.
        XCTAssertEqual(
            HookMapping.event(agent: "omp", event: "session_stop", input: ["session_id": "s"])?.state, .idle)
        // A cancelled or no-output stop carries `aborted`/`empty`; clear quietly rather than alert "done".
        XCTAssertEqual(
            HookMapping.event(
                agent: "omp", event: "session_stop", input: ["session_id": "s", "title": "x", "aborted": true])?.state,
            .idle)
        XCTAssertEqual(
            HookMapping.event(
                agent: "omp", event: "session_stop", input: ["session_id": "s", "title": "x", "empty": true])?.state,
            .idle)
        // agent_end fires for the main session AND every subagent, so it is always a quiet clear:
        // never a completion bubble, even with a session title (which a subagent's stop carries).
        XCTAssertEqual(
            HookMapping.event(agent: "omp", event: "agent_end", input: ["session_id": "s", "title": "Fix tests"])?
                .state, .idle)
        XCTAssertEqual(
            HookMapping.event(agent: "omp", event: "agent_end", input: ["session_id": "s"])?.state, .idle)
        // omp completion is agent-level; per-turn endings are ignored to avoid premature done alerts.
        XCTAssertNil(HookMapping.event(agent: "omp", event: "turn_end", input: ["session_id": "s"]))
        // omp reports only the lifecycle transitions above; anything else is ignored (no message).
        XCTAssertNil(HookMapping.event(agent: "omp", event: "context", input: [:]))
        // omp ignores Clawdi hook stdout, so no response is printed.
        XCTAssertNil(HookMapping.response(agent: "omp", event: "agent_end"))

        for response in [
            HookMapping.response(agent: "cursor", event: "beforeShellExecution"),
            HookMapping.response(agent: "antigravity", event: "PreToolUse"),
            HookMapping.response(agent: "antigravity", event: "Stop"),
            HookMapping.response(agent: "antigravity", event: "PostInvocation"),
        ] {
            let text = try XCTUnwrap(response)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(text.utf8)))
        }
    }

    func testOmpFileEditStatsParsingAndPopLabels() throws {
        // Zero-zero and pathless entries are dropped; negative counts clamp to zero (and thus drop
        // a fully-negative entry); the list caps at 8 so an edit storm can't flood the payload.
        let files: [[String: Any]] =
            [
                ["path": "/r/keep.ts", "added": 1, "removed": 0],
                ["path": "/r/none.ts", "added": 0, "removed": 0],
                ["added": 5, "removed": 5],
                ["path": "/r/negative.ts", "added": -3, "removed": -1],
            ] + (0..<10).map { ["path": "/r/f\($0).ts", "added": 1, "removed": 1] }
        let stats = HookMapping.editStats(["files": files])
        XCTAssertEqual(stats.count, 8)
        XCTAssertEqual(stats.first, FileEditStat(path: "/r/keep.ts", added: 1, removed: 0))
        XCTAssertFalse(stats.contains { $0.path.contains("none") || $0.path.contains("negative") })
        XCTAssertEqual(HookMapping.editStats([:]), [])
        XCTAssertEqual(HookMapping.editStats(["files": "nope"]), [])

        // Edits must survive the socket's JSON roundtrip — the custom Codable conformance would
        // silently drop them otherwise, and the pet would never see an edit to throw.
        let event = AgentStateEvent(
            agentId: "omp", sessionId: "s", event: "file_edit", state: .working, cwd: "/work/pi",
            edits: [FileEditStat(path: "/work/pi/a.ts", added: 2, removed: 1)], source: .omp)
        let round = try JSONDecoder().decode(AgentStateEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(round.edits, event.edits)

        // The demo CLI passes flight tuning after a colon; bare names and junk pairs stay safe.
        XCTAssertEqual(DemoCommand.parseTarget("edit").name, "edit")
        XCTAssertTrue(DemoCommand.parseTarget("edit").options.isEmpty)
        let tuned = DemoCommand.parseTarget("edit:flight=1.8,rise=0.6,junk,alsojunk=x")
        XCTAssertEqual(tuned.name, "edit")
        XCTAssertEqual(tuned.options, ["flight": 1.8, "rise": 0.6])

        // `project>file` labels: cwd basename + file basename; no cwd keeps just the file; long
        // file names keep their tail so the extension stays readable.
        XCTAssertEqual(EditPop.label(path: "/work/pi/bla/bla/bla/bla.ts", cwd: "/work/pi"), "pi>bla.ts")
        XCTAssertEqual(EditPop.label(path: "/work/pi/bla.ts", cwd: nil), "bla.ts")
        let long = EditPop.label(path: "/r/AVeryLongFileNameThatKeepsGoingForever.swift", cwd: "/r")
        XCTAssertEqual(long, "r>…KeepsGoingForever.swift")
    }

    func testOmpSessionStopCompletesWhileAgentEndClearsQuietly() throws {
        var machine = AgentStateMachine()
        let start = try XCTUnwrap(
            HookMapping.event(agent: "omp", event: "agent_start", input: ["session_id": "omp-s", "cwd": "/repo"]))
        XCTAssertEqual(machine.handle(start, now: 0), .active(start))

        // User cancels: session_stop carries `aborted`, so the active session clears without a "done" alert.
        let cancelled = try XCTUnwrap(
            HookMapping.event(
                agent: "omp", event: "session_stop", input: ["session_id": "omp-s", "cwd": "/repo", "aborted": true]))
        XCTAssertEqual(machine.handle(cancelled, now: 1), .cleared(cancelled))
        XCTAssertFalse(machine.hasActiveSessions)

        // A no-output settle carries `empty` and likewise clears silently.
        XCTAssertEqual(machine.handle(start, now: 2), .active(start))
        let empty = try XCTUnwrap(
            HookMapping.event(
                agent: "omp", event: "session_stop", input: ["session_id": "omp-s", "cwd": "/repo", "empty": true]))
        XCTAssertEqual(machine.handle(empty, now: 3), .cleared(empty))
        XCTAssertFalse(machine.hasActiveSessions)

        // A titled session_stop is the only completion path (the happy "title" finished. reaction).
        XCTAssertEqual(machine.handle(start, now: 4), .active(start))
        let done = try XCTUnwrap(
            HookMapping.event(
                agent: "omp", event: "session_stop",
                input: ["session_id": "omp-s", "cwd": "/repo", "title": "Ship it"]))
        XCTAssertEqual(machine.handle(done, now: 5), .complete(done))

        // A subagent (or the main session's trailing event) fires agent_end, which always clears
        // quietly — even with a session title it never surfaces a completion bubble.
        XCTAssertEqual(machine.handle(start, now: 6), .active(start))
        let subagentDone = try XCTUnwrap(
            HookMapping.event(
                agent: "omp", event: "agent_end",
                input: ["session_id": "omp-s", "cwd": "/repo", "title": "Subagent task"]))
        XCTAssertEqual(machine.handle(subagentDone, now: 7), .cleared(subagentDone))
        XCTAssertFalse(machine.hasActiveSessions)
    }

    func testOmpSessionStopCompletionSurvivesOutOfOrderAgentEnd() throws {
        // clawdi delivers each omp hook event from an independent process, so the main session's
        // trailing agent_end (.idle) can overtake its session_stop (.complete). The completion must
        // still surface even though agent_end already cleared the active session.
        var machine = AgentStateMachine()
        let start = try XCTUnwrap(
            HookMapping.event(agent: "omp", event: "agent_start", input: ["session_id": "omp-s", "cwd": "/repo"]))
        XCTAssertEqual(machine.handle(start, now: 0), .active(start))

        // The clear lands first and removes the active session.
        let cleared = try XCTUnwrap(
            HookMapping.event(agent: "omp", event: "agent_end", input: ["session_id": "omp-s", "cwd": "/repo"]))
        XCTAssertEqual(machine.handle(cleared, now: 1), .cleared(cleared))
        XCTAssertFalse(machine.hasActiveSessions)

        // The titled session_stop still fires the completion despite the active key being gone.
        let done = try XCTUnwrap(
            HookMapping.event(
                agent: "omp", event: "session_stop",
                input: ["session_id": "omp-s", "cwd": "/repo", "title": "Ship it"]))
        XCTAssertEqual(machine.handle(done, now: 2), .complete(done))

        // A non-session_stop completion with no live session stays ignored (claude's strict gate).
        let stray = AgentStateEvent(
            agentId: "claude-code", sessionId: "missing", event: "Stop", state: .complete, cwd: "/repo")
        XCTAssertEqual(machine.handle(stray, now: 3), .ignored)
    }

    func testAgentReactionRoutesOmpMomentsDistinctly() {
        func omp(_ event: String, title: String? = nil) -> AgentStateEvent {
            AgentStateEvent(agentId: "omp", sessionId: "s", event: event, state: .notification, cwd: "/r", title: title)
        }
        // Completion: happy jump + completion meow + plain bubble. omp leads with the session title.
        let done = AgentReaction.completion(for: omp("session_stop", title: "Fix tests"))
        XCTAssertEqual(done.animation, .jump)
        XCTAssertEqual(done.sound, .completion)
        XCTAssertEqual(done.bubbleKind, .notice)
        XCTAssertEqual(done.speech, "\"Fix tests\" finished.")
        // Errors are routed to .idle by HookMapping and never reach completion(for:); if one did
        // slip through, it still renders as a happy completion (no shake branch anymore).
        let failed = AgentReaction.completion(for: omp("agent_error"))
        XCTAssertEqual(failed.animation, .jump)
        XCTAssertEqual(failed.sound, .completion)
        XCTAssertEqual(failed.bubbleKind, .notice)
        // Ask prompt: a curious head-tilt.
        let ask = AgentReaction.notification(for: omp("ask_prompt"))
        XCTAssertEqual(ask.animation, .tilt)
        XCTAssertEqual(ask.speech, "omp has a question.")
        // Plan approval: a scale "pop".
        let plan = AgentReaction.notification(for: omp("plan_approval", title: "ship-it"))
        XCTAssertEqual(plan.animation, .pop)
        XCTAssertEqual(plan.speech, "omp wants plan approval: ship-it.")
        // Other agents' notifications keep the generic nudge with no body animation (no regression).
        let generic = AgentReaction.notification(
            for: AgentStateEvent(
                agentId: "claude-code", sessionId: "s", event: "PermissionRequest", state: .notification, cwd: "/r"))
        XCTAssertEqual(generic.animation, .none)
        XCTAssertEqual(generic.speech, "Claude Code needs attention.")
    }

    func testOmpFailedTurnClearsSilently() throws {
        var machine = AgentStateMachine()
        let start = try XCTUnwrap(
            HookMapping.event(agent: "omp", event: "agent_start", input: ["session_id": "omp-s", "cwd": "/repo"]))
        XCTAssertEqual(machine.handle(start, now: 0), .active(start))
        // A failed turn (agent_error) clears the session silently — no completion reaction, no shake.
        let failed = try XCTUnwrap(
            HookMapping.event(agent: "omp", event: "agent_error", input: ["session_id": "omp-s", "cwd": "/repo"]))
        XCTAssertEqual(failed.state, .idle)
        XCTAssertEqual(machine.handle(failed, now: 1), .cleared(failed))
        XCTAssertFalse(machine.hasActiveSessions)
    }

    func testDemoCommandEventsTriggerEachReaction() throws {
        XCTAssertEqual(DemoCommand.events(for: "complete"), ["agent_start", "session_stop"])
        XCTAssertEqual(DemoCommand.events(for: "ask"), ["ask_prompt"])
        XCTAssertEqual(DemoCommand.events(for: "plan"), ["plan_approval"])
        XCTAssertTrue(DemoCommand.events(for: "bogus").isEmpty)
        // `error` was removed: failures clear silently, so there is no error demo target.
        XCTAssertFalse(DemoCommand.names.contains("error"))
        XCTAssertFalse(DemoCommand.allNames.contains("error"))

        // Each demo name drives its reaction end-to-end through the real state machine (the demo CLI
        // sends exactly these events over the socket, including a session title for session_stop so
        // the completion gate in HookMapping fires).
        func run(_ name: String) throws -> AgentOutput {
            var machine = AgentStateMachine()
            var out = AgentOutput.ignored
            for event in DemoCommand.events(for: name) {
                var input: [String: Any] = ["session_id": "demo-\(name)", "cwd": "/r"]
                // session_stop needs a session title to trip the completion gate in HookMapping;
                // ask/plan/knead events are unaffected by the title, so mirror only what matters.
                if event == "session_stop" { input["title"] = "demo: \(event)" }
                let stateEvent = try XCTUnwrap(HookMapping.event(agent: "omp", event: event, input: input))
                out = machine.handle(stateEvent, now: 0)
            }
            return out
        }
        XCTAssertEqual(
            try run("complete"),
            .complete(try omp("session_stop", "demo-complete", title: "demo: session_stop")))
        XCTAssertEqual(try run("ask"), .notification(try omp("ask_prompt", "demo-ask")))
        XCTAssertEqual(try run("plan"), .notification(try omp("plan_approval", "demo-plan")))

        // Knead demo: agent_start holds a thinking session open (the cat kneads while it lasts);
        // session_shutdown clears it silently — no completion jump on the way out.
        XCTAssertEqual(DemoCommand.events(for: "knead"), ["agent_start", "session_shutdown"])
        XCTAssertGreaterThanOrEqual(DemoCommand.gap(for: "knead"), 5, "hold spans several knead cycles")
        XCTAssertFalse(DemoCommand.allNames.contains("knead"), "the long hold stays out of `all`")
        var machine = AgentStateMachine()
        _ = machine.handle(try omp("agent_start", "demo-knead"), now: 0)
        XCTAssertTrue(machine.hasActiveSessions, "knead demo holds a thinking session open")
        let ended = machine.handle(try omp("session_shutdown", "demo-knead"), now: 1)
        XCTAssertFalse(machine.hasActiveSessions, "shutdown clears the synthetic session")
        if case .complete = ended { XCTFail("knead demo must end silently, not with a completion reaction") }
    }

    private func omp(_ event: String, _ session: String, title: String? = nil) throws -> AgentStateEvent {
        var input: [String: Any] = ["session_id": session, "cwd": "/r"]
        if let title { input["title"] = title }
        return try XCTUnwrap(HookMapping.event(agent: "omp", event: event, input: input))
    }

    func testHookCommandModeRequiresExplicitFlagAndMapsPayload() throws {
        XCTAssertNil(
            HookCommand.mapIfRequested(
                arguments: ["Clawdi", "Stop"],
                input: ["session_id": "ignored"]
            ))

        let cursor = try XCTUnwrap(
            HookCommand.mapIfRequested(
                arguments: ["Clawdi", HookCommand.flag, "cursor:beforeShellExecution"],
                input: ["workspace": "/cursor"]
            ))
        XCTAssertEqual(cursor.event?.agentId, "cursor")
        XCTAssertEqual(cursor.event?.state, .notification)
        XCTAssertEqual(cursor.response, HookMapping.response(agent: "cursor", event: "beforeShellExecution"))

        let claude = try XCTUnwrap(
            HookCommand.mapIfRequested(
                arguments: ["Clawdi", HookCommand.flag],
                input: ["hook_event_name": "UserPromptSubmit", "session_id": "claude-session"]
            ))
        XCTAssertEqual(claude.event?.agentId, "claude-code")
        XCTAssertEqual(claude.event?.sessionId, "claude-session")
        XCTAssertEqual(claude.event?.state, .thinking)
    }

    func testHookInstallerConfigMergesAreIdempotentInTemporaryHome() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let helper = dir.appendingPathComponent("Clawdi.app/Contents/MacOS/Clawdi").path
        let installer = HookInstaller(home: dir, helperPath: helper)

        let claudeURL = dir.appendingPathComponent(".claude/settings.json")
        let geminiURL = dir.appendingPathComponent(".gemini/config/hooks.json")
        let cursorURL = dir.appendingPathComponent(".cursor/hooks.json")
        let claudeFixture: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": "/old/other-tool-hook PreToolUse"]
                        ],
                    ]
                ],
                "Stop": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": "/stale/clawdi-hook Stop"]
                        ],
                    ]
                ],
            ],
            "keep": true,
        ]
        try writeJSONObject(claudeFixture, to: claudeURL)
        try writeJSONObject(
            [
                "existing": ["enabled": true],
                "clawdi": [
                    "PreToolUse": [
                        "hooks": [["type": "command", "command": "/stale/clawdi-hook antigravity:PreToolUse"]]
                    ]
                ],
            ], to: geminiURL)
        try writeJSONObject(
            [
                "other": ["command": "/other/hook"],
                "beforeShellExecution": ["command": "/stale/clawdi-hook cursor:beforeShellExecution"],
            ], to: cursorURL)

        try installer.installAll()
        try installer.installAll()

        let claude = try readJSONObject(claudeURL)
        XCTAssertEqual(claude["keep"] as? Bool, true)
        let claudeCommands = commands(in: claude)
        XCTAssertEqual(claudeCommands.filter { $0 == "/old/other-tool-hook PreToolUse" }.count, 1)
        for event in [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
            "PostToolUseFailure", "Stop", "StopFailure", "Notification", "Elicitation",
        ] {
            XCTAssertEqual(claudeCommands.filter { isClawdiCommand($0, suffix: event) }.count, 1, event)
        }
        for staleEvent in ["SubagentStop", "PreCompact", "Error"] {
            XCTAssertEqual(claudeCommands.filter { isClawdiCommand($0, suffix: staleEvent) }.count, 0, staleEvent)
        }

        let gemini = try readJSONObject(geminiURL)
        XCTAssertNotNil(gemini["existing"])
        let geminiCommands = commands(in: gemini)
        for event in ["PostToolUse", "PreInvocation", "PostInvocation", "Stop"] {
            XCTAssertEqual(
                geminiCommands.filter { isClawdiCommand($0, suffix: "antigravity:\(event)") }.count, 1, event)
        }
        // SRC does not register these for Antigravity; the stale PreToolUse fixture must be removed.
        for event in ["PreToolUse", "PermissionRequest"] {
            XCTAssertEqual(
                geminiCommands.filter { isClawdiCommand($0, suffix: "antigravity:\(event)") }.count, 0, event)
        }

        let cursorConfig = try readJSONObject(cursorURL)
        XCTAssertNotNil(cursorConfig["other"])
        let cursorCommands = commands(in: cursorConfig)
        XCTAssertEqual(cursorCommands.filter { $0 == "/other/hook" }.count, 1)
        XCTAssertEqual(cursorCommands.filter { isClawdiCommand($0, suffix: "cursor:beforeShellExecution") }.count, 1)
        XCTAssertEqual(cursorCommands.filter { isClawdiCommand($0, suffix: "cursor:beforeMCPExecution") }.count, 1)

        try installer.reconcile(enabled: [])

        let disabledClaude = try readJSONObject(claudeURL)
        XCTAssertFalse(commands(in: disabledClaude).contains { $0.contains("--clawdi-hook") })
        XCTAssertEqual(disabledClaude["keep"] as? Bool, true)

        let disabledGemini = try readJSONObject(geminiURL)
        XCTAssertNil(disabledGemini["clawdi"])
        XCTAssertNotNil(disabledGemini["existing"])

        let disabledCursor = try readJSONObject(cursorURL)
        XCTAssertFalse(commands(in: disabledCursor).contains { $0.contains("--clawdi-hook") })
        XCTAssertNotNil(disabledCursor["other"])

        let ompURL = dir.appendingPathComponent(".omp/agent/extensions/clawdi-omp-hook.js")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ompURL.path))
    }

    func testOmpExtensionModuleInstallIsIdempotentAndImportable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("Clawdi.app/Contents/MacOS/Clawdi").path
        let installer = HookInstaller(home: dir, helperPath: helper)

        try installer.installOmp()
        try installer.installOmp()

        let extDir = dir.appendingPathComponent(".omp/agent/extensions")
        let entries = try FileManager.default.contentsOfDirectory(atPath: extDir.path).sorted()
        XCTAssertEqual(entries, ["clawdi-omp-hook.js"], "exactly one module, no leftover tmp files")

        let source = try String(contentsOf: extDir.appendingPathComponent("clawdi-omp-hook.js"), encoding: .utf8)
        XCTAssertTrue(source.contains("export default function"), "must export a factory for the loader")
        XCTAssertTrue(source.contains("pi.on("), "must register lifecycle handlers")
        XCTAssertTrue(source.contains(#""--clawdi-hook", "omp:" + event"#), "must invoke Clawdi hook mode")
        XCTAssertTrue(source.contains(helper), "must bake in the absolute helper path")
        let ompEvents = [
            "session_start", "agent_start", "turn_start", "tool_call", "tool_result",
            "agent_end", "session_stop", "session_shutdown",
        ]
        for event in ompEvents {
            XCTAssertTrue(source.contains("\"\(event)\""), event)
        }
        XCTAssertFalse(source.contains("\"turn_end\""), "completion is session-level, not per-turn")
        XCTAssertTrue(source.contains("getSessionName"), "completion payload should include the current omp title")
        XCTAssertTrue(
            source.contains("\"session_stop\""), "completion must be driven by the main-only session_stop event")
        XCTAssertTrue(source.contains("\"ask_prompt\""), "ask tool calls should request attention")
        XCTAssertTrue(
            source.contains("stopReason") && source.contains("aborted"),
            "cancelled turns must be detected via the aborted assistant stopReason")
        XCTAssertTrue(source.contains("payload.aborted = true"), "a cancelled agent_end must forward the aborted flag")
        XCTAssertTrue(source.contains("payload.empty = true"), "a no-output agent_end must clear without alerting")
        XCTAssertTrue(source.contains("\"plan_approval\""), "plan-mode approval requests should request attention")
        XCTAssertTrue(
            source.contains("\"agent_error\"") && source.contains(#"reason === "error""#),
            "a failed turn should be re-emitted as the agent_error event")
        XCTAssertTrue(
            source.contains("errorMessage") && source.contains("abort"),
            "an abort that surfaces as stopReason error must still be treated as a quiet cancel, not an error")
        XCTAssertTrue(source.contains("\"resolve\""), "plan approval is detected from the resolve tool call")
        XCTAssertTrue(
            source.contains("\"file_edit\"") && source.contains("perFileResults"),
            "successful edit results must be re-emitted as file_edit with per-file diff counts")
        XCTAssertTrue(
            source.contains("payload.files = files"),
            "file_edit must carry the per-file ±line counts the pet renders as flying diff stats")
    
        // Generated module must be valid JavaScript that parses without syntax errors (e.g. unescaped newlines).
        let scriptPath = extDir.appendingPathComponent("clawdi-omp-hook.js").path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "export PATH=\"$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; bun build \(scriptPath) --no-bundle 2>&1 || node --input-type=module -e 'import(\"\(scriptPath)\")' 2>&1"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, "generated omp hook module must parse cleanly: \(output)")}

    func testShareCropCenteredNineBySixteenCrop() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 2560)
        let pet = CGRect(x: 510, y: 1200, width: 180, height: 200)

        let crop = ShareCrop.rect(display: display, petFrame: pet)

        XCTAssertEqual(crop, CGRect(x: 240, y: 612, width: 720, height: 1280))
        assertShareCropInvariants(crop, display: display)
        XCTAssertEqual(crop.midX, pet.midX)
        XCTAssertEqual(crop.midY, pet.midY - pet.height * 0.24)
    }

    func testShareCropClampsAgainstAllDisplayEdgeGuards() {
        let display = CGRect(x: -640, y: 80, width: 1440, height: 2560)
        let centeredY: CGFloat = 1200
        let centeredX: CGFloat = -230
        let size = CGSize(width: 180, height: 200)

        let left = ShareCrop.rect(
            display: display, petFrame: CGRect(origin: CGPoint(x: -630, y: centeredY), size: size))
        XCTAssertEqual(left.minX, display.minX + ShareCrop.guardX)

        let right = ShareCrop.rect(
            display: display, petFrame: CGRect(origin: CGPoint(x: 700, y: centeredY), size: size))
        XCTAssertEqual(right.maxX, display.maxX - ShareCrop.guardX)

        let bottom = ShareCrop.rect(
            display: display, petFrame: CGRect(origin: CGPoint(x: centeredX, y: 90), size: size))
        XCTAssertEqual(bottom.minY, display.minY + ShareCrop.guardBottom)

        let top = ShareCrop.rect(display: display, petFrame: CGRect(origin: CGPoint(x: centeredX, y: 2400), size: size))
        XCTAssertEqual(top.maxY, display.maxY - ShareCrop.guardTop)

        for crop in [left, right, bottom, top] {
            assertShareCropInvariants(crop, display: display)
        }
    }

    func testShareCropRoundsAllRectValuesToEvenIntegers() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 2560)
        let pet = CGRect(x: 300.3, y: 500.7, width: 123.25, height: 111.5)

        let crop = ShareCrop.rect(display: display, petFrame: pet)

        let idealWidth = pet.width * 4
        let idealHeight = idealWidth * 16 / 9
        XCTAssertEqual(crop.width, evenRounded(idealWidth))
        XCTAssertEqual(crop.height, evenRounded(idealHeight))
        XCTAssertEqual(crop.minX, evenRounded(pet.midX - crop.width / 2))
        XCTAssertEqual(crop.minY, evenRounded(pet.midY - pet.height * 0.24 - crop.height / 2))
        assertShareCropInvariants(crop, display: display)
    }

    func testShareCropKeyframeInterpolationRoundsAllValuesEvenly() {
        let start = CGRect(x: 1, y: 3, width: 101, height: 203)
        let end = CGRect(x: 12, y: 28, width: 124, height: 247)

        XCTAssertEqual(
            ShareCrop.interpolate(start, end, t: 0),
            CGRect(
                x: evenRounded(start.minX), y: evenRounded(start.minY), width: evenRounded(start.width),
                height: evenRounded(start.height)))
        XCTAssertEqual(
            ShareCrop.interpolate(start, end, t: 0.25),
            CGRect(x: evenRounded(3.75), y: evenRounded(9.25), width: evenRounded(106.75), height: evenRounded(214)))
        XCTAssertEqual(
            ShareCrop.interpolate(start, end, t: 0.5),
            CGRect(x: evenRounded(6.5), y: evenRounded(15.5), width: evenRounded(112.5), height: evenRounded(225)))
        XCTAssertEqual(
            ShareCrop.interpolate(start, end, t: 1),
            CGRect(
                x: evenRounded(end.minX), y: evenRounded(end.minY), width: evenRounded(end.width),
                height: evenRounded(end.height)))
        let display = CGRect(x: 0, y: 0, width: 2_000, height: 4_000)
        let pet = CGRect(x: 800, y: 1_000, width: 100, height: 100)
        XCTAssertEqual(
            ShareCrop.interpolatedRect(display: display, from: pet, to: pet.offsetBy(dx: 200, dy: 0), t: 0.5),
            ShareCrop.rect(display: display, petFrame: pet.offsetBy(dx: 100, dy: 0))
        )
    }

    private func assertShareCropInvariants(
        _ rect: CGRect, display: CGRect, file: StaticString = #filePath, line: UInt = #line
    ) {
        assertEvenIntegral(rect, file: file, line: line)
        XCTAssertEqual(rect.width / rect.height, 9.0 / 16.0, accuracy: 0.002, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minX, display.minX + ShareCrop.guardX, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, display.maxX - ShareCrop.guardX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, display.minY + ShareCrop.guardBottom, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, display.maxY - ShareCrop.guardTop, file: file, line: line)
    }

    private func evenRounded(_ value: CGFloat) -> CGFloat {
        CGFloat(Int(value.rounded()) & ~1)
    }

    private func assertEvenIntegral(_ rect: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        for value in [rect.minX, rect.minY, rect.width, rect.height] {
            XCTAssertEqual(value.rounded(), value, file: file, line: line)
            XCTAssertEqual(Int(value) % 2, 0, file: file, line: line)
        }
    }

    private func commands(in value: Any) -> [String] {
        if let dict = value as? [String: Any] {
            return dict.flatMap { key, value -> [String] in
                var found = commands(in: value)
                if key == "command", let command = value as? String {
                    found.append(command)
                }
                return found
            }
        }
        if let array = value as? [Any] {
            return array.flatMap { commands(in: $0) }
        }
        return []
    }

    private func isClawdiCommand(_ command: String, suffix: String) -> Bool {
        command.contains(HookCommand.flag) && command.hasSuffix(" \(suffix)")
    }
    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerializationData(object).write(to: url)
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func JSONSerializationData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private struct ImageDiffStats {
        let opaquePixels: Int
        let differingPixels: Int
        let largestRegion: Int

        var fraction: Double {
            Double(differingPixels) / Double(max(1, opaquePixels))
        }
    }

    private func assertLayeredMatchesMonolithic(
        poses: PoseLibrary,
        mappings: CellMappings,
        state: RenderState,
        scale: CGFloat,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let monolithic = PixelCompositor(library: poses, mappings: mappings)
        monolithic.forceMonolithic = true
        let layered = PixelCompositor(library: poses, mappings: mappings)
        let expected = try XCTUnwrap(monolithic.render(state: state, scale: scale), file: file, line: line)
        let actual = try XCTUnwrap(layered.render(state: state, scale: scale), file: file, line: line)

        XCTAssertEqual(actual.width, expected.width, label, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, label, file: file, line: line)
        guard actual.width == expected.width, actual.height == expected.height else { return }

        let stats = try perceptualDiff(expected: expected, actual: actual, channelThreshold: 8)
        let patterned = PatternPart.allCases.contains { !state.pattern.spots(for: $0).isEmpty }
        let fractionLimit = scale >= 2 ? (patterned ? 0.20 : 0.12) : 0.001
        let regionLimit = max(32, stats.opaquePixels / (patterned ? 4 : 12))
        XCTAssertLessThanOrEqual(
            stats.fraction,
            fractionLimit,
            "\(label) diff fraction \(stats.fraction)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            stats.largestRegion,
            regionLimit,
            "\(label) contiguous diff \(stats.largestRegion)",
            file: file,
            line: line
        )
    }

    private func perceptualDiff(expected: CGImage, actual: CGImage, channelThreshold: Int) throws -> ImageDiffStats {
        let expectedData = try XCTUnwrap(expected.dataProvider?.data)
        let actualData = try XCTUnwrap(actual.dataProvider?.data)
        let expectedBytes = try XCTUnwrap(CFDataGetBytePtr(expectedData))
        let actualBytes = try XCTUnwrap(CFDataGetBytePtr(actualData))
        let expectedLength = CFDataGetLength(expectedData)
        let actualLength = CFDataGetLength(actualData)
        var differing = [Bool](repeating: false, count: expected.width * expected.height)
        var opaquePixels = 0
        var differingPixels = 0

        for row in 0..<expected.height {
            for column in 0..<expected.width {
                let expectedOffset = row * expected.bytesPerRow + column * 4
                let actualOffset = row * actual.bytesPerRow + column * 4
                guard expectedOffset + 3 < expectedLength, actualOffset + 3 < actualLength else { continue }
                let expectedAlpha = expectedBytes[expectedOffset + 3]
                let actualAlpha = actualBytes[actualOffset + 3]
                guard expectedAlpha > 0 || actualAlpha > 0 else { continue }
                opaquePixels += 1

                var maxDelta = 0
                for channel in 0..<4 {
                    let delta = abs(
                        Int(expectedBytes[expectedOffset + channel]) - Int(actualBytes[actualOffset + channel]))
                    maxDelta = max(maxDelta, delta)
                }
                if maxDelta > channelThreshold {
                    differingPixels += 1
                    differing[row * expected.width + column] = true
                }
            }
        }

        return ImageDiffStats(
            opaquePixels: opaquePixels,
            differingPixels: differingPixels,
            largestRegion: largestRegion(in: differing, width: expected.width, height: expected.height)
        )
    }

    private func largestRegion(in differing: [Bool], width: Int, height: Int) -> Int {
        var visited = [Bool](repeating: false, count: differing.count)
        var largest = 0
        var stack: [Int] = []
        stack.reserveCapacity(64)

        for index in differing.indices where differing[index] && !visited[index] {
            visited[index] = true
            stack.append(index)
            var size = 0
            while let current = stack.popLast() {
                size += 1
                let row = current / width
                let column = current % width
                let neighbors = [
                    row > 0 ? current - width : nil,
                    row + 1 < height ? current + width : nil,
                    column > 0 ? current - 1 : nil,
                    column + 1 < width ? current + 1 : nil,
                ]
                for neighbor in neighbors.compactMap({ $0 }) where differing[neighbor] && !visited[neighbor] {
                    visited[neighbor] = true
                    stack.append(neighbor)
                }
            }
            largest = max(largest, size)
        }

        return largest
    }
    private func containsNode(_ node: SceneNode, where predicate: (SceneNode) -> Bool) -> Bool {
        if predicate(node) { return true }
        return node.children.contains { containsNode($0, where: predicate) }
    }

    private func countPixels(in image: CGImage, matching rgb: (UInt8, UInt8, UInt8)) -> Int {
        countPixels(in: image) { red, green, blue, alpha in
            red == rgb.0 && green == rgb.1 && blue == rgb.2 && alpha > 0
        }
    }

    private func pixelBounds(in image: CGImage, matching rgb: (UInt8, UInt8, UInt8)) -> CGRect? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let length = CFDataGetLength(data)
        let rowStride = image.bytesPerRow
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1

        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * rowStride + column * 4
                guard offset + 3 < length else { continue }
                if bytes[offset] == rgb.0, bytes[offset + 1] == rgb.1, bytes[offset + 2] == rgb.2, bytes[offset + 3] > 0
                {
                    minX = min(minX, column)
                    minY = min(minY, row)
                    maxX = max(maxX, column)
                    maxY = max(maxY, row)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }
    private func countPixels(in image: CGImage, matching predicate: (UInt8, UInt8, UInt8, UInt8) -> Bool) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var count = 0
        for i in stride(from: 0, to: CFDataGetLength(data), by: 4) {
            if predicate(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) {
                count += 1
            }
        }
        return count
    }
    func testLiftPlacementPinsHeadAndDanglesBelowRestingSquare() {
        // Lifting must render at least as large as the fit-to-square path (the old shrink), pin the
        // head in the top region, stay centered, and hang below the resting square.
        let catRect = CGRect(x: 10, y: 0, width: 480, height: 480)
        let lifted = CatLayout.liftedRect(imageWidth: 40, imageHeight: 145, in: catRect)
        let fitted = CatLayout.fittedRect(imageWidth: 40, imageHeight: 145, in: catRect)
        XCTAssertGreaterThan(lifted.width, fitted.width, "lift renders larger than fit-to-square (no shrink)")
        XCTAssertEqual(lifted.midX, catRect.midX, accuracy: 0.5, "stays horizontally centered")
        XCTAssertEqual(lifted.minY, catRect.minY + CatLayout.liftHeadInset * catRect.height, accuracy: 0.5)
        XCTAssertLessThan(lifted.minY, catRect.midY, "head stays in the top region")
        XCTAssertGreaterThan(lifted.maxY, catRect.maxY, "body hangs below the resting square")
    }

    func testWindowReservesDangleRoomWithoutResizingRestingCat() {
        for petSize in [40, 100, 240] {
            let resting = WindowGeometry.restingHeight(petSize: petSize)
            let size = WindowGeometry.windowSize(petSize: petSize)
            XCTAssertEqual(
                WindowGeometry.catSide(petSize: petSize),
                min(WindowGeometry.windowWidth(petSize: petSize), resting), accuracy: 0.5,
                "resting cat square is unchanged from min(width, restingHeight)")
            XCTAssertGreaterThanOrEqual(size.width, WindowGeometry.windowWidth(petSize: petSize))
            let catTop = (resting - WindowGeometry.catSide(petSize: petSize)) * WindowGeometry.catTopFraction
            let sky = WindowGeometry.skyRoom(petSize: petSize)
            XCTAssertGreaterThanOrEqual(
                size.height, sky + catTop + WindowGeometry.catSide(petSize: petSize) + 1,
                "window reserves sky room above and hang room below the resting cat")
            XCTAssertGreaterThanOrEqual(
                sky, WindowGeometry.catSide(petSize: petSize) * 0.6 - 1,
                "sky room covers an edit-pop apex up to 1x the pet square above the chin launch point")
        }
    }

    @MainActor
    func testLiftRenderKeepsHeadSizeAndElongatesDownward() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        let size = WindowGeometry.windowSize(petSize: 100)
        let width = Int(size.width)
        let height = Int(size.height)
        // The cat now lives in `CatLayerTree` sublayers, which `cacheDisplay` skips; render the
        // whole backing-layer tree instead. Offscreen layer rendering can resolve with either
        // vertical parity, so boxes are normalized via the idle render (the resting cat is
        // known to sit in the window's top half).
        func darkBox(_ state: RenderState) throws -> CGRect {
            let view = PetView(frame: CGRect(origin: .zero, size: size), compositor: compositor, state: state)
            view.restingHeight = WindowGeometry.restingHeight(petSize: 100)
            view.state = state
            view.layoutSubtreeIfNeeded()
            let ctx = try XCTUnwrap(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            func renderLayers(_ v: NSView) {
                v.layer?.render(in: ctx)
                for sub in v.subviews { renderLayers(sub) }
            }
            renderLayers(view)
            let data = try XCTUnwrap(ctx.data)
            let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            var minX = Int.max
            var minY = Int.max
            var maxX = -1
            var maxY = -1
            for row in stride(from: 0, to: height, by: 2) {
                for col in stride(from: 0, to: width, by: 2) {
                    let index = (row * width + col) * 4
                    guard bytes[index + 3] > 128, bytes[index] < 64, bytes[index + 1] < 64, bytes[index + 2] < 64
                    else { continue }
                    minX = min(minX, col)
                    minY = min(minY, row)
                    maxX = max(maxX, col)
                    maxY = max(maxY, row)
                }
            }
            XCTAssertGreaterThanOrEqual(maxX, minX, "render produced no dark cat pixels")
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        // Measure the cat alone: the dark name badge is chrome, not silhouette.
        var idle = RenderState()
        idle.showName = false
        var lift = idle
        lift.pose = .stretchEnd
        lift.mochiStretchActive = true
        lift.stretchT = 0.5  // controller caps the lift morph here at full pull
        lift.stretchSegmentDX = Array(repeating: 0, count: StretchChain.segmentCount)
        var idleBox = try darkBox(idle)
        var liftBox = try darkBox(lift)
        if idleBox.midY > CGFloat(height) / 2 {
            // Offscreen pass rendered bottom-up: mirror both boxes into top-down coordinates.
            idleBox.origin.y = CGFloat(height) - idleBox.maxY
            liftBox.origin.y = CGFloat(height) - liftBox.maxY
        }
        // The old behavior collapsed the cat to ~1/3 width; the anchored dangle keeps near-full width.
        XCTAssertGreaterThan(liftBox.width, idleBox.width * 0.6, "lift must not shrink the cat")
        // Head stays anchored near the idle top rather than popping/collapsing.
        XCTAssertLessThan(abs(liftBox.minY - idleBox.minY), idleBox.height * 0.4, "head stays near idle top")
        // Body elongates well below the resting silhouette.
        XCTAssertGreaterThan(liftBox.maxY, idleBox.maxY + idleBox.height * 0.5, "body dangles below resting")
    }

    @MainActor
    func testCatDrawRectCapsToRestingHeightButFillsExpandedWindow() throws {
        let poses = try PoseLibrary.load(bundle: Bundle.main)
        let mappings = try CellMappings.load(bundle: Bundle.main)
        let compositor = PixelCompositor(library: poses, mappings: mappings)
        func rect(_ bounds: CGSize, resting: CGFloat) -> CGRect {
            let view = PetView(frame: CGRect(origin: .zero, size: bounds), compositor: compositor, state: RenderState())
            view.restingHeight = resting
            return view.catDrawRect()
        }
        // Dangle-room window: cat keeps the resting square at the top, room reserved below.
        let normal = rect(CGSize(width: 500, height: 1123), resting: 480)
        XCTAssertEqual(normal.height, 480, accuracy: 0.5)
        XCTAssertEqual(normal.minY, 0, accuracy: 0.5)
        // Temporarily expanded square (stretch/focus sequences): cat fills the window.
        let expanded = rect(CGSize(width: 1000, height: 1000), resting: 1000)
        XCTAssertEqual(expanded.height, 1000, accuracy: 0.5)
        // Unconfigured views fall back to bounds.
        let unconfigured = rect(CGSize(width: 250, height: 250), resting: 0)
        XCTAssertEqual(unconfigured.height, 250, accuracy: 0.5)
    }

    func testGenerationalCacheRetainsLastTwoGenerationsAfterRotation() {
        let capacity = 4
        var cache = GenerationalCache<Int, String>(hotBudget: capacity, cost: { _ in 1 })

        for key in 1...12 {
            cache[key] = "value-\(key)"
        }

        let populated = cache
        for key in 5...12 {
            var probe = populated
            XCTAssertEqual(probe[key], "value-\(key)", "recent key \(key) should remain cached")
        }
        for key in 1...4 {
            var probe = populated
            XCTAssertNil(probe[key], "key \(key) should be older than the retained generations")
        }
    }

    func testGenerationalCachePromotionKeepsReadEntryAliveAcrossManyRotations() {
        let capacity = 4
        var cache = GenerationalCache<Int, String>(hotBudget: capacity, cost: { _ in 1 })
        cache[0] = "anchor"

        for key in 1...32 {
            XCTAssertEqual(cache[0], "anchor", "anchor should be promoted before inserting key \(key)")
            cache[key] = "value-\(key)"
        }

        let populated = cache
        var anchorProbe = populated
        XCTAssertEqual(anchorProbe[0], "anchor")
        var staleProbe = populated
        XCTAssertNil(staleProbe[1], "an unpromoted early key should still age out")
    }

    func testGenerationalCacheOverwriteUpdatesWithoutRotatingAtCapacity() {
        let capacity = 2
        var cache = GenerationalCache<Int, String>(hotBudget: capacity, cost: { _ in 1 })
        cache[1] = "one"
        cache[2] = "two"

        cache[1] = "ONE"
        XCTAssertEqual(cache[1], "ONE")

        cache[3] = "three"
        cache[4] = "four"

        let populated = cache
        var updatedProbe = populated
        XCTAssertEqual(updatedProbe[1], "ONE")
        var retainedProbe = populated
        XCTAssertEqual(retainedProbe[2], "two", "overwriting an existing key must not consume a generation")
        var newestProbe = populated
        XCTAssertEqual(newestProbe[3], "three")
        var hotProbe = populated
        XCTAssertEqual(hotProbe[4], "four")
    }

    func testGenerationalCacheRotatesByCostNotCount() {
        var cache = GenerationalCache<String, Int>(hotBudget: 10, cost: { $0 })
        cache["a"] = 4
        cache["b"] = 4
        cache["c"] = 4  // 8 + 4 > 10: a/b rotate to cold
        cache["d"] = 8  // 4 + 8 > 10: c rotates to cold, a/b drop

        let populated = cache
        for key in ["c", "d"] {
            var probe = populated
            XCTAssertNotNil(probe[key], "\(key) should still be cached")
        }
        for key in ["a", "b"] {
            var probe = populated
            XCTAssertNil(probe[key], "\(key) should be evicted once newer entries exceed the byte budget")
        }
    }

    func testGenerationalCacheNilSetRemovesHotAndColdEntries() {
        var hotCache = GenerationalCache<Int, String>(hotBudget: 2, cost: { _ in 1 })
        hotCache[1] = "one"
        hotCache[1] = nil
        XCTAssertNil(hotCache[1])

        var coldCache = GenerationalCache<Int, String>(hotBudget: 2, cost: { _ in 1 })
        coldCache[1] = "one"
        coldCache[2] = "two"
        coldCache[3] = "three"

        coldCache[1] = nil
        XCTAssertNil(coldCache[1])
        XCTAssertEqual(coldCache[2], "two", "removing one cold key should leave the other cold entries available")
    }
}
