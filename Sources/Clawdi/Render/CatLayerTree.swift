import AppKit
import QuartzCore

/// GPU-composited presentation of the pet.
///
/// Every pose slot becomes a pair of CALayers — sticker-outline underlay below, fill above —
/// whose contents are the compositor's cached rasters. All per-frame animation (cursor
/// tracking, tail sway, breathing, kneading, ear flicks, blink visibility, and the whole-cat
/// shake/jump/tilt/pop effects) is expressed as layer transforms that Core Animation
/// composites on the GPU, so moving the cat costs no CPU rasterization at all. The CPU only
/// rasterizes when artwork actually changes: pose, supersample scale, pattern, or heat tint.
///
/// The sticker outline stays exact because dilation distributes over union: per-slot dilated
/// underlays, z-ordered below every fill, produce the same ring as dilating the assembled
/// silhouette. Slots whose `silhouette` flag is false (eyes, pupils) get no underlay, matching
/// the monolithic outline's interior behavior.
///
/// Poses without a layered plan (scroll, the stretch morphs, `forceMonolithic` skins, sub-2x
/// scales) fall back to a single layer whose contents is the monolithic
/// `render(state:scale:)` image, updated only when the frame key changes.
@MainActor
final class CatLayerTree {
    /// Root layer; the host view adds it to its backing layer. Its transform maps the
    /// compositor's device-pixel space onto the fitted cat rect in (flipped) view coordinates,
    /// including the whole-cat shake/jump/tilt/pop effects.
    let containerLayer = CALayer()

    private let breatheLayer = CALayer()
    private let outlineGroup = CALayer()
    private let fillGroup = CALayer()
    private let fallbackLayer = CALayer()

    private var compositor: PixelCompositor
    private var slots: [SlotLayers] = []
    private var planKey: PlanKey?
    private var contentBucket = Int.min
    private var contentPattern: PatternModel?
    private var fallbackKey: FrameKey?

    private struct PlanKey: Equatable {
        let pose: PetPose
        let scaleBucket: Int
    }

    private final class SlotLayers {
        let fill = SlotLayers.makeLayer()
        let outline = SlotLayers.makeLayer()
        var fillRect = CGRect.zero
        var outlineRect = CGRect.zero
        var empty = true

        static func makeLayer() -> CALayer {
            let layer = CALayer()
            layer.anchorPoint = .zero
            layer.position = .zero
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            layer.contentsGravity = .resize
            return layer
        }
    }

    init(compositor: PixelCompositor) {
        self.compositor = compositor
        for layer in [containerLayer, breatheLayer, outlineGroup, fillGroup] {
            layer.anchorPoint = .zero
            layer.position = .zero
        }
        fallbackLayer.anchorPoint = .zero
        fallbackLayer.position = .zero
        fallbackLayer.magnificationFilter = .nearest
        fallbackLayer.minificationFilter = .nearest
        fallbackLayer.contentsGravity = .resize
        containerLayer.addSublayer(fallbackLayer)
        containerLayer.addSublayer(breatheLayer)
        breatheLayer.addSublayer(outlineGroup)
        breatheLayer.addSublayer(fillGroup)
    }

    /// Swap the renderer (character change) and drop every cached association.
    func replaceCompositor(_ compositor: PixelCompositor) {
        self.compositor = compositor
        planKey = nil
        fallbackKey = nil
        contentBucket = .min
        contentPattern = nil
    }

    /// Reflect `state` into the layer tree. Called once per frame tick; cheap when nothing
    /// but transforms changed. `catRect` is the resting square in the pet view's flipped
    /// coordinates; `viewHeight` converts it into the non-flipped host layer's y-up space;
    /// `lifting` selects the mochi-lift fallback placement.
    func update(state: RenderState, scale: CGFloat, catRect: CGRect, lifting: Bool, viewHeight: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if !lifting, let frame = compositor.layeredFrame(state: state, scale: scale) {
            fallbackLayer.isHidden = true
            breatheLayer.isHidden = false
            updateTree(frame: frame, state: state, scale: scale, catRect: catRect, viewHeight: viewHeight)
        } else {
            breatheLayer.isHidden = true
            fallbackLayer.isHidden = false
            updateFallback(state: state, scale: scale, catRect: catRect, lifting: lifting, viewHeight: viewHeight)
        }
    }

    // MARK: - Layered path

    private func updateTree(
        frame: PixelCompositor.LayeredFrame, state: RenderState, scale: CGFloat, catRect: CGRect,
        viewHeight: CGFloat
    ) {
        let key = PlanKey(pose: state.pose, scaleBucket: Int((max(1, scale) * 1000).rounded()))
        if key != planKey {
            rebuild(frame: frame)
            planKey = key
            contentBucket = .min
        }
        let bucket = compositor.slotContentBucket(state: state, scale: scale)
        if bucket != contentBucket || contentPattern != state.pattern {
            reloadContents(frame: frame, state: state, scale: scale)
            contentBucket = bucket
            contentPattern = state.pattern
        }

        let device = CGSize(width: frame.width, height: frame.height)
        setBounds(containerLayer, CGRect(origin: .zero, size: device))
        setTransform(
            containerLayer,
            effectsTransform(state: state, catRect: catRect, device: device, viewHeight: viewHeight))
        setTransform(breatheLayer, compositor.breatheTransform(state: state, frame: frame))

        for (slot, layers) in zip(frame.plan.slots, slots) {
            let hidden = layers.empty || !slot.visibility.includes(state)
            layers.fill.isHidden = hidden
            layers.outline.isHidden = hidden || layers.outline.contents == nil
            guard !hidden else { continue }
            let blit = compositor.slotBlitTransform(slot: slot, state: state, frame: frame)
            setTransform(
                layers.fill,
                CGAffineTransform(translationX: layers.fillRect.minX, y: layers.fillRect.minY)
                    .concatenating(blit))
            if layers.outline.contents != nil {
                setTransform(
                    layers.outline,
                    CGAffineTransform(translationX: layers.outlineRect.minX, y: layers.outlineRect.minY)
                        .concatenating(blit))
            }
        }
    }

    private func rebuild(frame: PixelCompositor.LayeredFrame) {
        outlineGroup.sublayers?.forEach { $0.removeFromSuperlayer() }
        fillGroup.sublayers?.forEach { $0.removeFromSuperlayer() }
        slots = frame.plan.slots.map { _ in SlotLayers() }
        for layers in slots {
            outlineGroup.addSublayer(layers.outline)
            fillGroup.addSublayer(layers.fill)
        }
    }

    private func reloadContents(frame: PixelCompositor.LayeredFrame, state: RenderState, scale: CGFloat) {
        for (slot, layers) in zip(frame.plan.slots, slots) {
            guard let surface = compositor.slotSurface(slot: slot, state: state, scale: scale, frame: frame) else {
                layers.empty = true
                layers.fill.contents = nil
                layers.outline.contents = nil
                continue
            }
            layers.empty = false
            layers.fill.contents = surface.fill
            layers.fill.bounds = CGRect(x: 0, y: 0, width: surface.fill.width, height: surface.fill.height)
            layers.fillRect = surface.fillRect
            if let outline = surface.outline {
                layers.outline.contents = outline.image
                layers.outline.bounds = CGRect(
                    x: 0, y: 0, width: outline.image.width, height: outline.image.height)
                layers.outlineRect = outline.rect
            } else {
                layers.outline.contents = nil
            }
        }
    }

    // MARK: - Monolithic fallback

    private func updateFallback(
        state: RenderState, scale: CGFloat, catRect: CGRect, lifting: Bool, viewHeight: CGFloat
    ) {
        let key = compositor.renderFrameKey(state: state, scale: scale)
        if key != fallbackKey {
            guard let image = compositor.render(state: state, scale: scale) else { return }
            fallbackLayer.contents = image
            fallbackLayer.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            fallbackKey = key
        }
        let device = fallbackLayer.bounds.size
        guard device.width > 0, device.height > 0 else { return }
        setBounds(containerLayer, CGRect(origin: .zero, size: device))

        if lifting {
            let vb = compositor.viewBox(for: state.pose.rawValue)
            let lifted = CatLayout.liftedRect(
                imageWidth: Int(vb.width.rounded()), imageHeight: Int(vb.height.rounded()), in: catRect)
            setTransform(containerLayer, deviceToHost(fitted: lifted, device: device, viewHeight: viewHeight))
        } else {
            setTransform(
                containerLayer,
                effectsTransform(state: state, catRect: catRect, device: device, viewHeight: viewHeight))
        }
    }

    // MARK: - Geometry

    /// Maps device space onto `fitted` (given in the pet view's flipped coordinates) inside
    /// the host layer. Parity fixed empirically: layer contents render row-0-first in the
    /// host's space, so device y maps top-down from the fitted rect's top edge.
    private func deviceToHost(fitted: CGRect, device: CGSize, viewHeight: CGFloat) -> CGAffineTransform {
        let factor = fitted.width / device.width
        return CGAffineTransform(scaleX: factor, y: -factor)
            .concatenating(CGAffineTransform(translationX: fitted.minX, y: viewHeight - fitted.minY))
    }

    /// Whole-body effects transform: shake/jump offset the resting
    /// square, pop inflates it about its center, tilt rotates about the feet. Rects arrive in
    /// flipped view coordinates; rotation flips sign in the host's y-up space.
    private func effectsTransform(
        state: RenderState, catRect: CGRect, device: CGSize, viewHeight: CGFloat
    ) -> CGAffineTransform {
        let body = catRect.offsetBy(dx: state.shakeX * catRect.width, dy: -state.jumpY * catRect.height)
        let pop = state.popScale
        let drawRect = pop != 0 ? body.insetBy(dx: -body.width * pop / 2, dy: -body.height * pop / 2) : body
        let fitted = CatLayout.fittedRect(
            imageWidth: Int(device.width), imageHeight: Int(device.height), in: drawRect)
        var transform = deviceToHost(fitted: fitted, device: device, viewHeight: viewHeight)
        if state.tiltAngle != 0 {
            let feet = CGPoint(x: body.midX, y: viewHeight - body.maxY)
            let tilt = CGAffineTransform(translationX: feet.x, y: feet.y)
                .rotated(by: -state.tiltAngle)
                .translatedBy(x: -feet.x, y: -feet.y)
            transform = transform.concatenating(tilt)
        }
        return transform
    }

    private func setTransform(_ layer: CALayer, _ transform: CGAffineTransform) {
        let t3d = CATransform3DMakeAffineTransform(transform)
        if !CATransform3DEqualToTransform(layer.transform, t3d) { layer.transform = t3d }
    }

    private func setBounds(_ layer: CALayer, _ bounds: CGRect) {
        if layer.bounds != bounds { layer.bounds = bounds }
    }
}
