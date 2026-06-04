import CoreGraphics
import Foundation

struct CatHitTester {
    static func isCatHit(point: CGPoint, in bounds: CGRect, stretched: Bool = false) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        if stretched {
            return ellipse(x, y, cx: 0.50, cy: 0.20, rx: 0.20, ry: 0.14)
                || ellipse(x, y, cx: 0.50, cy: 0.52, rx: 0.18, ry: 0.38)
        }
        if ellipse(x, y, cx: 0.4, cy: 0.3, rx: 0.24, ry: 0.22) { return true }
        if ellipse(x, y, cx: 0.55, cy: 0.62, rx: 0.3, ry: 0.3) { return true }
        return (0.28...0.72).contains(x) && (0.3...0.78).contains(y)
    }

    static func isHead(point: CGPoint, in bounds: CGRect) -> Bool {
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        return ellipse(x, y, cx: 0.40, cy: 0.33, rx: 0.25, ry: 0.23)
    }

    private static func ellipse(_ x: CGFloat, _ y: CGFloat, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) -> Bool
    {
        let nx = (x - cx) / rx
        let ny = (y - cy) / ry
        return nx * nx + ny * ny <= 1
    }
}

enum CatLayout {
    /// Fit an image of `imageWidth`×`imageHeight` inside `catRect`, preserving aspect ratio and
    /// centering — the SVG default `preserveAspectRatio="xMidYMid meet"`. Square poses fill the
    /// rect; tall/wide poses (stretch 40×145, jump 40×62, stretch-default 72×56) keep their shape.
    static func fittedRect(imageWidth: Int, imageHeight: Int, in catRect: CGRect) -> CGRect {
        let iw = CGFloat(max(1, imageWidth))
        let ih = CGFloat(max(1, imageHeight))
        let scale = min(catRect.width / iw, catRect.height / ih)
        let w = iw * scale
        let h = ih * scale
        return CGRect(x: catRect.midX - w / 2, y: catRect.midY - h / 2, width: w, height: h)
    }

    /// Source crop and on-screen destination for one horizontal band of a stretch pose (the chain
    /// applies a per-band horizontal sway). The compositor bitmap is stored bottom-up relative to the
    /// flipped pet view — the whole-image `ctx.draw(image:in:)` path flips it implicitly — so a band
    /// taken from the *top* of the stored image must be drawn at the *bottom* of `fitted`, otherwise
    /// the cat reassembles head-down. The caller adds the horizontal chain offset to `dest`.
    static func stretchBand(index: Int, count: Int, imageWidth: Int, imageHeight: Int, fitted: CGRect) -> (
        source: CGRect, dest: CGRect
    ) {
        let bands = max(1, count)
        let height = max(1, imageHeight)
        let bandHeight = height / bands
        let sourceY = index * bandHeight
        let sourceHeight = index == bands - 1 ? height - sourceY : bandHeight
        let scale = fitted.height / CGFloat(height)
        let source = CGRect(x: 0, y: sourceY, width: imageWidth, height: sourceHeight)
        let destY = fitted.minY + CGFloat(height - sourceY - sourceHeight) * scale
        let dest = CGRect(x: fitted.minX, y: destY, width: fitted.width, height: CGFloat(sourceHeight) * scale)
        return (source, dest)
    }

    /// Anchored-dangle placement for a *lifted* cat. Unlike `fittedRect` (which scales the tall
    /// stretch canvas down to fit the square, shrinking the whole cat the instant a lift starts),
    /// this renders the stretch pose at the resting head scale and pins the head near its idle
    /// position, so the body, legs, and tail elongate *downward* below the resting silhouette as the
    /// morph (`stretchT`) grows. `catRect` is the resting square; the returned rect extends past its
    /// bottom into the dangle room the window reserves (`liftRoomBelow`).
    static let liftReference: CGFloat = 50  // canvas units mapped across the resting square → head matches idle scale
    static let liftHeadInset: CGFloat = 0.20  // fraction of the resting square; lands the head at the idle head
    static let liftDangleSpan: CGFloat = 2.1  // hang room reserved below the head, in resting-square units

    static func liftScale(catSide: CGFloat) -> CGFloat { catSide / liftReference }

    static func liftedRect(imageWidth: Int, imageHeight: Int, in catRect: CGRect) -> CGRect {
        let scale = liftScale(catSide: catRect.height)
        let w = CGFloat(max(1, imageWidth)) * scale
        let h = CGFloat(max(1, imageHeight)) * scale
        return CGRect(x: catRect.midX - w / 2, y: catRect.minY + liftHeadInset * catRect.height, width: w, height: h)
    }

    /// Vertical span (measured from the resting square's top) the window reserves below the cat so the
    /// capped dangle hangs without clipping.
    static func liftRoomBelow(catSide: CGFloat) -> CGFloat {
        (liftHeadInset + liftDangleSpan) * catSide
    }
}
