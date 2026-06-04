import CoreGraphics
import Foundation

/// Dynamic nodes must stay in lock-step with PixelCompositor.dynamicTransform(for:state:).
enum DynamicVocabulary {
    static let ids: Set<String> = [
        "body", "cat-content", "face-js", "eyes-js", "head-group", "pupil-left", "pupil-right", "tail",
        "leg-fl", "leg-fr", "leg-rl", "leg-rr",
    ]

    static let classes: Set<String> = [
        "pupil-left", "pupil-right", "breathe-anim", "tail-sway", "whiskers-flex",
        "ear-twitch-l", "ear-twitch-r", "eye-l-blink", "eye-r-blink",
        "hunting-body-grow", "hunting-tail-rise",
    ]

    static func isBoundary(_ node: SceneNode, poseName: String) -> Bool {
        if let id = node.id, idBoundaryIsActive(id, poseName: poseName) { return true }
        for name in classes where node.hasClass(name) && classBoundaryIsActive(name, poseName: poseName) { return true }
        return false
    }

    static func isBoundary(_ node: SceneNode) -> Bool {
        if let id = node.id, ids.contains(id) { return true }
        for name in classes where node.hasClass(name) { return true }
        return false
    }

    private static func idBoundaryIsActive(_ id: String, poseName: String) -> Bool {
        switch id {
        case "body":
            return poseName == PetPose.idle.rawValue || poseName == PetPose.sleepCurl.rawValue
                || poseName == PetPose.stretchDefault.rawValue
        case "face-js", "eyes-js", "pupil-left", "pupil-right":
            return poseName == PetPose.idle.rawValue || poseName == PetPose.sleepCurl.rawValue
        case "leg-fl", "leg-fr":
            // Front paws knead in idle (PixelCompositor.kneadTransform) on top of the
            // jump/stretch leg animations shared with the rear legs.
            return poseName == PetPose.idle.rawValue || poseName == PetPose.jumpIng.rawValue
                || poseName == PetPose.stretchDefault.rawValue
        case "leg-rl", "leg-rr":
            return poseName == PetPose.jumpIng.rawValue || poseName == PetPose.stretchDefault.rawValue
        case "cat-content", "head-group", "tail":
            return poseName == PetPose.stretchDefault.rawValue
        default:
            return false
        }
    }

    private static func classBoundaryIsActive(_ name: String, poseName: String) -> Bool {
        switch name {
        case "pupil-left", "pupil-right", "breathe-anim", "tail-sway", "whiskers-flex",
            "ear-twitch-l", "ear-twitch-r", "eye-l-blink", "eye-r-blink",
            "hunting-body-grow", "hunting-tail-rise":
            return poseName == PetPose.idle.rawValue || poseName == PetPose.sleepCurl.rawValue
        default:
            return false
        }
    }
}

enum LayerVisibility: Hashable {
    case always
    case hiddenWhenEyesClosed
    case eyesClosedOnly

    func includes(_ state: RenderState) -> Bool {
        switch self {
        case .always: return true
        case .hiddenWhenEyesClosed: return !state.eyesClosed
        case .eyesClosedOnly: return state.eyesClosed
        }
    }
}

struct LayerSlot {
    let id: String
    let indexPath: [Int]
    let ancestorChain: [SceneNode]
    let root: SceneNode
    let restCTM: CGAffineTransform
    let restCTMInverse: CGAffineTransform
    let part: PatternPart?
    let silhouette: Bool
    let visibility: LayerVisibility
}

struct PoseLayerPlan {
    let slots: [LayerSlot]
    let hoistedBreatheIndexPath: [Int]?

    static func build(pose: Pose, scale: CGFloat, viewBox: CGRect) -> PoseLayerPlan {
        var slots: [LayerSlot] = []
        var breatheIndexPath: [Int]?
        let base = baseTransform(poseName: pose.name, scale: scale, viewBox: viewBox)

        func walk(_ node: SceneNode, indexPath: [Int], ancestors: [SceneNode], inheritedLayerID: String?) {
            if node.tag == "defs" || node.tag == "clipPath" { return }

            let boundary = DynamicVocabulary.isBoundary(node, poseName: pose.name)
            if node.hasClass("breathe-anim"), breatheIndexPath == nil { breatheIndexPath = indexPath }
            let currentLayerID = node.id ?? inheritedLayerID
            let chain = ancestors + [node]

            if boundary, isLayerableBoundary(node) {
                appendSlot(node: node, indexPath: indexPath, chain: chain, inheritedLayerID: currentLayerID)
                return
            }

            if !boundary, !containsActiveBoundaryDescendant(node, poseName: pose.name), hasRenderableSubtree(node) {
                appendSlot(node: node, indexPath: indexPath, chain: chain, inheritedLayerID: currentLayerID)
                return
            }

            for (childIndex, child) in node.children.enumerated() {
                walk(child, indexPath: indexPath + [childIndex], ancestors: chain, inheritedLayerID: currentLayerID)
            }
        }

        func appendSlot(node: SceneNode, indexPath: [Int], chain: [SceneNode], inheritedLayerID: String?) {
            let eyeLayerID = chain.reversed().compactMap(\.id).first { $0 == "eye-left" || $0 == "eye-right" }
            let id = layerID(for: node, inherited: eyeLayerID ?? inheritedLayerID, indexPath: indexPath)
            let rest = chain.reduce(base) { partial, node in
                SVGTransformParser.parse(node.attr("transform")).concatenating(partial)
            }
            slots.append(
                LayerSlot(
                    id: id,
                    indexPath: indexPath,
                    ancestorChain: chain,
                    root: node,
                    restCTM: rest,
                    restCTMInverse: rest.inverted(),
                    part: PatternPart.forElement(id),
                    silhouette: isSilhouetteLayer(id: id, node: node, chain: chain),
                    visibility: visibility(for: id, node: node, chain: chain)
                ))
        }

        walk(pose.root, indexPath: [], ancestors: [], inheritedLayerID: nil)
        return PoseLayerPlan(slots: slots, hoistedBreatheIndexPath: breatheIndexPath)
    }

    static func baseTransform(poseName: String, scale: CGFloat, viewBox: CGRect) -> CGAffineTransform {
        var transform = CGAffineTransform.identity
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.translatedBy(x: -viewBox.minX, y: -viewBox.minY)
        if poseName == PetPose.jumpStart.rawValue || poseName == PetPose.jumpIng.rawValue {
            transform = transform.translatedBy(x: viewBox.midX, y: viewBox.midY)
            transform = transform.scaledBy(x: 1.12, y: 1.12)
            transform = transform.translatedBy(x: -viewBox.midX, y: -viewBox.midY)
        }
        return transform
    }

    private static func containsActiveBoundaryDescendant(_ node: SceneNode, poseName: String) -> Bool {
        for child in node.children {
            if DynamicVocabulary.isBoundary(child, poseName: poseName) { return true }
            if containsActiveBoundaryDescendant(child, poseName: poseName) { return true }
        }
        return false
    }

    private static func isLayerableBoundary(_ node: SceneNode) -> Bool {
        if let id = node.id, PatternPart.forElement(id) != nil { return true }
        if node.id == "pupil-left" || node.id == "pupil-right" { return true }
        return node.tag == "path" || node.tag == "rect"
    }

    private static func hasRenderableSubtree(_ node: SceneNode) -> Bool {
        if node.tag == "path" || node.tag == "rect" { return true }
        if let id = node.id, id == "tail" || id == "ear-left" || id == "ear-right" { return true }
        return node.children.contains { hasRenderableSubtree($0) }
    }

    private static func layerID(for node: SceneNode, inherited: String?, indexPath: [Int]) -> String {
        if let id = node.id { return id }
        if indexPath.starts(with: [1, 0, 3, 4, 0, 0, 0]) { return "eye-left" }
        if indexPath.starts(with: [1, 0, 3, 4, 1, 0, 0]) { return "eye-right" }
        if node.hasClass("closed-eye-line") {
            return indexPath.last == 2 ? "closed-eye-line-left" : "closed-eye-line-right"
        }
        if let inherited, inherited == "eye-left" || inherited == "eye-right" { return inherited }
        return "layer-" + indexPath.map(String.init).joined(separator: "-")
    }

    private static func visibility(for id: String, node: SceneNode, chain: [SceneNode]) -> LayerVisibility {
        if node.hasClass("closed-eye-line") || id.hasPrefix("closed-eye-line") { return .eyesClosedOnly }
        if chain.contains(where: { $0.id == "eye-left" || $0.id == "eye-right" }) { return .hiddenWhenEyesClosed }
        return .always
    }

    private static func isSilhouetteLayer(id: String, node: SceneNode, chain: [SceneNode]) -> Bool {
        if id == "pupil-left" || id == "pupil-right" { return false }
        if id == "eye-left" || id == "eye-right" { return false }
        if id.hasPrefix("closed-eye-line") { return false }
        if chain.contains(where: { $0.id == "eye-left" || $0.id == "eye-right" }) { return false }
        return true
    }
}

struct LayerRasterKey: Hashable {
    let pose: PetPose
    let scaleBucket: Int
    let layerID: String
    let patternSignature: String
    let colorSignature: String
    let heatBucket: Int
    let visibility: LayerVisibility
}

struct FrameKey: Hashable {
    let pose: PetPose
    let scaleBucket: Int
    let width: Int
    let height: Int
    let patternSignature: String
    let visualSignature: String
}

struct OutlineKey: Hashable {
    let pose: PetPose
    let scaleBucket: Int
    let width: Int
    let height: Int
    let outlineColor: String
    let silhouetteSignature: String
}
