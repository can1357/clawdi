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
    var name: String
    var file: String
    var viewBox: String
    var root: SceneNode

    var viewBoxRect: CGRect {
        let nums = viewBox.split { $0 == " " || $0 == "," }.compactMap { Double($0) }
        guard nums.count == 4 else { return CGRect(x: 0, y: 0, width: 50, height: 50) }
        return CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }
}

struct SceneNode: Codable, Sendable {
    var tag: String
    var attrs: [String: String]
    var children: [SceneNode]

    var id: String? { attrs["id"] }
    func attr(_ key: String) -> String? { attrs[key] }

    func hasClass(_ name: String) -> Bool {
        guard let raw = attrs["class"], !raw.isEmpty else { return false }
        var index = raw.startIndex
        while index < raw.endIndex {
            while index < raw.endIndex, raw[index] == " " { index = raw.index(after: index) }
            let start = index
            while index < raw.endIndex, raw[index] != " " { index = raw.index(after: index) }
            if start < index, raw[start..<index] == name { return true }
        }
        return false
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
