import CoreGraphics
import Foundation

struct PoseLibrary: Sendable {
    let components: PoseComponents
    let poses: [String: Pose]

    static func load(bundle: Bundle = .main, resource: String = "poses") throws -> PoseLibrary {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw ResourceError.missing("\(resource).json")
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(PoseResource.self, from: data)
        return PoseLibrary(
            components: decoded.components, poses: Dictionary(uniqueKeysWithValues: decoded.poses.map { ($0.name, $0) })
        )
    }

    func pose(named name: String) -> Pose { poses[name] ?? poses["cat-idle-follow-v2"]! }
}

enum ResourceError: Error, Equatable { case missing(String) }

struct PoseResource: Codable, Sendable {
    var schemaVersion: Int
    var components: PoseComponents
    var poses: [Pose]
}

struct PoseComponents: Codable, Sendable {
    var earLeftPathD: String
    var earRightPathD: String
    var tailPathD: String
}

struct Pose: Codable, Sendable {
    let name: String
    let file: String
    let viewBox: String
    let root: SceneNode
    /// `viewBox` parsed once at load; the renderer reads it several times per frame.
    let viewBoxRect: CGRect

    private enum CodingKeys: String, CodingKey { case name, file, viewBox, root }

    init(name: String, file: String, viewBox: String, root: SceneNode) {
        self.name = name
        self.file = file
        self.viewBox = viewBox
        self.root = root
        let nums = viewBox.split { $0 == " " || $0 == "," }.compactMap { Double($0) }
        viewBoxRect =
            nums.count == 4
            ? CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
            : CGRect(x: 0, y: 0, width: 50, height: 50)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: c.decode(String.self, forKey: .name), file: c.decode(String.self, forKey: .file),
            viewBox: c.decode(String.self, forKey: .viewBox), root: c.decode(SceneNode.self, forKey: .root))
    }
}

/// One SVG element of a pose. Attribute-derived values the renderer queries every frame (id,
/// class tokens, static transform) are parsed once at load instead of per lookup.
struct SceneNode: Codable, Sendable {
    let tag: String
    let attrs: [String: String]
    let children: [SceneNode]
    let id: String?
    /// The `transform` attribute as a matrix; identity when absent.
    let transform: CGAffineTransform
    /// Animation hooks among the `class` tokens, for `PixelCompositor.dynamicTransform`.
    let motion: MotionClasses
    private let classes: Set<Substring>

    private enum CodingKeys: String, CodingKey { case tag, attrs, children }

    init(tag: String, attrs: [String: String], children: [SceneNode]) {
        self.tag = tag
        self.attrs = attrs
        self.children = children
        id = attrs["id"]
        transform = SVGTransformParser.parse(attrs["transform"])
        classes = Set((attrs["class"] ?? "").split(separator: " "))
        motion = MotionClasses(classes: classes)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            tag: c.decode(String.self, forKey: .tag), attrs: c.decode([String: String].self, forKey: .attrs),
            children: c.decode([SceneNode].self, forKey: .children))
    }

    func attr(_ key: String) -> String? { attrs[key] }

    func hasClass(_ name: String) -> Bool { !classes.isEmpty && classes.contains(Substring(name)) }
}

/// The `class` tokens that drive per-frame motion, as bits so the per-node, per-frame checks
/// in `PixelCompositor.dynamicTransform` cost no string hashing.
struct MotionClasses: OptionSet, Sendable {
    let rawValue: UInt16

    static let breathe = MotionClasses(rawValue: 1 << 0)
    static let tailSway = MotionClasses(rawValue: 1 << 1)
    static let whiskersFlex = MotionClasses(rawValue: 1 << 2)
    static let earTwitchLeft = MotionClasses(rawValue: 1 << 3)
    static let earTwitchRight = MotionClasses(rawValue: 1 << 4)
    static let blinkLeft = MotionClasses(rawValue: 1 << 5)
    static let blinkRight = MotionClasses(rawValue: 1 << 6)
    static let pupil = MotionClasses(rawValue: 1 << 7)
    static let huntingBodyGrow = MotionClasses(rawValue: 1 << 8)
    static let huntingTailRise = MotionClasses(rawValue: 1 << 9)

    init(rawValue: UInt16) { self.rawValue = rawValue }

    fileprivate init(classes: Set<Substring>) {
        let names: [(String, MotionClasses)] = [
            ("breathe-anim", .breathe), ("tail-sway", .tailSway), ("whiskers-flex", .whiskersFlex),
            ("ear-twitch-l", .earTwitchLeft), ("ear-twitch-r", .earTwitchRight),
            ("eye-l-blink", .blinkLeft), ("eye-r-blink", .blinkRight),
            ("pupil-left", .pupil), ("pupil-right", .pupil),
            ("hunting-body-grow", .huntingBodyGrow), ("hunting-tail-rise", .huntingTailRise),
        ]
        self = names.reduce(into: []) { flags, entry in
            if classes.contains(Substring(entry.0)) { flags.insert(entry.1) }
        }
    }
}

struct CellMappings: Sendable {
    let mappings: [String: CellMapping]
    private let prepared: [String: CellPixelMapping]

    init(mappings: [String: CellMapping]) {
        self.mappings = mappings
        self.prepared = mappings.mapValues(CellPixelMapping.init)
    }

    static func load(bundle: Bundle = .main) throws -> CellMappings {
        guard let url = bundle.url(forResource: "cell-mappings", withExtension: "json") else {
            throw ResourceError.missing("cell-mappings.json")
        }
        let data = try Data(contentsOf: url)
        let resource = try JSONDecoder().decode(CellMappingsResource.self, from: data)
        return CellMappings(mappings: resource.mappings)
    }

    func mapping(svgName: String, elementId: String) -> CellPixelMapping? {
        prepared["\(svgName):\(elementId)"]
    }

    func pixels(svgName: String, elementId: String, cellX: Int, cellY: Int) -> [CGPoint]? {
        guard let mapping = mapping(svgName: svgName, elementId: elementId) else { return nil }
        return mapping.points(cellX: cellX, cellY: cellY) ?? []
    }

    func dimensions(svgName: String, elementId: String) -> (Int, Int)? {
        guard let mapping = mappings["\(svgName):\(elementId)"] else { return nil }
        return (mapping.cellsX, mapping.cellsY)
    }
}

struct CellPixelMapping: Sendable {
    private let cells: [CellKey: CellPixels]

    init(_ mapping: CellMapping) {
        let originX = mapping.origin.first ?? 0
        let originY = mapping.origin.dropFirst().first ?? 0
        var cells: [CellKey: CellPixels] = [:]
        cells.reserveCapacity(mapping.cells.count)
        for (rawKey, offsets) in mapping.cells {
            guard let key = CellKey(rawKey) else { continue }
            var points: [CGPoint] = []
            var rects: [CGRect] = []
            points.reserveCapacity(offsets.count)
            rects.reserveCapacity(offsets.count)
            for offset in offsets {
                let point = CGPoint(
                    x: originX + (offset.first ?? 0),
                    y: originY + (offset.dropFirst().first ?? 0)
                )
                points.append(point)
                rects.append(CGRect(x: point.x, y: point.y, width: 1, height: 1))
            }
            cells[key] = CellPixels(points: points, rects: rects)
        }
        self.cells = cells
    }

    func points(cellX: Int, cellY: Int) -> [CGPoint]? {
        cells[CellKey(column: cellX, row: cellY)]?.points
    }

    func rects(cellX: Int, cellY: Int) -> [CGRect]? {
        cells[CellKey(column: cellX, row: cellY)]?.rects
    }
}

private struct CellPixels: Sendable {
    let points: [CGPoint]
    let rects: [CGRect]
}

private struct CellKey: Hashable, Sendable {
    let column: Int
    let row: Int

    init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    init?(_ raw: String) {
        let parts = raw.split(separator: ",", maxSplits: 1)
        guard parts.count == 2, let column = Int(parts[0]), let row = Int(parts[1]) else { return nil }
        self.column = column
        self.row = row
    }
}

struct CellMappingsResource: Codable, Sendable {
    var schemaVersion: Int
    var mappings: [String: CellMapping]
}

struct CellMapping: Codable, Sendable {
    var cellsX: Int
    var cellsY: Int
    var origin: [CGFloat]
    var svgW: CGFloat
    var svgH: CGFloat
    var cells: [String: [[CGFloat]]]
}
