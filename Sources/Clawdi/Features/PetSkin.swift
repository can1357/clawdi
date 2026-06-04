import Foundation

/// Selectable pet character. Every skin is rendered by the same `PixelCompositor` animation engine;
/// a skin just swaps the bundled pose-geometry library it draws from.
enum PetSkin: String, Codable, CaseIterable, Sendable {
    case cat
    case flowerClaude = "flower-claude"

    var displayName: String {
        switch self {
        case .cat: return "Cat"
        case .flowerClaude: return "Flowery Claude"
        }
    }

    /// Bundled pose-library resource basename (`<name>.json`) this skin's geometry loads from.
    var poseResource: String {
        switch self {
        case .cat: return "poses"
        case .flowerClaude: return "flower-poses"
        }
    }

    /// The cat morphs into the procedural mochi noodle on stretch; sprite-free skins keep stretch
    /// inside the resting square and render monolithically.
    var usesProceduralRig: Bool { self == .cat }
}
