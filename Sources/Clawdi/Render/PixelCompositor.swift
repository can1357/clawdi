import AppKit
import CoreGraphics
import Foundation

struct PixelCompositorCacheStats {
    var frameHits = 0
    var frameMisses = 0
    var layerRasterHits = 0
    var layerRasterMisses = 0
    var outlineHits = 0
    var outlineMisses = 0
}

final class PixelCompositor {
    // Hunting/crouch enlarges the 3px pupils inside a 5px sclera, leaving about 0.5px of safe travel.
    private static let huntingPupilScale: CGFloat = 1.33
    private static let huntingPupilTrackingScale: CGFloat = 0.31
    /// Below this supersample scale the per-slot rasters are too coarse to reassemble cleanly:
    /// `render(state:scale:)` rasterizes monolithically, and `layeredFrame` supersamples up to it.
    private static let layeredMinimumScale: CGFloat = 2
    /// One full thinking-time knead cycle: each front paw presses once, half a cycle apart.
    static let kneadPeriod: TimeInterval = 1.8
    // Silhouette tracking MUST bucket at this same density (see trackingSilhouetteSignature): the
    // outline underlay is composited under a fill drawn at the live tracking offset, so a coarser
    // outline bucket leaves the outline trailing the moving face/petals a whole step behind.
    private static let visualTrackingBucketsPerPoint: CGFloat = 4

    private let library: PoseLibrary
    private let mappings: CellMappings
    private var pathCache: [String: CGPath] = [:]
    private var clipPathCache: [String: [String: SceneNode]] = [:]
    private var outlineTempAlpha = [UInt8]()
    private var outlineDeque = [Int]()
    var forceMonolithic = false
    /// Cat-only: drives the mochi stretch lift geometry in `PetView`. Sprite-free skins keep stretch
    /// inside the resting square and set this false.
    var usesMochiLift = true
    /// Skip drawing the user's `RenderState.pattern` spots (head/body/tail/leg patches).
    /// Fixed-palette skins like `flower-claude` own their colors and must not inherit the user's
    /// tabby/cow stripes; setting this true prevents those spots from leaking onto the rig.
    var skipUserPatches = false
    /// Space every raster is drawn in. `PetView` sets its screen's space so Core Animation can
    /// composite layer contents as-is; any other space makes each new contents image take a
    /// CPU color-conversion copy at commit. Changing it drops every cached raster.
    var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)! {
        didSet {
            guard colorSpace != oldValue else { return }
            frameCache.removeAll()
            layerRasterCache.removeAll()
            outlineUnderlayCache.removeAll()
        }
    }
    private let affineFastPathPoses: Set<PetPose> = [
        .idle, .sleepCurl, .pressLeft, .pressRight, .jumpStart, .jumpIng, .stretchDefault,
    ]
    private var poseLayerPlanCache: [String: PoseLayerPlan] = [:]
    private var frameCache = GenerationalCache<FrameKey, CGImage>(hotBudget: 16 << 20, cost: PixelCompositor.bytes)
    private var layerRasterCache = GenerationalCache<LayerRasterKey, CachedLayerRaster>(
        hotBudget: 32 << 20, cost: \.bytes)
    private var outlineUnderlayCache = GenerationalCache<OutlineKey, CGImage>(
        hotBudget: 8 << 20, cost: PixelCompositor.bytes)
    private var patternSignatureCache: (pattern: PatternModel, signature: String)?
    private(set) var cacheStats = PixelCompositorCacheStats()

    private struct RectKey: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
            self.x = Int((x * 1000).rounded())
            self.y = Int((y * 1000).rounded())
            self.width = Int((width * 1000).rounded())
            self.height = Int((height * 1000).rounded())
        }
    }

    private struct RectInfo {
        let key: RectKey
        let origIndex: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private struct StretchRect {
        let key: RectKey
        let startX: CGFloat
        let startY: CGFloat
        let startWidth: CGFloat
        let startHeight: CGFloat
        let endX: CGFloat
        let endY: CGFloat
        let endWidth: CGFloat
        let endHeight: CGFloat
        let segmentIndex: Int
    }

    private struct StretchMorph {
        let bodyRects: [RectKey: StretchRect]
        /// `bodyRects` in paint order (ascending `endY`), sorted once instead of per frame.
        let bodyRectsInPaintOrder: [StretchRect]
        let bodyRows: [StretchRect]
        let bodyYMin: CGFloat
        let segmentHeight: CGFloat
        let tailStartY: CGFloat
        let tailEndY: CGFloat
    }

    private enum HeatTint {
        case hot(CGFloat)
        case cool(CGFloat)
    }
    private struct DrawStyle {
        var fill: String?
        var stroke: String?
        var strokeWidth: CGFloat?
        var strokeLineCap: CGLineCap?
        var strokeLineJoin: CGLineJoin?
        var heatOverlay = false
    }

    private struct LayerRaster {
        let image: CGImage
        let rect: CGRect
    }

    /// Layer-raster cache entry. `.empty` records a slot whose raster came out fully
    /// transparent (e.g. flower slots whose artwork is actually drawn by the head slot):
    /// without the marker such slots re-ran the vector rasterization and full-bitmap alpha
    /// scan on every recomposite, which made the flower skin ~10x costlier than the cat.
    /// `.raster` also carries the slot's pre-dilated sticker-outline underlay (silhouette
    /// slots only) so the CALayer tree can move outline and fill together on the GPU.
    private enum CachedLayerRaster {
        case empty
        case raster(LayerRaster, outline: LayerRaster?)

        var bytes: Int {
            switch self {
            case .empty: return 0
            case .raster(let fill, let outline):
                return PixelCompositor.bytes(fill.image) + (outline.map { PixelCompositor.bytes($0.image) } ?? 0)
            }
        }
    }

    /// Decoded size of a raster, the cost unit of every raster cache.
    private static func bytes(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    private var activeClipPaths: [String: SceneNode] = [:]

    private struct OutlineSource {
        let bytes: UnsafePointer<UInt8>
        let length: Int
        let rowStride: Int
        let width: Int
        let height: Int
        let radius: Int
    }

    private struct OutlineRGBA {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    private struct OutlineDestination {
        let bytes: UnsafeMutablePointer<UInt8>
        let rowStride: Int
        let color: OutlineRGBA
    }
    private var stretchMorphCache: StretchMorph?

    init(library: PoseLibrary, mappings: CellMappings) {
        self.library = library
        self.mappings = mappings
    }

    /// Rasterizes the pose. `scale` supersamples the vector artwork above its native ~50px viewBox so
    /// the on-screen result is crisp instead of a nearest-neighbour blow-up; the sticker outline grows
    /// with it to keep a constant ~1 viewBox-unit thickness.
    func render(state: RenderState, scale: CGFloat = 1) -> CGImage? {
        let pose = library.pose(named: state.pose.rawValue)
        let viewBox = pose.viewBoxRect
        let renderScale = max(1, scale)
        let width = max(1, Int((viewBox.width * renderScale).rounded(.up)))
        let height = max(1, Int((viewBox.height * renderScale).rounded(.up)))
        let frameKey = renderFrameKey(state: state, scale: renderScale, width: width, height: height)
        if let cached = frameCache[frameKey] {
            cacheStats.frameHits += 1
            return cached
        }
        cacheStats.frameMisses += 1

        let useLayered =
            renderScale >= Self.layeredMinimumScale && affineFastPathPoses.contains(state.pose) && !forceMonolithic
        let rendered: CGImage?
        if useLayered {
            rendered = renderLayered(
                pose: pose,
                state: state,
                scale: renderScale,
                viewBox: viewBox,
                width: width,
                height: height
            )
        } else {
            guard
                let cat = rasterizeCat(
                    pose: pose,
                    state: state,
                    scale: renderScale,
                    viewBox: viewBox,
                    width: width,
                    height: height
                )
            else {
                return nil
            }
            rendered = outlinedCached(
                cat,
                pose: state.pose,
                state: state,
                scale: renderScale,
                width: width,
                height: height
            )
        }

        if let rendered {
            frameCache[frameKey] = rendered
        }
        return rendered
    }

    func viewBox(for poseName: String) -> CGRect { library.pose(named: poseName).viewBoxRect }

    func renderFrameKey(state: RenderState, scale: CGFloat) -> FrameKey {
        let pose = library.pose(named: state.pose.rawValue)
        let viewBox = pose.viewBoxRect
        let renderScale = max(1, scale)
        let width = max(1, Int((viewBox.width * renderScale).rounded(.up)))
        let height = max(1, Int((viewBox.height * renderScale).rounded(.up)))
        return renderFrameKey(state: state, scale: renderScale, width: width, height: height)
    }

    private func renderFrameKey(state: RenderState, scale: CGFloat, width: Int, height: Int) -> FrameKey {
        FrameKey(
            pose: state.pose,
            scaleBucket: scaleBucket(scale),
            width: width,
            height: height,
            patternSignature: cachedPatternSignature(for: state.pattern),
            visualSignature: visualSignature(state: state, scale: scale)
        )
    }

    private func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private func rasterizeCat(
        pose: Pose, state: RenderState, scale: CGFloat, viewBox vb: CGRect, width: Int, height: Int
    ) -> CGImage? {
        guard let ctx = bitmapContext(width: width, height: height) else { return nil }
        activeClipPaths = cachedClipPaths(for: pose)
        defer { activeClipPaths.removeAll(keepingCapacity: true) }
        ctx.interpolationQuality = .none
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -vb.minX, y: -vb.minY)
        if state.pose == .jumpStart || state.pose == .jumpIng {
            ctx.translateBy(x: vb.midX, y: vb.midY)
            ctx.scaleBy(x: 1.12, y: 1.12)
            ctx.translateBy(x: -vb.midX, y: -vb.midY)
        }
        draw(
            node: pose.root,
            in: ctx,
            inheritedFill: nil,
            inheritedStroke: nil,
            inheritedStrokeWidth: nil,
            inheritedStrokeLineCap: nil,
            inheritedStrokeLineJoin: nil,
            inheritedHeatOverlay: false,
            pose: pose,
            state: state
        )
        return ctx.makeImage()
    }

    private func renderLayered(
        pose: Pose,
        state: RenderState,
        scale: CGFloat,
        viewBox: CGRect,
        width: Int,
        height: Int
    ) -> CGImage? {
        let plan = layerPlan(for: pose, scale: scale, viewBox: viewBox)
        guard !plan.slots.isEmpty else {
            guard
                let cat = rasterizeCat(
                    pose: pose,
                    state: state,
                    scale: scale,
                    viewBox: viewBox,
                    width: width,
                    height: height
                )
            else {
                return nil
            }
            return outlinedCached(
                cat,
                pose: state.pose,
                state: state,
                scale: scale,
                width: width,
                height: height
            )
        }

        activeClipPaths = cachedClipPaths(for: pose)
        defer { activeClipPaths.removeAll(keepingCapacity: true) }

        let base = PoseLayerPlan.baseTransform(poseName: pose.name, scale: scale, viewBox: viewBox)
        guard
            let assembled = compositeLayers(
                plan: plan,
                pose: pose,
                state: state,
                scale: scale,
                base: base,
                width: width,
                height: height
            )
        else {
            return nil
        }
        let outlined = outlinedCached(
            assembled,
            pose: state.pose,
            state: state,
            scale: scale,
            width: width,
            height: height
        )
        let breathe = breatheDeviceTransform(plan: plan, pose: pose, state: state, base: base)
        return outlined.flatMap { transformed($0, width: width, height: height, by: breathe) }
    }

    private func layerPlan(for pose: Pose, scale: CGFloat, viewBox: CGRect) -> PoseLayerPlan {
        let key = "\(pose.name):\(scaleBucket(scale))"
        if let cached = poseLayerPlanCache[key] { return cached }
        let plan = PoseLayerPlan.build(pose: pose, scale: scale, viewBox: viewBox)
        poseLayerPlanCache[key] = plan
        return plan
    }

    private func compositeLayers(
        plan: PoseLayerPlan,
        pose: Pose,
        state: RenderState,
        scale: CGFloat,
        base: CGAffineTransform,
        width: Int,
        height: Int
    ) -> CGImage? {
        guard let ctx = bitmapContext(width: width, height: height) else { return nil }
        ctx.interpolationQuality = .none
        for slot in plan.slots where slot.visibility.includes(state) {
            guard
                let layer = layerRaster(
                    slot: slot, pose: pose, state: state, scale: scale, width: width, height: height)
            else {
                continue
            }
            let anim = layerAnimCTM(slot: slot, state: state, base: base)
            let blit = slot.restCTMInverse.concatenating(anim)
            ctx.saveGState()
            ctx.concatenate(blit)
            ctx.draw(layer.image, in: layer.rect)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    private func layerRaster(
        slot: LayerSlot,
        pose: Pose,
        state: RenderState,
        scale: CGFloat,
        width: Int,
        height: Int
    ) -> LayerRaster? {
        switch layerEntry(slot: slot, pose: pose, state: state, scale: scale, width: width, height: height) {
        case .raster(let raster, _): return raster
        case .empty, nil: return nil
        }
    }

    private func layerEntry(
        slot: LayerSlot,
        pose: Pose,
        state: RenderState,
        scale: CGFloat,
        width: Int,
        height: Int
    ) -> CachedLayerRaster? {
        let key = layerRasterKey(slot: slot, pose: pose, state: state, scale: scale)
        if let cached = layerRasterCache[key] {
            cacheStats.layerRasterHits += 1
            return cached
        }
        cacheStats.layerRasterMisses += 1
        guard let ctx = bitmapContext(width: width, height: height) else { return nil }
        ctx.interpolationQuality = .none
        ctx.concatenate(slot.restCTM)
        let style = inheritedStyle(for: slot)
        // Slot contents must be independent of the live eye state: `draw` prunes eye /
        // closed-eye-line nodes by `state.eyesClosed`, but the cache key only carries the
        // slot's static visibility. Rasterize with the eye state the slot itself expects and
        // let visibility gating (compositeLayers' filter, the layer tree's isHidden) decide
        // what shows — otherwise an eye slot rasterized mid-blink caches as `.empty` forever.
        var rasterState = state
        // `eyesClosed` is computed (`purring || sleeping`); force the gate through its inputs.
        // Neither flag affects static slot artwork otherwise — purr/sleep motion is all
        // dynamic-transform, which layer rasterization skips (`applyDynamic: false`).
        rasterState.purring = slot.visibility == .eyesClosedOnly
        rasterState.sleeping = false
        draw(
            node: slot.root,
            in: ctx,
            inheritedFill: style.fill,
            inheritedStroke: style.stroke,
            inheritedStrokeWidth: style.strokeWidth,
            inheritedStrokeLineCap: style.strokeLineCap,
            inheritedStrokeLineJoin: style.strokeLineJoin,
            inheritedHeatOverlay: style.heatOverlay,
            pose: pose,
            state: rasterState,
            applyDynamic: false,
            pruneDynamicBoundaries: true,
            isLayerRoot: true,
            applyRootStaticTransform: false
        )
        guard let image = ctx.makeImage() else { return nil }
        let entry: CachedLayerRaster
        if let raster = croppedLayerRaster(image, width: width, height: height) {
            let outline = slot.silhouette ? slotOutline(for: raster, scale: scale, pattern: state.pattern) : nil
            entry = .raster(raster, outline: outline)
        } else {
            entry = .empty
        }
        layerRasterCache[key] = entry
        return entry
    }

    /// Dilates a slot's cropped raster into its sticker-outline underlay. The dilation runs on
    /// a canvas padded by the outline radius so the ring is never clipped by the crop; the
    /// returned rect is the fill rect expanded by that padding.
    private func slotOutline(for raster: LayerRaster, scale: CGFloat, pattern: PatternModel) -> LayerRaster? {
        let radius = outlineRadius(scale: scale)
        let pad = max(1, Int(radius.rounded(.up)))
        let width = raster.image.width + pad * 2
        let height = raster.image.height + pad * 2
        guard let ctx = bitmapContext(width: width, height: height) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(
            raster.image,
            in: CGRect(x: pad, y: pad, width: raster.image.width, height: raster.image.height))
        guard
            let padded = ctx.makeImage(),
            let outline = outlineUnderlay(
                padded, width: width, height: height, radius: radius, color: outlineColor(for: pattern))
        else { return nil }
        return LayerRaster(image: outline, rect: raster.rect.insetBy(dx: -CGFloat(pad), dy: -CGFloat(pad)))
    }

    private func outlineRadius(scale: CGFloat) -> CGFloat { scale.rounded() }

    private func croppedLayerRaster(_ image: CGImage, width: Int, height: Int) -> LayerRaster? {
        guard
            let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else {
            return LayerRaster(image: image, rect: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let length = CFDataGetLength(data)
        let rowStride = image.bytesPerRow
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for row in 0..<height {
            let rowOffset = row * rowStride
            for column in 0..<width {
                let alphaOffset = rowOffset + column * 4 + 3
                guard alphaOffset < length, bytes[alphaOffset] > 0 else { continue }
                minX = min(minX, column)
                minY = min(minY, row)
                maxX = max(maxX, column)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let padding = 2
        minX = max(0, minX - padding)
        minY = max(0, minY - padding)
        maxX = min(width - 1, maxX + padding)
        maxY = min(height - 1, maxY + padding)
        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = image.cropping(to: cropRect) else {
            return LayerRaster(image: image, rect: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let drawRect = CGRect(x: minX, y: height - maxY - 1, width: maxX - minX + 1, height: maxY - minY + 1)
        return LayerRaster(image: cropped, rect: drawRect)
    }

    private func layerAnimCTM(slot: LayerSlot, state: RenderState, base: CGAffineTransform) -> CGAffineTransform {
        slot.ancestorChain.reduce(base) { partial, node in
            var next = node.transform.concatenating(partial)
            if !node.motion.contains(.breathe) {
                next = dynamicTransform(for: node, state: state).concatenating(next)
            }
            return next
        }
    }

    private func breatheDeviceTransform(
        plan: PoseLayerPlan,
        pose: Pose,
        state: RenderState,
        base: CGAffineTransform
    ) -> CGAffineTransform {
        guard
            let indexPath = plan.hoistedBreatheIndexPath,
            let node = node(at: indexPath, in: pose.root)
        else {
            return .identity
        }
        let breathe = dynamicTransform(for: node, state: state)
        guard !breathe.isIdentity else { return .identity }
        return base.inverted().concatenating(breathe.concatenating(base))
    }

    // MARK: - CALayer-tree surface

    /// Everything `CatLayerTree` needs to assemble one pose as GPU-composited CALayers.
    /// `base` maps viewBox units to device pixels; `width`/`height` are the device canvas.
    /// `scale` is the supersample scale the slots rasterize at; `supersampled` marks a canvas
    /// denser than requested, which the layer tree must minify smoothly rather than point-sample.
    struct LayeredFrame {
        let plan: PoseLayerPlan
        let base: CGAffineTransform
        let width: Int
        let height: Int
        let scale: CGFloat
        let supersampled: Bool
    }

    /// One slot's cached artwork: the cropped fill raster plus, for silhouette slots, the
    /// pre-dilated sticker-outline underlay. Rects are in the frame's device space.
    struct SlotSurface {
        let fill: CGImage
        let fillRect: CGRect
        let outline: (image: CGImage, rect: CGRect)?
    }

    /// The layered plan for the pose, or nil when the pose must render monolithically
    /// (non-affine morphs, `forceMonolithic` skins). Callers fall back to a single-layer
    /// `render(state:scale:)` contents image. Sub-2x scales supersample to 2x so small pets stay
    /// on the GPU path instead of re-rasterizing the whole cat every frame.
    func layeredFrame(state: RenderState, scale: CGFloat) -> LayeredFrame? {
        guard affineFastPathPoses.contains(state.pose), !forceMonolithic else { return nil }
        let renderScale = max(Self.layeredMinimumScale, scale)
        let pose = library.pose(named: state.pose.rawValue)
        let viewBox = pose.viewBoxRect
        let plan = layerPlan(for: pose, scale: renderScale, viewBox: viewBox)
        guard !plan.slots.isEmpty else { return nil }
        return LayeredFrame(
            plan: plan,
            base: PoseLayerPlan.baseTransform(poseName: pose.name, scale: renderScale, viewBox: viewBox),
            width: max(1, Int((viewBox.width * renderScale).rounded(.up))),
            height: max(1, Int((viewBox.height * renderScale).rounded(.up))),
            scale: renderScale,
            supersampled: renderScale > max(1, scale)
        )
    }

    /// Cached raster surfaces for one slot; nil when the slot draws nothing for this state.
    func slotSurface(slot: LayerSlot, state: RenderState, frame: LayeredFrame) -> SlotSurface? {
        let pose = library.pose(named: state.pose.rawValue)
        activeClipPaths = cachedClipPaths(for: pose)
        defer { activeClipPaths.removeAll(keepingCapacity: true) }
        switch layerEntry(
            slot: slot, pose: pose, state: state, scale: frame.scale, width: frame.width, height: frame.height)
        {
        case .raster(let fill, let outline):
            return SlotSurface(
                fill: fill.image,
                fillRect: fill.rect,
                outline: outline.map { ($0.image, $0.rect) }
            )
        case .empty, nil:
            return nil
        }
    }

    /// Device-space transform placing a slot's rest raster at its animated position —
    /// identical math to `compositeLayers`' per-slot blit, evaluated continuously (the layer
    /// tree needs no cache-key quantization).
    func slotBlitTransform(slot: LayerSlot, state: RenderState, frame: LayeredFrame) -> CGAffineTransform {
        slot.restCTMInverse.concatenating(layerAnimCTM(slot: slot, state: state, base: frame.base))
    }

    /// Whole-body breathe transform hoisted out of the slot CTMs (see `renderLayered`), in
    /// device space.
    func breatheTransform(state: RenderState, frame: LayeredFrame) -> CGAffineTransform {
        let pose = library.pose(named: state.pose.rawValue)
        return breatheDeviceTransform(plan: frame.plan, pose: pose, state: state, base: frame.base)
    }

    /// Cheap signature of everything that changes slot contents (not placement) besides the
    /// pattern, which callers compare by value: supersample scale and the heat tint bucket.
    func slotContentBucket(state: RenderState, frame: LayeredFrame) -> Int {
        (scaleBucket(frame.scale) << 16) | heatBucket(state)
    }

    private func transformed(
        _ image: CGImage,
        width: Int,
        height: Int,
        by transform: CGAffineTransform
    ) -> CGImage? {
        guard !transform.isIdentity else { return image }
        guard let ctx = bitmapContext(width: width, height: height) else { return image }
        ctx.interpolationQuality = .none
        ctx.concatenate(transform)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    private func inheritedStyle(for slot: LayerSlot) -> DrawStyle {
        var style = DrawStyle()
        for node in slot.ancestorChain.dropLast() {
            style.fill = node.attr("fill") ?? style.fill
            style.stroke = node.attr("stroke") ?? style.stroke
            style.strokeWidth =
                node.attr("stroke-width")
                .flatMap(Double.init)
                .map { CGFloat($0) } ?? style.strokeWidth
            style.strokeLineCap = node.attr("stroke-linecap").flatMap(lineCap) ?? style.strokeLineCap
            style.strokeLineJoin = node.attr("stroke-linejoin").flatMap(lineJoin) ?? style.strokeLineJoin
            style.heatOverlay = style.heatOverlay || node.attr("data-heat-overlay") != nil
        }
        return style
    }

    /// Surrounds the silhouette with the configured sticker outline and reuses that underlay across
    /// frames whose alpha mask is unchanged. The outline pass is the expensive part of monolithic
    /// skins, while the underlay depends only on silhouette + outline color, not fill colors.
    private func outlinedCached(
        _ cat: CGImage,
        pose: PetPose,
        state: RenderState,
        scale: CGFloat,
        width: Int,
        height: Int
    ) -> CGImage? {
        let radius = outlineRadius(scale: scale)
        let outline = outlineColor(for: state.pattern)

        let key = OutlineKey(
            pose: pose,
            scaleBucket: scaleBucket(scale),
            width: width,
            height: height,
            outlineColor: state.pattern.resolvedOutlineColor,
            silhouetteSignature: silhouetteSignature(state: state, scale: scale)
        )
        let underlay: CGImage
        if let cached = outlineUnderlayCache[key] {
            cacheStats.outlineHits += 1
            underlay = cached
        } else {
            cacheStats.outlineMisses += 1
            guard
                let generated = outlineUnderlay(
                    cat,
                    width: width,
                    height: height,
                    radius: radius,
                    color: outline
                )
            else {
                return coreGraphicsOutlined(cat, width: width, height: height, radius: radius, color: outline)
            }
            underlay = generated
            outlineUnderlayCache[key] = generated
        }
        return composite(cat: cat, underlay: underlay, width: width, height: height)
    }

    private func outlineUnderlay(_ cat: CGImage, width: Int, height: Int, radius: CGFloat, color: NSColor) -> CGImage? {
        guard
            let sourceData = cat.dataProvider?.data,
            let source = CFDataGetBytePtr(sourceData)
        else {
            return nil
        }

        let sourceBitmap = OutlineSource(
            bytes: source,
            length: CFDataGetLength(sourceData),
            rowStride: cat.bytesPerRow,
            width: width,
            height: height,
            radius: max(1, Int(radius.rounded(.up)))
        )
        prepareOutlineBuffers(pixelCount: width * height, dequeCount: max(width, height))

        outlineTempAlpha.withUnsafeMutableBufferPointer { temp in
            outlineDeque.withUnsafeMutableBufferPointer { deque in
                Self.maxFilterHorizontal(source: sourceBitmap, output: temp, deque: deque)
            }
        }

        let rgba = outlineRGBA(color)
        let outputRowStride = width * 4
        var output = Data(count: outputRowStride * height)
        output.withUnsafeMutableBytes { rawOutput in
            guard let destination = rawOutput.bindMemory(to: UInt8.self).baseAddress else { return }
            let destinationBitmap = OutlineDestination(bytes: destination, rowStride: outputRowStride, color: rgba)
            outlineTempAlpha.withUnsafeBufferPointer { temp in
                outlineDeque.withUnsafeMutableBufferPointer { deque in
                    Self.writeVerticalOutline(
                        input: temp,
                        source: sourceBitmap,
                        destination: destinationBitmap,
                        deque: deque
                    )
                }
            }
        }

        guard let provider = CGDataProvider(data: output as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outputRowStride,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func composite(cat: CGImage, underlay: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = bitmapContext(width: width, height: height) else { return cat }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.interpolationQuality = .none
        ctx.draw(underlay, in: canvas)
        ctx.draw(cat, in: canvas)
        return ctx.makeImage() ?? cat
    }

    private func prepareOutlineBuffers(pixelCount: Int, dequeCount: Int) {
        if outlineTempAlpha.count != pixelCount { outlineTempAlpha = [UInt8](repeating: 0, count: pixelCount) }
        if outlineDeque.count < dequeCount { outlineDeque = [Int](repeating: 0, count: dequeCount) }
    }

    private static func maxFilterHorizontal(
        source: OutlineSource,
        output: UnsafeMutableBufferPointer<UInt8>,
        deque: UnsafeMutableBufferPointer<Int>
    ) {
        guard let outputBase = output.baseAddress, let dequeBase = deque.baseAddress else { return }

        var row = 0
        while row < source.height {
            let sourceRow = row * source.rowStride
            let outputRow = outputBase.advanced(by: row * source.width)
            var head = 0
            var tail = 0
            var next = 0
            var column = 0
            while column < source.width {
                let unclampedEnd = column + source.radius
                let end = unclampedEnd < source.width ? unclampedEnd : source.width - 1
                while next <= end {
                    let offset = sourceRow + next * 4 + 3
                    let value = offset < source.length ? source.bytes[offset] : 0
                    while head < tail {
                        let previousColumn = dequeBase[tail - 1]
                        let previousOffset = sourceRow + previousColumn * 4 + 3
                        let previous = previousOffset < source.length ? source.bytes[previousOffset] : 0
                        if previous > value { break }
                        tail -= 1
                    }
                    dequeBase[tail] = next
                    tail += 1
                    next += 1
                }
                let start = column - source.radius
                while head < tail, dequeBase[head] < start { head += 1 }
                let bestColumn = dequeBase[head]
                let bestOffset = sourceRow + bestColumn * 4 + 3
                outputRow[column] = bestOffset < source.length ? source.bytes[bestOffset] : 0
                column += 1
            }
            row += 1
        }
    }

    private static func writeVerticalOutline(
        input: UnsafeBufferPointer<UInt8>,
        source: OutlineSource,
        destination: OutlineDestination,
        deque: UnsafeMutableBufferPointer<Int>
    ) {
        guard let inputBase = input.baseAddress, let dequeBase = deque.baseAddress else { return }
        let color = destination.color

        var column = 0
        while column < source.width {
            var head = 0
            var tail = 0
            var next = 0
            var row = 0
            while row < source.height {
                let unclampedEnd = row + source.radius
                let end = unclampedEnd < source.height ? unclampedEnd : source.height - 1
                while next <= end {
                    let index = next * source.width + column
                    let value = inputBase[index]
                    while head < tail {
                        let previous = inputBase[dequeBase[tail - 1] * source.width + column]
                        if previous > value { break }
                        tail -= 1
                    }
                    dequeBase[tail] = next
                    tail += 1
                    next += 1
                }
                let start = row - source.radius
                while head < tail, dequeBase[head] < start { head += 1 }

                let maskAlpha = inputBase[dequeBase[head] * source.width + column]
                if maskAlpha > 0 {
                    let sourceOffset = row * source.rowStride + column * 4
                    if sourceOffset + 3 < source.length, source.bytes[sourceOffset + 3] == 0 {
                        let alpha = (Int(maskAlpha) * Int(color.alpha) + 127) / 255
                        let outputOffset = row * destination.rowStride + column * 4
                        destination.bytes[outputOffset] = UInt8((Int(color.red) * alpha + 127) / 255)
                        destination.bytes[outputOffset + 1] = UInt8((Int(color.green) * alpha + 127) / 255)
                        destination.bytes[outputOffset + 2] = UInt8((Int(color.blue) * alpha + 127) / 255)
                        destination.bytes[outputOffset + 3] = UInt8(alpha)
                    }
                }
                row += 1
            }
            column += 1
        }
    }

    /// Outline components in `colorSpace`: the dilation writes these bytes directly, bypassing
    /// the color matching CG applies to fills.
    private func outlineRGBA(_ color: NSColor) -> OutlineRGBA {
        let rgb = NSColorSpace(cgColorSpace: colorSpace).flatMap(color.usingColorSpace) ?? color
        return OutlineRGBA(
            red: UInt8(clamping: Int((rgb.redComponent * 255).rounded())),
            green: UInt8(clamping: Int((rgb.greenComponent * 255).rounded())),
            blue: UInt8(clamping: Int((rgb.blueComponent * 255).rounded())),
            alpha: UInt8(clamping: Int((rgb.alphaComponent * 255).rounded()))
        )
    }

    private func coreGraphicsOutlined(
        _ cat: CGImage,
        width: Int,
        height: Int,
        radius: CGFloat,
        color: NSColor
    ) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let ctx = bitmapContext(width: width, height: height) else { return cat }
        ctx.interpolationQuality = .high
        let directions = 16
        for index in 0..<directions {
            let angle = CGFloat(index) / CGFloat(directions) * 2 * .pi
            ctx.draw(cat, in: rect.offsetBy(dx: cos(angle) * radius, dy: sin(angle) * radius))
        }
        ctx.setBlendMode(.sourceAtop)
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
        ctx.setBlendMode(.normal)
        ctx.draw(cat, in: rect)
        return ctx.makeImage() ?? cat
    }

    private func draw(
        node: SceneNode,
        in ctx: CGContext,
        inheritedFill: String?,
        inheritedStroke: String?,
        inheritedStrokeWidth: CGFloat?,
        inheritedStrokeLineCap: CGLineCap?,
        inheritedStrokeLineJoin: CGLineJoin?,
        inheritedHeatOverlay: Bool,
        pose: Pose,
        state: RenderState,
        applyDynamic: Bool = true,
        pruneDynamicBoundaries: Bool = false,
        isLayerRoot: Bool = true,
        applyRootStaticTransform: Bool = true
    ) {
        if node.tag == "defs" || node.tag == "clipPath" { return }
        if pruneDynamicBoundaries, !isLayerRoot, DynamicVocabulary.isBoundary(node, poseName: pose.name) { return }
        if node.hasClass("closed-eye-line") && !state.eyesClosed { return }
        if state.eyesClosed && (node.id == "eye-left" || node.id == "eye-right") { return }
        if state.pose == .stretchDefault {
            let peak = stretchPosePeak(state)
            if node.id == "eyes-open" && peak > 0.95 { return }
            if node.id == "eyes-closed" && peak <= 0.95 { return }
        }
        ctx.saveGState()
        if applyRootStaticTransform || !isLayerRoot {
            ctx.concatenate(node.transform)
        }
        if applyDynamic {
            ctx.concatenate(dynamicTransform(for: node, state: state))
        }
        applyClipIfNeeded(for: node, ctx: ctx, state: state)
        let fill = node.attr("fill") ?? inheritedFill
        let stroke = node.attr("stroke") ?? inheritedStroke
        let strokeWidth = node.attr("stroke-width").flatMap(Double.init).map { CGFloat($0) } ?? inheritedStrokeWidth
        let strokeLineCap = node.attr("stroke-linecap").flatMap(lineCap) ?? inheritedStrokeLineCap
        let strokeLineJoin = node.attr("stroke-linejoin").flatMap(lineJoin) ?? inheritedStrokeLineJoin
        let heatOverlay = inheritedHeatOverlay || node.attr("data-heat-overlay") != nil
        if node.tag == "path", let d = node.attr("d") {
            drawPath(
                d, fill: fill, stroke: stroke, strokeWidth: strokeWidth,
                lineCap: strokeLineCap ?? .butt, lineJoin: strokeLineJoin ?? .miter,
                ctx: ctx, state: state, heatOverlay: heatOverlay)
        }
        if node.tag == "rect" {
            drawRect(
                node, fill: fill, stroke: stroke, strokeWidth: strokeWidth,
                lineCap: strokeLineCap ?? .butt, lineJoin: strokeLineJoin ?? .miter,
                ctx: ctx, pose: pose, state: state, heatOverlay: heatOverlay)
        }
        drawGeneratedComponentIfNeeded(node, fill: fill, ctx: ctx, state: state, heatOverlay: heatOverlay)
        let drawsMochiBody = state.mochiStretchActive && pose.name == "stretch-end" && node.id == "cat-content"
        var drewMochiBody = false
        for child in node.children {
            if drawsMochiBody && !drewMochiBody && child.id == "head" {
                drawMochiBodyAndPattern(in: ctx, state: state)
                drewMochiBody = true
            }
            draw(
                node: child,
                in: ctx,
                inheritedFill: fill,
                inheritedStroke: stroke,
                inheritedStrokeWidth: strokeWidth,
                inheritedStrokeLineCap: strokeLineCap,
                inheritedStrokeLineJoin: strokeLineJoin,
                inheritedHeatOverlay: heatOverlay,
                pose: pose,
                state: state,
                applyDynamic: applyDynamic,
                pruneDynamicBoundaries: pruneDynamicBoundaries,
                isLayerRoot: false,
                applyRootStaticTransform: true
            )
        }
        if drawsMochiBody && !drewMochiBody { drawMochiBodyAndPattern(in: ctx, state: state) }
        drawPatternIfNeeded(node, ctx: ctx, pose: pose, state: state)
        ctx.restoreGState()
    }

    private func drawGeneratedComponentIfNeeded(
        _ node: SceneNode, fill: String?, ctx: CGContext, state: RenderState, heatOverlay: Bool
    ) {
        guard let id = node.id else { return }
        switch id {
        case "tail":
            guard node.children.isEmpty, let frame = patchFrame(node) else { return }
            ctx.saveGState()
            ctx.translateBy(x: frame.origin.x, y: frame.origin.y)
            ctx.scaleBy(x: frame.size.width, y: frame.size.height)
            drawPath(
                library.components.tailPathD, fill: fill ?? "var(--cat-color)", ctx: ctx, state: state,
                heatOverlay: heatOverlay)
            ctx.restoreGState()
        case "ear-left", "ear-right":
            guard node.children.isEmpty, let pos = node.attr("data-ear-position") else { return }
            let nums = numbers(pos)
            guard nums.count >= 2 else { return }
            ctx.saveGState()
            ctx.translateBy(x: nums[0], y: nums[1])
            drawPath(
                id == "ear-left" ? library.components.earLeftPathD : library.components.earRightPathD,
                fill: "var(--cat-color)", ctx: ctx, state: state, heatOverlay: heatOverlay)
            ctx.restoreGState()
        default: return
        }
    }

    private func drawPath(
        _ d: String, fill: String?, stroke: String? = nil, strokeWidth: CGFloat? = nil, lineCap: CGLineCap = .butt,
        lineJoin: CGLineJoin = .miter, ctx: CGContext, state: RenderState, heatOverlay: Bool
    ) {
        let path: CGPath
        if let cached = pathCache[d] {
            path = cached
        } else {
            guard let parsed = try? SVGPathParser.path(d) else { return }
            pathCache[d] = parsed
            path = parsed
        }
        if let fillColor = color(fill, state: state, heatOverlay: heatOverlay) {
            ctx.addPath(path)
            ctx.setFillColor(fillColor.cgColor)
            ctx.fillPath()
        }
        guard let stroke, let strokeColor = color(stroke, state: state, heatOverlay: heatOverlay) else { return }
        let width = max(0, strokeWidth ?? 1)
        guard width > 0 else { return }
        ctx.addPath(path)
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(lineCap)
        ctx.setLineJoin(lineJoin)
        ctx.strokePath()
    }

    private func drawRect(
        _ node: SceneNode, fill: String?, stroke: String?, strokeWidth: CGFloat?, lineCap: CGLineCap,
        lineJoin: CGLineJoin, ctx: CGContext, pose: Pose, state: RenderState, heatOverlay: Bool
    ) {
        guard let geometry = rectInfo(for: node, origIndex: 0) else { return }
        if state.mochiStretchActive, pose.name == "stretch-end", stretchMorph()?.bodyRects[geometry.key] != nil {
            return
        }
        let rect = CGRect(x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height)
        guard rect.width > 0, rect.height > 0 else { return }
        if let fillColor = color(fill, state: state, heatOverlay: heatOverlay) {
            ctx.setFillColor(fillColor.cgColor)
            ctx.fill(rect)
        }
        guard let stroke, let strokeColor = color(stroke, state: state, heatOverlay: heatOverlay) else { return }
        let width = max(0, strokeWidth ?? 1)
        guard width > 0 else { return }
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(lineCap)
        ctx.setLineJoin(lineJoin)
        ctx.stroke(rect)
    }

    private func drawPatternIfNeeded(_ node: SceneNode, ctx: CGContext, pose: Pose, state: RenderState) {
        guard let element = node.id, let part = PatternPart.forElement(element) else { return }
        if skipUserPatches { return }
        if state.mochiStretchActive, pose.name == "stretch-end", element == "body" { return }
        let spots = state.pattern.spots(for: part)
        guard !spots.isEmpty else { return }
        let frame = patchFrame(node)
        let mirrorXCells = Int(number(node.attr("data-patch-mirror-x")))
        let isStretchBody = pose.name == "stretch-end" && element == "body"
        let mapping =
            isStretchBody
            ? mappings.mapping(svgName: "stretch-chain", elementId: "body")
            : mappings.mapping(svgName: pose.name, elementId: element)
        let stampMissingMappedCell =
            (pose.name == "jump-ing" || pose.name == "jump-start")
            && (element == "leg-fl" || element == "leg-fr")
        for spot in spots {
            guard let base = NSColor(hex: spot.color) else { continue }
            ctx.setFillColor(heatAdjustedPatternColor(base, state: state).cgColor)
            let cellX = mirrorXCells > 0 ? mirrorXCells - 1 - spot.x : spot.x
            drawSpot(
                mapping: mapping,
                isStretchBody: isStretchBody,
                stampMissingMappedCell: stampMissingMappedCell,
                cellX: cellX,
                cellY: spot.y,
                frame: frame,
                ctx: ctx,
                state: state
            )
        }
    }

    private func drawSpot(
        mapping: CellPixelMapping?,
        isStretchBody: Bool,
        stampMissingMappedCell: Bool,
        cellX: Int,
        cellY: Int,
        frame: CGRect?,
        ctx: CGContext,
        state: RenderState
    ) {
        if isStretchBody {
            if let blocks = mapping?.points(cellX: cellX, cellY: cellY), !blocks.isEmpty {
                for block in blocks {
                    drawStretchBodyBlock(blockX: Int(block.x), blockY: Int(block.y), ctx: ctx, state: state)
                }
            } else {
                drawStretchBodyBlock(blockX: cellX, blockY: cellY, ctx: ctx, state: state)
            }
            return
        }
        guard let mapping else {
            if let frame { stamp(cellX: cellX, cellY: cellY, frame: frame, ctx: ctx) }
            return
        }
        guard let rects = mapping.rects(cellX: cellX, cellY: cellY), !rects.isEmpty else {
            if stampMissingMappedCell, let frame {
                stamp(cellX: cellX, cellY: cellY, frame: frame, ctx: ctx)
            }
            return
        }
        ctx.fill(rects)
    }

    private func stamp(cellX: Int, cellY: Int, frame: CGRect, ctx: CGContext) {
        ctx.fill(
            CGRect(
                x: frame.minX + CGFloat(cellX) * frame.width, y: frame.minY + CGFloat(cellY) * frame.height,
                width: frame.width, height: frame.height))
    }

    private func patchFrame(_ node: SceneNode) -> CGRect? {
        let raw =
            node.attr("data-patch-frame")
            ?? (node.id?.hasPrefix("ear") == true ? node.attr("data-ear-position").map { "\($0) 1 1" } : nil)
        guard let raw else { return nil }
        let nums = numbers(raw)
        guard nums.count >= 4 else { return nil }
        return CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }

    private func color(_ raw: String?, state: RenderState, heatOverlay: Bool) -> NSColor? {
        let fallbackCat = heatAdjustedBase(pattern: state.pattern, state: state, heatOverlay: heatOverlay)
        guard let raw else { return fallbackCat }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        if normalized == "none" { return nil }
        if normalized == "black" { return .black }
        if normalized == "white" { return .white }
        if normalized == "transparent" { return nil }
        if trimmed.contains("--cat-outline") { return outlineColor(for: state.pattern) }
        if trimmed.contains("--eye-bg-color") {
            return NSColor(hex: state.pattern.resolvedEyeBgColor).map { heatAdjustedVisibleColor($0, state: state) }
        }
        if trimmed.contains("--eye-color-left") {
            return NSColor(hex: state.pattern.resolvedEyeColorLeft).map { heatAdjustedVisibleColor($0, state: state) }
        }
        if trimmed.contains("--eye-color-right") {
            return NSColor(hex: state.pattern.resolvedEyeColorRight).map { heatAdjustedVisibleColor($0, state: state) }
        }
        if trimmed.contains("--eye-color") {
            return NSColor(hex: state.pattern.resolvedEyeColor).map { heatAdjustedVisibleColor($0, state: state) }
        }
        if trimmed.contains("--cat-color") { return fallbackCat }
        if trimmed.hasPrefix("#") {
            guard let base = NSColor(hex: trimmed) else { return nil }
            return heatOverlay
                ? heatAdjustedPatternColor(base, state: state) : heatAdjustedVisibleColor(base, state: state)
        }
        return fallbackCat
    }

    private func heatAdjustedBase(pattern: PatternModel, state: RenderState, heatOverlay: Bool) -> NSColor {
        let base = (NSColor(hex: pattern.baseColor) ?? .black).usingColorSpace(.sRGB) ?? .black
        guard let tint = heatTint(state: state, patternRegion: heatOverlay) else { return base }
        return apply(tint: tint, to: base)
    }

    private func heatAdjustedPatternColor(_ color: NSColor, state: RenderState) -> NSColor {
        let base = color.usingColorSpace(.sRGB) ?? color
        guard let tint = heatTint(state: state, patternRegion: true) else { return base }
        return apply(tint: tint, to: base)
    }

    private func heatAdjustedVisibleColor(_ color: NSColor, state: RenderState) -> NSColor {
        let base = color.usingColorSpace(.sRGB) ?? color
        guard let tint = heatTint(state: state, patternRegion: false) else { return base }
        return apply(tint: tint, to: base)
    }

    /// Tint for typing "heat" (red) and stretch "resting" (green). Fur/pattern colors
    /// (`patternRegion`) take both tints; other colors (eyes) tint only during the mochi stretch.
    private func heatTint(state: RenderState, patternRegion: Bool) -> HeatTint? {
        let hotOpacity = min(0.7, max(0, state.heat) * 0.7)
        if state.mochiStretchActive, hotOpacity > 0.005 { return .hot(hotOpacity) }
        guard patternRegion else { return nil }
        let coolOpacity = min(0.42, max(0, state.stretchingHeat) * 0.42)
        if coolOpacity > 0.005 { return .cool(coolOpacity) }
        if hotOpacity > 0.005 { return .hot(hotOpacity) }
        return nil
    }

    private func apply(tint: HeatTint, to base: NSColor) -> NSColor {
        let target: (r: CGFloat, g: CGFloat, b: CGFloat)
        let opacity: CGFloat
        switch tint {
        case .hot(let alpha):
            target = (CGFloat(220) / 255, CGFloat(40) / 255, CGFloat(40) / 255)
            opacity = alpha
        case .cool(let alpha):
            target = (CGFloat(60) / 255, CGFloat(180) / 255, CGFloat(90) / 255)
            opacity = alpha
        }
        return NSColor(
            srgbRed: base.redComponent + (target.r - base.redComponent) * opacity,
            green: base.greenComponent + (target.g - base.greenComponent) * opacity,
            blue: base.blueComponent + (target.b - base.blueComponent) * opacity,
            alpha: base.alphaComponent)
    }

    private func dynamicTransform(for node: SceneNode, state: RenderState) -> CGAffineTransform {
        var t = CGAffineTransform.identity
        if state.pose == .idle {
            if node.id == "body" { t = t.translatedBy(x: state.tracking.body.x, y: state.tracking.body.y) }
            if node.id == "face-js" {
                if state.purring {
                    let bob: CGFloat = phase(state.time, period: 1.1) >= 0.5 ? 0.4 : 0
                    t = t.translatedBy(x: state.purrFaceOffset.x, y: state.purrFaceOffset.y + bob)
                } else {
                    t = t.translatedBy(x: state.tracking.face.x, y: state.tracking.face.y)
                }
            }
            if node.id == "eyes-js" { t = t.translatedBy(x: state.tracking.eyes.x, y: state.tracking.eyes.y) }
            if node.motion.contains(.pupil) || node.id == "pupil-left" || node.id == "pupil-right" {
                let tracking =
                    state.hunting
                    ? CGPoint(
                        x: state.tracking.pupils.x * Self.huntingPupilTrackingScale,
                        y: state.tracking.pupils.y * Self.huntingPupilTrackingScale
                    )
                    : state.tracking.pupils
                let offset = CGAffineTransform(translationX: tracking.x, y: tracking.y)
                if state.hunting, let scale = pupilScaleTransform(for: node, factor: Self.huntingPupilScale) {
                    t = t.concatenating(scale).concatenating(offset)
                } else {
                    t = t.concatenating(offset)
                }
            }
        }
        if state.pose == .idle, state.kneadPhase > 0, let id = node.id,
            let knead = kneadTransform(id: id, time: state.time, intensity: state.kneadPhase)
        {
            t = t.concatenating(knead)
        }
        if state.pose == .jumpIng, let id = node.id {
            if let jump = jumpLegTransform(id: id, time: state.time) { t = t.concatenating(jump) }
        }
        if state.mochiStretchActive, state.pose == .stretchEnd, let id = node.id {
            if let stretch = mochiPartTransform(id: id, node: node, state: state) { t = t.concatenating(stretch) }
        }
        if state.pose == .stretchDefault, let id = node.id {
            if let stretch = stretchReminderTransform(id: id, time: state.time, progress: stretchPosePeak(state)) {
                t = t.concatenating(stretch)
            }
        }
        let time = state.time
        if node.motion.contains(.breathe), !state.hunting, !state.huntingReturn {
            let p = (sin(time / 3.5 * 2 * .pi - .pi / 2) + 1) / 2
            t = t.concatenating(
                about(CGPoint(x: 16, y: 22), scaleX: 1 + 0.015 * p, y: 1 - 0.015 * p, translateY: 0.4 * p))
        }
        if node.motion.contains(.tailSway) {
            let angle = Self.idleTailAngle(
                time: time, hunting: state.hunting, purring: state.purring, sleeping: state.sleeping,
                thinking: state.thinking, flourish: state.flourish, flourishPhase: state.flourishPhase)
            t = t.concatenating(rotate(angleDegrees: angle, around: CGPoint(x: 24, y: 31)))
        }
        if node.motion.contains(.whiskersFlex) {
            if state.purring {
                t = t.translatedBy(x: 0, y: sin(time / 0.42 * 2 * .pi) > 0 ? 0.6 : 0)
            } else {
                let active = phase(time, period: 8)
                if active > 0.90 {
                    t = t.concatenating(about(CGPoint(x: 16, y: 16), scaleX: 1.06, y: 1, translateY: 0))
                }
            }
        }
        if !node.motion.isDisjoint(with: [.earTwitchLeft, .earTwitchRight]) {
            let ears = Self.earAngles(time: time, flourish: state.flourish, phase: state.flourishPhase)
            let isLeft = node.motion.contains(.earTwitchLeft)
            let angle = isLeft ? ears.left : ears.right
            if angle != 0 {
                t = t.concatenating(
                    rotate(angleDegrees: angle, around: isLeft ? CGPoint(x: 8, y: 8) : CGPoint(x: 19, y: 9)))
            }
        }
        if !node.motion.isDisjoint(with: [.blinkLeft, .blinkRight]) {
            let eyeCenterX: CGFloat = node.motion.contains(.blinkLeft) ? 9 : 18
            if state.purring {
                t = t.concatenating(about(CGPoint(x: eyeCenterX, y: 12.5), scaleX: 1, y: 0.24, translateY: 0))
            } else if phase(time, period: 4) > 0.965 && phase(time, period: 4) < 0.99 {
                t = t.concatenating(about(CGPoint(x: eyeCenterX, y: 12.5), scaleX: 1, y: 0.1, translateY: 0))
            }
        }
        let huntingAmount: CGFloat
        if state.hunting {
            huntingAmount = clamp01(state.huntingEnter)
        } else if state.huntingReturn {
            huntingAmount = 1 - clamp01(state.huntingReturnProgress)
        } else {
            huntingAmount = 0
        }
        if huntingAmount > 0, node.id == "face-js" { t = t.translatedBy(x: 0, y: 11 * huntingAmount) }
        if huntingAmount > 0, node.motion.contains(.huntingBodyGrow) {
            t = t.concatenating(
                about(CGPoint(x: 16, y: 28), scaleX: 1 + 0.2 * huntingAmount, y: 1 + 0.2 * huntingAmount, translateY: 0)
            )
        }
        if huntingAmount > 0, node.motion.contains(.huntingTailRise) { t = t.translatedBy(x: 0, y: -5 * huntingAmount) }
        return t
    }

    private func cachedClipPaths(for pose: Pose) -> [String: SceneNode] {
        if let cached = clipPathCache[pose.name] { return cached }
        let clips = collectClipPaths(in: pose.root)
        clipPathCache[pose.name] = clips
        return clips
    }

    private func collectClipPaths(in node: SceneNode) -> [String: SceneNode] {
        var clips: [String: SceneNode] = [:]
        func walk(_ node: SceneNode) {
            if node.tag == "clipPath", let id = node.id { clips[id] = node }
            for child in node.children { walk(child) }
        }
        walk(node)
        return clips
    }

    private func applyClipIfNeeded(for node: SceneNode, ctx: CGContext, state: RenderState) {
        guard let raw = node.attr("clip-path"), let id = clipPathId(raw), let clip = activeClipPaths[id] else { return }
        for child in clip.children { addClipShape(child, to: ctx, state: state, transform: .identity) }
        ctx.clip()
    }

    private func addClipShape(_ node: SceneNode, to ctx: CGContext, state: RenderState, transform: CGAffineTransform) {
        var transform = transform.concatenating(node.transform)
        if node.tag == "path", let d = node.attr("d") {
            let path: CGPath
            if let cached = pathCache[d] {
                path = cached
            } else {
                guard let parsed = try? SVGPathParser.path(d) else { return }
                pathCache[d] = parsed
                path = parsed
            }
            if let copied = path.copy(using: &transform) { ctx.addPath(copied) }
        } else if node.tag == "rect", let geometry = rectInfo(for: node, origIndex: 0) {
            let height =
                node.id == "paper-strip-mask"
                ? ScrollReaction.paperHeight(progress: state.scrollProgress) : geometry.height
            let rect = CGRect(x: geometry.x, y: geometry.y, width: geometry.width, height: height)
            ctx.addPath(CGPath(rect: rect, transform: &transform))
        }
        for child in node.children { addClipShape(child, to: ctx, state: state, transform: transform) }
    }

    private func clipPathId(_ raw: String) -> String? {
        guard let hash = raw.firstIndex(of: "#") else { return nil }
        let rest = raw[raw.index(after: hash)...]
        let end = rest.firstIndex(of: ")") ?? rest.endIndex
        return String(rest[..<end])
    }

    private func drawMochiBodyAndPattern(in ctx: CGContext, state: RenderState) {
        guard let morph = stretchMorph(), let bodyColor = color("var(--cat-color)", state: state, heatOverlay: false)
        else { return }
        ctx.setFillColor(bodyColor.cgColor)
        for rect in morph.bodyRectsInPaintOrder {
            ctx.fill(morphedRect(rect, state: state))
        }
        if skipUserPatches { return }
        let spots = state.pattern.spots(for: .body)
        guard !spots.isEmpty else { return }
        let mapping = mappings.mapping(svgName: "stretch-chain", elementId: "body")
        for spot in spots {
            guard let base = NSColor(hex: spot.color) else { continue }
            ctx.setFillColor(heatAdjustedPatternColor(base, state: state).cgColor)
            drawSpot(
                mapping: mapping,
                isStretchBody: true,
                stampMissingMappedCell: false,
                cellX: spot.x,
                cellY: spot.y,
                frame: nil,
                ctx: ctx,
                state: state
            )
        }
    }

    private func drawStretchBodyBlock(blockX: Int, blockY: Int, ctx: CGContext, state: RenderState) {
        guard blockX >= 0, blockY >= 0, blockX < 22, let morph = stretchMorph(), blockY < morph.bodyRows.count else {
            return
        }
        let row = morph.bodyRows[blockY]
        let cellsMaxCol = CGFloat(21)
        let startCol = (CGFloat(blockX) * max(0, row.startWidth - 1) / cellsMaxCol).rounded()
        let endCol = (CGFloat(blockX) * max(0, row.endWidth - 1) / cellsMaxCol).rounded()
        let patch = StretchRect(
            key: row.key,
            startX: row.startX + startCol,
            startY: row.startY,
            startWidth: 1,
            startHeight: row.startHeight,
            endX: row.endX + endCol,
            endY: row.endY,
            endWidth: 1,
            endHeight: row.endHeight,
            segmentIndex: row.segmentIndex
        )
        ctx.fill(morphedRect(patch, state: state))
    }

    private func morphedRect(_ rect: StretchRect, state: RenderState) -> CGRect {
        let t = state.mochiStretchActive ? clamp01(state.stretchT) : 1
        let dx = state.mochiStretchActive ? segmentDX(rect.segmentIndex, state: state) : 0
        return CGRect(
            x: lerp(rect.startX, rect.endX, t) + dx,
            y: lerp(rect.startY, rect.endY, t),
            width: lerp(rect.startWidth, rect.endWidth, t),
            height: lerp(rect.startHeight, rect.endHeight, t))
    }

    private func mochiPartTransform(id: String, node: SceneNode, state: RenderState) -> CGAffineTransform? {
        let t = clamp01(state.stretchT)
        if id == "tail", let morph = stretchMorph() {
            return CGAffineTransform(
                translationX: segmentDX(StretchChain.segmentCount - 1, state: state),
                y: (morph.tailStartY - morph.tailEndY) * (1 - t))
        }
        guard id == "leg-fl" || id == "leg-fr" || id == "leg-rl" || id == "leg-rr", let morph = stretchMorph() else {
            return nil
        }
        let delta = number(node.attr("data-stretch-y-delta"))
        let cy = number(node.attr("data-stretch-cy"))
        let seg = segmentIndex(centerY: cy, bodyYMin: morph.bodyYMin, segmentHeight: morph.segmentHeight)
        return CGAffineTransform(translationX: segmentDX(seg, state: state), y: delta * (1 - t))
    }

    private func stretchReminderTransform(id: String, time: TimeInterval, progress: CGFloat) -> CGAffineTransform? {
        guard progress > 0 else { return nil }
        switch id {
        case "cat-content":
            guard progress > 0.95 else { return nil }
            let offsets: [CGPoint] = [
                CGPoint(x: -0.4, y: 0.2), CGPoint(x: 0.3, y: -0.3), CGPoint(x: -0.3, y: 0.3),
                CGPoint(x: 0.4, y: -0.2), CGPoint(x: -0.2, y: 0.4), CGPoint(x: 0.3, y: 0.2),
                CGPoint(x: -0.4, y: -0.1), CGPoint(x: 0.2, y: 0.3), CGPoint(x: -0.3, y: -0.3),
                CGPoint(x: 0.4, y: 0.1), CGPoint(x: -0.2, y: -0.4), CGPoint(x: 0.3, y: 0.3),
            ]
            let idx = Int((time / 0.09).rounded(.down)) % offsets.count
            let offset = offsets[idx]
            return CGAffineTransform(translationX: offset.x, y: offset.y)
        case "leg-fl":
            return stretchFrontLegTransform(
                translation: CGPoint(x: 4, y: 8.7), origin: CGPoint(x: 11.5, y: 22), progress: progress)
        case "leg-fr":
            return stretchFrontLegTransform(
                translation: CGPoint(x: 2, y: 9.7), origin: CGPoint(x: 20.5, y: 22), progress: progress)
        case "leg-rl", "leg-rr":
            return CGAffineTransform(translationX: 7 * progress, y: -2 * progress)
        case "body":
            return CGAffineTransform(translationX: 5 * progress, y: 1 * progress)
        case "head-group":
            return CGAffineTransform(translationX: 5 * progress, y: 4 * progress)
        case "tail":
            return rotate(angleDegrees: -10 * progress, around: CGPoint(x: 39, y: 21)).translatedBy(
                x: progress, y: -2 * progress)
        default:
            return nil
        }
    }

    private func stretchFrontLegTransform(translation: CGPoint, origin: CGPoint, progress: CGFloat) -> CGAffineTransform
    {
        let scaleY = 1 + (0.69 - 1) * progress
        return CGAffineTransform(translationX: translation.x * progress, y: translation.y * progress)
            .concatenating(rotate(angleDegrees: 51 * progress, around: origin))
            .concatenating(about(origin, scaleX: 1, y: scaleY, translateY: 0))
    }

    private func pupilScaleTransform(for node: SceneNode, factor: CGFloat) -> CGAffineTransform? {
        guard let pupil = rectInfo(for: node, origIndex: 0, includingTransform: true) else { return nil }
        let center = CGPoint(x: pupil.x + pupil.width / 2, y: pupil.y + pupil.height / 2)
        return about(center, scaleX: factor, y: factor, translateY: 0)
    }

    private func jumpLegTransform(id: String, time: TimeInterval) -> CGAffineTransform? {
        switch id {
        case "leg-fl":
            return animatedRotation(
                values: [98, 112, 98, 88, 98], center: CGPoint(x: 15, y: 26), period: 0.32, time: time)
        case "leg-fr":
            return animatedRotation(
                values: [-98, -112, -98, -88, -98], center: CGPoint(x: 25, y: 26), period: 0.32, time: time)
        case "leg-rl":
            return animatedRotation(values: [0, -7, 0, 6, 0], center: CGPoint(x: 14, y: 43), period: 0.42, time: time)
        case "leg-rr":
            return animatedRotation(values: [0, 7, 0, -6, 0], center: CGPoint(x: 26, y: 43), period: 0.42, time: time)
        default:
            return nil
        }
    }

    /// Whole-body kneading while an agent thinks (`RenderState.kneadPhase` > 0), half a cycle per
    /// paw, like a cat kneading a blanket — arch included:
    /// - Paws alternately tuck up into the body, then press down past the resting ground line with
    ///   a slight outward splay (the squash pivots on the paw's bottom edge). The rig's front legs
    ///   barely peek out below the mochi body, so the readable cues are the nub retracting and the
    ///   pressing paw pushing into the ground.
    /// - The back arches: shoulders hunch up (the torso stretches about the ground line while the
    ///   paws stay planted) and the head drops between them, both swelling once per press and
    ///   rocking toward whichever paw is pressing.
    /// `intensity` (0..1, see `KneadMotion`) eases every amplitude in and out so it never pops.
    private func kneadTransform(id: String, time: TimeInterval, intensity: CGFloat) -> CGAffineTransform? {
        let amp = intensity * intensity * (3 - 2 * intensity)
        let theta = phase(time, period: Self.kneadPeriod) * 2 * .pi
        let pulse = abs(sin(theta))  // peaks once per press, either side
        let lean = sin(theta) * amp  // negative while the left paw presses
        switch id {
        case "leg-fl", "leg-fr":
            let outward: CGFloat = id == "leg-fl" ? -1 : 1
            let beat = id == "leg-fl" ? sin(theta) : -sin(theta)
            let lift = max(0, beat)
            let press = max(0, -beat)
            let travel = CGAffineTransform(
                translationX: outward * (0.7 * lift + 0.35 * press) * amp,
                y: (-1.4 * lift + 0.55 * press) * amp)
            return travel.concatenating(
                about(
                    CGPoint(x: id == "leg-fl" ? 11 : 18, y: 36),
                    scaleX: 1 + 0.08 * press * amp, y: 1 - 0.06 * press * amp, translateY: 0))
        case "body":
            return CGAffineTransform(translationX: 0.5 * lean, y: 0)
                .concatenating(
                    about(
                        CGPoint(x: 14, y: 34),
                        scaleX: 1, y: 1 + (0.04 + 0.04 * pulse) * amp, translateY: 0))
        case "face-js":
            return CGAffineTransform(translationX: 0.45 * lean, y: (0.8 + 0.4 * pulse) * amp)
        default:
            return nil
        }
    }

    private func animatedRotation(values: [CGFloat], center: CGPoint, period: TimeInterval, time: TimeInterval)
        -> CGAffineTransform
    {
        let p = phase(time, period: period) * CGFloat(values.count - 1)
        let i = min(values.count - 2, max(0, Int(p.rounded(.down))))
        let local = p - CGFloat(i)
        return rotate(angleDegrees: lerp(values[i], values[i + 1], local), around: center)
    }

    private func stretchMorph() -> StretchMorph? {
        if let stretchMorphCache { return stretchMorphCache }
        let start = library.pose(named: "stretch-start")
        let end = library.pose(named: "stretch-end")
        let startRects = baseRects(in: start.root)
        let endRects = baseRects(in: end.root)
        let body = endRects.filter { $0.y + $0.height >= 25 }
        guard !body.isEmpty else { return nil }
        let bodyYMin = body.map(\.y).min() ?? 0
        let bodyYMax = body.map { $0.y + $0.height }.max() ?? bodyYMin
        let segmentHeight = max(1, (bodyYMax - bodyYMin) / CGFloat(StretchChain.segmentCount))
        var bodyRects: [RectKey: StretchRect] = [:]
        var rows: [StretchRect] = []
        for endRect in body {
            let startRect = endRect.origIndex < startRects.count ? startRects[endRect.origIndex] : endRect
            let seg = segmentIndex(
                centerY: endRect.y + endRect.height / 2, bodyYMin: bodyYMin, segmentHeight: segmentHeight)
            let rect = StretchRect(
                key: endRect.key,
                startX: startRect.x,
                startY: startRect.y,
                startWidth: startRect.width,
                startHeight: startRect.height,
                endX: endRect.x,
                endY: endRect.y,
                endWidth: endRect.width,
                endHeight: endRect.height,
                segmentIndex: seg)
            bodyRects[endRect.key] = rect
            if endRect.width >= 12, endRect.height >= 5 { rows.append(rect) }
        }
        rows.sort { $0.endY < $1.endY }
        let tailStartY = findNode(id: "tail-path", in: start.root).flatMap { firstMoveY($0.attr("d")) } ?? 51
        let tailEndY =
            findNode(id: "tail", in: end.root)
            .flatMap { patchFrame($0) }
            .map { $0.minY + (firstMoveY(library.components.tailPathD) ?? 0) * $0.height } ?? 133
        let morph = StretchMorph(
            bodyRects: bodyRects, bodyRectsInPaintOrder: bodyRects.values.sorted { $0.endY < $1.endY },
            bodyRows: rows, bodyYMin: bodyYMin, segmentHeight: segmentHeight,
            tailStartY: tailStartY, tailEndY: tailEndY)
        stretchMorphCache = morph
        return morph
    }

    private func baseRects(in root: SceneNode) -> [RectInfo] {
        var rects: [RectInfo] = []
        func walk(_ node: SceneNode, excluded: Bool) {
            let nowExcluded =
                excluded || node.tag == "defs" || node.tag == "clipPath" || node.hasClass("patches")
                || node.hasClass("heat-overlay")
            if node.tag == "rect", !nowExcluded,
                let rect = rectInfo(for: node, origIndex: rects.count, includingTransform: true)
            {
                rects.append(rect)
            }
            for child in node.children { walk(child, excluded: nowExcluded) }
        }
        walk(root, excluded: false)
        return rects
    }

    private func rectInfo(for node: SceneNode, origIndex: Int, includingTransform: Bool = false) -> RectInfo? {
        let width = number(node.attr("width"))
        let height = number(node.attr("height"))
        guard width > 0, height > 0 else { return nil }
        var x = number(node.attr("x"))
        var y = number(node.attr("y"))
        if includingTransform, node.attr("x") == nil && node.attr("y") == nil,
            let translated = translatePoint(node.attr("transform"))
        {
            x = translated.x
            y = translated.y
        }
        return RectInfo(
            key: RectKey(x: x, y: y, width: width, height: height), origIndex: origIndex, x: x, y: y, width: width,
            height: height)
    }

    private func translatePoint(_ raw: String?) -> CGPoint? {
        guard let raw, let open = raw.firstIndex(of: "("),
            let close = raw[raw.index(after: open)...].firstIndex(of: ")")
        else { return nil }
        let nums = numbers(String(raw[raw.index(after: open)..<close]))
        guard !nums.isEmpty else { return nil }
        return CGPoint(x: nums[0], y: nums.count > 1 ? nums[1] : 0)
    }

    private func findNode(id: String, in node: SceneNode) -> SceneNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNode(id: id, in: child) { return found }
        }
        return nil
    }

    private func node(at indexPath: [Int], in root: SceneNode) -> SceneNode? {
        var node = root
        for index in indexPath {
            guard index >= 0, index < node.children.count else { return nil }
            node = node.children[index]
        }
        return node
    }

    private func scaleBucket(_ scale: CGFloat) -> Int {
        Int((scale * 1000).rounded())
    }

    private func cachedPatternSignature(for pattern: PatternModel) -> String {
        if let cached = patternSignatureCache, cached.pattern == pattern { return cached.signature }
        let signature = pattern.signature()
        patternSignatureCache = (pattern, signature)
        return signature
    }

    private func layerRasterKey(slot: LayerSlot, pose: Pose, state: RenderState, scale: CGFloat) -> LayerRasterKey {
        LayerRasterKey(
            pose: state.pose,
            scaleBucket: scaleBucket(scale),
            layerID: slot.id,
            patternSignature: patternSignature(part: slot.part, pattern: state.pattern),
            colorSignature: colorSignature(pattern: state.pattern),
            heatBucket: heatBucket(state),
            visibility: slot.visibility
        )
    }

    private func patternSignature(part: PatternPart?, pattern: PatternModel) -> String {
        guard let part else { return "" }
        return pattern.spots(for: part)
            .map { "\($0.x),\($0.y),\($0.color)" }
            .joined(separator: ";")
    }

    private func colorSignature(pattern: PatternModel) -> String {
        [
            pattern.baseColor,
            pattern.resolvedEyeBgColor,
            pattern.resolvedEyeColorLeft,
            pattern.resolvedEyeColorRight,
            pattern.resolvedOutlineColor,
        ].joined(separator: "|")
    }

    private func heatBucket(_ state: RenderState) -> Int {
        let heat = Int((clamp01(state.heat) * 15).rounded())
        let stretching = Int((clamp01(state.stretchingHeat) * 15).rounded())
        return (heat << 8) | stretching
    }

    private func visualSignature(state: RenderState, scale: CGFloat) -> String {
        [
            trackingVisualSignature(state: state),
            "p:\(state.purring)",
            "slp:\(state.sleeping)",
            "h:\(huntingSignature(state))",
            "heat:\(heatBucket(state))",
            "pf:\(pointSignature(state.purrFaceOffset, scale))",
            animationSignature(state),
        ].joined(separator: "|")
    }

    private func silhouetteSignature(state: RenderState, scale: CGFloat) -> String {
        return [
            trackingSilhouetteSignature(state: state),
            "p:\(state.purring)",
            "slp:\(state.sleeping)",
            "h:\(huntingSignature(state))",
            "pf:\(pointSignature(state.purrFaceOffset, scale))",
            silhouetteAnimationSignature(state),
        ].joined(separator: "|")
    }

    private func trackingVisualSignature(state: RenderState) -> String {
        guard state.pose == .idle else { return "track:static" }
        let trackingScale = Self.visualTrackingBucketsPerPoint
        return [
            "tr:\(pointSignature(state.tracking.body, trackingScale))",
            "tf:\(pointSignature(state.tracking.face, trackingScale))",
            "te:\(pointSignature(state.tracking.eyes, trackingScale))",
            "tp:\(pointSignature(state.tracking.pupils, trackingScale))",
        ].joined(separator: "|")
    }

    private func trackingSilhouetteSignature(state: RenderState) -> String {
        guard state.pose == .idle else { return "track:static" }
        // Same bucket density as the fill so the outline never lags the tracked face/petals.
        let trackingScale = Self.visualTrackingBucketsPerPoint
        return [
            "tr:\(pointSignature(state.tracking.body, trackingScale))",
            "tf:\(pointSignature(state.tracking.face, trackingScale))",
        ].joined(separator: "|")
    }

    private func animationSignature(_ state: RenderState) -> String {
        switch state.pose {
        case .idle, .sleepCurl:
            return idleAnimationSignature(state, includeEyes: true)
        case .jumpIng:
            return jumpAnimationSignature(state.time)
        case .pressLeft, .pressRight, .jumpStart:
            return "static"
        case .stretchDefault:
            return stretchDefaultAnimationSignature(state)
        default:
            return monolithicAnimationSignature(state)
        }
    }

    private func silhouetteAnimationSignature(_ state: RenderState) -> String {
        switch state.pose {
        case .idle, .sleepCurl:
            return idleAnimationSignature(state, includeEyes: false)
        case .jumpIng:
            return jumpAnimationSignature(state.time)
        case .pressLeft, .pressRight, .jumpStart:
            return "static"
        case .stretchDefault:
            return stretchDefaultAnimationSignature(state)
        default:
            return monolithicAnimationSignature(state)
        }
    }

    private func idleAnimationSignature(_ state: RenderState, includeEyes: Bool) -> String {
        let time = state.time
        let tailAngle = Self.idleTailAngle(
            time: time, hunting: state.hunting, purring: state.purring, sleeping: state.sleeping,
            thinking: state.thinking, flourish: state.flourish, flourishPhase: state.flourishPhase)
        let breathe =
            includeEyes && !state.hunting && !state.huntingReturn ? quantized(breathePhase(time), scale: 12) : -1
        let whiskers =
            state.purring ? (sin(time / 0.42 * 2 * .pi) > 0 ? 1 : 0) : (phase(time, period: 8) > 0.90 ? 1 : 0)
        let earAngles = Self.earAngles(time: time, flourish: state.flourish, phase: state.flourishPhase)
        let ears = "\(quantized(earAngles.left, scale: 1)),\(quantized(earAngles.right, scale: 1))"
        let eyes =
            includeEyes
            ? ",blink:\(state.eyesClosed ? 2 : (phase(time, period: 4) > 0.965 && phase(time, period: 4) < 0.99 ? 1 : 0))"
            : ""
        let purrBob = includeEyes && state.purring ? (phase(time, period: 1.1) >= 0.5 ? 1 : 0) : 0
        let knead =
            state.kneadPhase > 0
            ? ":k:\(quantized(state.kneadPhase, scale: 32)),\(quantized(phase(time, period: Self.kneadPeriod), scale: 32))"
            : ""
        return "idle:tail:\(quantized(tailAngle, scale: 1)):b:\(breathe):w:\(whiskers):e:\(ears):bob:\(purrBob)\(knead)\(eyes)"
    }

    private func jumpAnimationSignature(_ time: TimeInterval) -> String {
        let front = phase(time, period: 0.32)
        let rear = phase(time, period: 0.42)
        return "jump:\(quantized(front, scale: 64)):\(quantized(rear, scale: 64))"
    }

    private func stretchDefaultAnimationSignature(_ state: RenderState) -> String {
        let progress = quantized(state.stretchPoseProgress, scale: 1000)
        let jitter = state.stretchPoseProgress > 0.95 ? Int((state.time / 0.09).rounded(.down)) : 0
        return "stretchDefault:\(progress):\(jitter)"
    }

    private func monolithicAnimationSignature(_ state: RenderState) -> String {
        [
            "scroll:\(quantized(state.scrollProgress, scale: 1000))",
            "stretch:\(quantized(state.stretchT, scale: 1000))",
            "\(state.stretchSegmentDX.map { quantized($0, scale: 1000) })",
            "poseStretch:\(quantized(state.stretchPoseProgress, scale: 1000))",
            "jump:\(quantized(state.jumpY, scale: 1000)):\(quantized(state.bubbleJumpY, scale: 1000))",
        ].joined(separator: ":")
    }

    private func huntingSignature(_ state: RenderState) -> String {
        let amount: CGFloat
        if state.hunting {
            amount = clamp01(state.huntingEnter)
        } else if state.huntingReturn {
            amount = 1 - clamp01(state.huntingReturnProgress)
        } else {
            amount = 0
        }
        return "\(state.hunting):\(state.huntingReturn):\(quantized(amount, scale: 128))"
    }

    private func breathePhase(_ time: TimeInterval) -> CGFloat {
        (sin(time / 3.5 * 2 * .pi - .pi / 2) + 1) / 2
    }

    private func pointSignature(_ point: CGPoint, _ scale: CGFloat) -> String {
        "\(quantized(point.x, scale: scale)),\(quantized(point.y, scale: scale))"
    }

    private func quantized(_ value: CGFloat, scale: CGFloat) -> Int {
        Int((value * scale).rounded())
    }

    private func firstMoveY(_ d: String?) -> CGFloat? {
        guard let d else { return nil }
        var values: [CGFloat] = []
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            if let value = Double(token) { values.append(CGFloat(value)) }
            token.removeAll(keepingCapacity: true)
        }
        for ch in d {
            if ch == "-" || ch == "." || ch.isNumber {
                token.append(ch)
            } else {
                flush()
                if values.count >= 2 { break }
            }
        }
        flush()
        return values.count >= 2 ? values[1] : nil
    }

    private func segmentIndex(centerY: CGFloat, bodyYMin: CGFloat, segmentHeight: CGFloat) -> Int {
        min(StretchChain.segmentCount - 1, max(0, Int(((centerY - bodyYMin) / max(1, segmentHeight)).rounded(.down))))
    }

    private func segmentDX(_ index: Int, state: RenderState) -> CGFloat {
        guard index >= 0, index < state.stretchSegmentDX.count else { return 0 }
        return state.stretchSegmentDX[index]
    }

    private func stretchPosePeak(_ state: RenderState) -> CGFloat { clamp01(state.stretchPoseProgress) }
    private func clamp01(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private func lineCap(_ raw: String) -> CGLineCap {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "round": return .round
        case "square": return .square
        default: return .butt
        }
    }

    private func lineJoin(_ raw: String) -> CGLineJoin {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "round": return .round
        case "bevel": return .bevel
        default: return .miter
        }
    }

    private func outlineColor(for pattern: PatternModel) -> NSColor {
        NSColor(hex: pattern.resolvedOutlineColor) ?? .white
    }

    private func phase(_ time: TimeInterval, period: TimeInterval) -> CGFloat {
        CGFloat((time.truncatingRemainder(dividingBy: period)) / period)
    }

    static let earFlickLeftPeriod: TimeInterval = 9
    static let earFlickRightPeriod: TimeInterval = 13
    static let earFlickRightOffset: TimeInterval = 5

    /// Idle tail angle shared by `dynamicTransform(for:state:)` and the frame-cache signature so
    /// the two can never drift. Precedence: hunting/purring rhythms, the near-still sleeping tail,
    /// then the plan-approval raised tail, the slow thinking metronome, and finally the mood sway
    /// with a brisk two-beat swish every 19s so the idle cat reads as alive rather than metronomic.
    static func idleTailAngle(
        time: TimeInterval, hunting: Bool, purring: Bool, sleeping: Bool, thinking: Bool,
        flourish: ReactionFlourish, flourishPhase: CGFloat
    ) -> CGFloat {
        if hunting { return CGFloat(sin(time / 0.68 * 2 * .pi) * 2) }
        if purring { return sin(time / 0.22 * 2 * .pi) > 0 ? 12 : -5 }
        if sleeping { return CGFloat(sin(time / 5 * 2 * .pi) * 1.5) }
        if flourish == .planTail {
            let raise = min(1, flourishPhase / 0.15) * (flourishPhase > 0.8 ? max(0, (1 - flourishPhase) / 0.2) : 1)
            return 22 * raise
        }
        if thinking { return CGFloat(sin(time / 2.4 * 2 * .pi) * 7) }
        let base = CGFloat(sin(time / 4 * 2 * .pi) * 4)
        let cycle = time.truncatingRemainder(dividingBy: 19)
        guard cycle >= 17.0, cycle < 18.2 else { return base }
        let p = (cycle - 17.0) / 1.2
        let envelope = CGFloat(sin(p * .pi))
        return base + CGFloat(sin(p * 4 * .pi)) * 9 * envelope
    }

    /// Final ear rotations in degrees, shared by `dynamicTransform(for:state:)` and the frame-cache
    /// signature. A reaction flourish owns the ears while active; otherwise the ambient double
    /// flicks play. Ask flicks the ear on the tilt side twice; an error pins both ears back for the
    /// badge duration; the generic attention nudge perks both ears once.
    static func earAngles(
        time: TimeInterval, flourish: ReactionFlourish, phase: CGFloat
    ) -> (left: CGFloat, right: CGFloat) {
        switch flourish {
        case .askEars:
            let flicked = (phase >= 0.08 && phase < 0.22) || (phase >= 0.36 && phase < 0.52)
            return (0, flicked ? 16 : 0)
        case .errorEars:
            let ramp = min(1, phase / 0.12) * (phase > 0.85 ? max(0, (1 - phase) / 0.15) : 1)
            let step = (ramp * 4).rounded() / 4  // quantized so the ear raster cache stays effective
            return (-20 * step, 20 * step)
        case .attentionEars:
            let perked = phase >= 0.05 && phase < 0.30
            return (perked ? -12 : 0, perked ? 12 : 0)
        case .none, .planTail:
            return (
                earFlickStep(time: time, period: earFlickLeftPeriod, offset: 0) == 1 ? -10 : 0,
                earFlickStep(time: time, period: earFlickRightPeriod, offset: earFlickRightOffset) == 1 ? 10 : 0
            )
        }
    }

    /// Ear flick step shared by `dynamicTransform(for:state:)` and the frame-cache signature:
    /// 0 = rest, 1 = flicked. Two quick pulses at the end of each period read as a real ear shake
    /// instead of the old second-long static hold.
    static func earFlickStep(time: TimeInterval, period: TimeInterval, offset: TimeInterval) -> Int {
        let cycle = (time + offset).truncatingRemainder(dividingBy: period)
        let into = cycle - (period - 0.42)
        guard into >= 0 else { return 0 }
        if into < 0.10 { return 1 }
        if into < 0.18 { return 0 }
        if into < 0.30 { return 1 }
        return 0
    }
    private func number(_ raw: String?) -> CGFloat { raw.flatMap(Double.init).map { CGFloat($0) } ?? 0 }
    private func numbers(_ raw: String) -> [CGFloat] {
        raw.split { $0 == " " || $0 == "," }.compactMap { Double($0) }.map { CGFloat($0) }
    }

    private func rotate(angleDegrees: CGFloat, around p: CGPoint) -> CGAffineTransform {
        .identity.translatedBy(x: p.x, y: p.y).rotated(by: angleDegrees * .pi / 180).translatedBy(x: -p.x, y: -p.y)
    }

    private func about(_ p: CGPoint, scaleX: CGFloat, y scaleY: CGFloat, translateY: CGFloat) -> CGAffineTransform {
        .identity.translatedBy(x: p.x, y: p.y).scaledBy(x: scaleX, y: scaleY).translatedBy(x: 0, y: translateY)
            .translatedBy(x: -p.x, y: -p.y)
    }
}
