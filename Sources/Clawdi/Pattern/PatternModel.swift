import AppKit
import Foundation

struct Spot: Codable, Hashable, Sendable {
    var x: Int
    var y: Int
    var color: String
}

private let defaultBaseColor = "#1A1A1A"
private let defaultEyeColor = "#1A1A1A"
private let defaultEyeBgColor = "#FFFFFF"
private let defaultOutlineColor = "#FFFFFF"

enum PatternPart: String, CaseIterable, Codable, Sendable, Identifiable {
    case head, body, tail, legFl, legFr, legRl, legRr, earL, earR
    var id: String { rawValue }
    var elementIDs: [String] {
        switch self {
        case .head: return ["head"]
        case .body: return ["body"]
        case .tail: return ["tail"]
        case .legFl: return ["leg-fl"]
        case .legFr: return ["leg-fr"]
        case .legRl: return ["leg-rl"]
        case .legRr: return ["leg-rr"]
        case .earL: return ["ear-left"]
        case .earR: return ["ear-right"]
        }
    }

    static func forElement(_ id: String) -> PatternPart? {
        allCases.first { $0.elementIDs.contains(id) }
    }
}

struct PartSilhouette: @unchecked Sendable {
    let cellsX: Int
    let cellsY: Int
    let tx: CGFloat
    let ty: CGFloat
    let path: CGPath
}

/// Per-part paintable silhouette (outline path, editor-grid transform, and grid dimensions)
/// that gates which editor cells can hold a pattern spot.
enum PartSilhouettes {
    private static let sampleOffsets: [(CGFloat, CGFloat)] = [
        (0.5, 0.5), (0.12, 0.12), (0.88, 0.12), (0.12, 0.88), (0.88, 0.88),
        (0.5, 0.12), (0.88, 0.5), (0.5, 0.88), (0.12, 0.5),
    ]

    static let table: [PatternPart: PartSilhouette] = [
        .head: make(
            22, 18, 0, -1,
            "M4 3H2V5H1V7H0V12H1V16H3V17H4V18H6V19H16V18H18V17H19V16H20V15H21V12H22V8H21V5H20V4H19V3H17V2H15V1H7V2H4V3Z"
        ),
        .body: make(22, 15, 0, 0, "M15 0V1H18V2H20V3H21V6H22V11H21V14H19V15H3V14H1V11H0V6H1V3H2V2H4V1H7V0H15Z"),
        .tail: make(13, 10, 0, 0, "M0 8V7H6V6H8V5H9V4H8V1H9V0H11V1H12V2H13V7H12V8H11V9H9V10H4V9H1V8H0Z"),
        .legFl: make(8, 11, -6, -25, "M6 29V26H7V25H10V26H11V28H12V31H13V32H14V35H13V36H9V35H8V31H7V29H6Z"),
        .legFr: make(8, 11, -15, -25, "M23 29V26H22V25H19V26H18V28H17V31H16V32H15V35H16V36H20V35H21V31H22V29H23Z"),
        .legRl: make(8, 8, -10, -134, "M10 138V134H18V138H17V140H16V142H12V140H11V138H10Z"),
        .legRr: make(8, 8, -22, -134, "M22 138V134H30V138H29V140H28V142H24V140H23V138H22Z"),
        .earL: make(6, 8, 0, 0, "M0 7V4H1V2H2V1H3V0H4V2H5V3H6V7H5V8H1V7H0Z"),
        .earR: make(5, 8, 0, 0, "M1 3H0V7H1V8H4V7H5V2H4V1H3V0H2V1H1V3Z"),
    ]

    static func dimensions(_ part: PatternPart) -> (Int, Int) {
        guard let s = table[part] else { return (8, 8) }
        return (s.cellsX, s.cellsY)
    }

    /// Point-in-fill test sampling the 9 offsets per cell: a cell is paintable when either its
    /// rendered point or its pre-transform (local) point falls inside the silhouette path.
    static func contains(_ part: PatternPart, x: Int, y: Int) -> Bool {
        guard let s = table[part] else { return true }
        let fx = CGFloat(x)
        let fy = CGFloat(y)
        for (ox, oy) in sampleOffsets {
            let px = fx + ox
            let py = fy + oy
            if s.path.contains(CGPoint(x: px, y: py), using: .winding) { return true }
            if s.path.contains(CGPoint(x: px - s.tx, y: py - s.ty), using: .winding) { return true }
        }
        return false
    }

    private static func make(_ cx: Int, _ cy: Int, _ tx: CGFloat, _ ty: CGFloat, _ d: String) -> PartSilhouette {
        PartSilhouette(cellsX: cx, cellsY: cy, tx: tx, ty: ty, path: parsePath(d))
    }

    /// Minimal SVG path parser covering the M/L/H/V/Z subset used by the silhouettes.
    private static func parsePath(_ d: String) -> CGPath {
        let path = CGMutablePath()
        let chars = Array(d)
        var i = 0
        var cmd: Character = " "
        var current = CGPoint.zero
        func skipSep() { while i < chars.count, chars[i] == " " || chars[i] == "," { i += 1 } }
        func readNum() -> CGFloat {
            skipSep()
            var s = ""
            if i < chars.count, chars[i] == "-" {
                s.append(chars[i])
                i += 1
            }
            while i < chars.count, chars[i].isNumber || chars[i] == "." {
                s.append(chars[i])
                i += 1
            }
            return CGFloat(Double(s) ?? 0)
        }
        while i < chars.count {
            let c = chars[i]
            if c.isLetter {
                cmd = c
                i += 1
            }
            switch cmd {
            case "M":
                current = CGPoint(x: readNum(), y: readNum())
                path.move(to: current)
                cmd = "L"
            case "L":
                current = CGPoint(x: readNum(), y: readNum())
                path.addLine(to: current)
            case "H":
                current = CGPoint(x: readNum(), y: current.y)
                path.addLine(to: current)
            case "V":
                current = CGPoint(x: current.x, y: readNum())
                path.addLine(to: current)
            case "Z", "z":
                path.closeSubpath()
                if !c.isLetter { i += 1 }
            default:
                i += 1
            }
            skipSep()
        }
        return path
    }
}

struct PatternModel: Codable, Equatable, Sendable {
    var selectedPresetId: String?
    var baseColor: String
    var eyeColor: String
    var eyeBgColor: String
    var outlineColor: String
    var oddEye: Bool
    var eyeColorLeft: String
    var eyeColorRight: String
    var head: [Spot]
    var body: [Spot]
    var tail: [Spot]
    var legFl: [Spot]
    var legFr: [Spot]
    var legRl: [Spot]
    var legRr: [Spot]
    var earL: [Spot]
    var earR: [Spot]

    enum CodingKeys: String, CodingKey {
        case selectedPresetId, baseColor, eyeColor, eyeBgColor, outlineColor, oddEye, eyeColorLeft, eyeColorRight
        case head, body, tail, legFl, legFr, legRl, legRr, earL, earR
    }

    init(
        selectedPresetId: String? = nil,
        baseColor: String = defaultBaseColor,
        eyeColor: String = defaultEyeColor,
        eyeBgColor: String = defaultEyeBgColor,
        outlineColor: String = defaultOutlineColor,
        oddEye: Bool = false,
        eyeColorLeft: String = defaultEyeColor,
        eyeColorRight: String = defaultEyeColor,
        head: [Spot] = [], body: [Spot] = [], tail: [Spot] = [], legFl: [Spot] = [], legFr: [Spot] = [],
        legRl: [Spot] = [], legRr: [Spot] = [], earL: [Spot] = [], earR: [Spot] = []
    ) {
        self.selectedPresetId = selectedPresetId
        self.baseColor = baseColor
        self.eyeColor = eyeColor
        self.eyeBgColor = eyeBgColor
        self.outlineColor = outlineColor
        self.oddEye = oddEye
        self.eyeColorLeft = eyeColorLeft
        self.eyeColorRight = eyeColorRight
        self.head = head
        self.body = body
        self.tail = tail
        self.legFl = legFl
        self.legFr = legFr
        self.legRl = legRl
        self.legRr = legRr
        self.earL = earL
        self.earR = earR
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedPresetId = try c.decodeIfPresent(String.self, forKey: .selectedPresetId)
        baseColor = try c.decodeIfPresent(String.self, forKey: .baseColor) ?? defaultBaseColor
        eyeColor = try c.decodeIfPresent(String.self, forKey: .eyeColor) ?? defaultEyeColor
        eyeBgColor = try c.decodeIfPresent(String.self, forKey: .eyeBgColor) ?? defaultEyeBgColor
        outlineColor = try c.decodeIfPresent(String.self, forKey: .outlineColor) ?? defaultOutlineColor
        oddEye = try c.decodeIfPresent(Bool.self, forKey: .oddEye) ?? false
        eyeColorLeft = try c.decodeIfPresent(String.self, forKey: .eyeColorLeft) ?? eyeColor
        eyeColorRight = try c.decodeIfPresent(String.self, forKey: .eyeColorRight) ?? eyeColor
        head = try c.decodeIfPresent([Spot].self, forKey: .head) ?? []
        body = try c.decodeIfPresent([Spot].self, forKey: .body) ?? []
        tail = try c.decodeIfPresent([Spot].self, forKey: .tail) ?? []
        legFl = try c.decodeIfPresent([Spot].self, forKey: .legFl) ?? []
        legFr = try c.decodeIfPresent([Spot].self, forKey: .legFr) ?? []
        legRl = try c.decodeIfPresent([Spot].self, forKey: .legRl) ?? []
        legRr = try c.decodeIfPresent([Spot].self, forKey: .legRr) ?? []
        earL = try c.decodeIfPresent([Spot].self, forKey: .earL) ?? []
        earR = try c.decodeIfPresent([Spot].self, forKey: .earR) ?? []
        self = sanitized()
    }

    static var `default`: PatternModel { PatternModel() }

    func spots(for part: PatternPart) -> [Spot] {
        switch part {
        case .head: return head
        case .body: return body
        case .tail: return tail
        case .legFl: return legFl
        case .legFr: return legFr
        case .legRl: return legRl
        case .legRr: return legRr
        case .earL: return earL
        case .earR: return earR
        }
    }

    var resolvedEyeColor: String { Self.hexOrDefault(eyeColor, "#1A1A1A") }
    var resolvedEyeBgColor: String { Self.hexOrDefault(eyeBgColor, "#FFFFFF") }
    var resolvedOutlineColor: String { Self.hexOrDefault(outlineColor, defaultOutlineColor) }
    var resolvedEyeColorLeft: String { oddEye ? Self.hexOrDefault(eyeColorLeft, resolvedEyeColor) : resolvedEyeColor }
    var resolvedEyeColorRight: String { oddEye ? Self.hexOrDefault(eyeColorRight, resolvedEyeColor) : resolvedEyeColor }

    mutating func setSpots(_ spots: [Spot], for part: PatternPart) {
        switch part {
        case .head: head = spots
        case .body: body = spots
        case .tail: tail = spots
        case .legFl: legFl = spots
        case .legFr: legFr = spots
        case .legRl: legRl = spots
        case .legRr: legRr = spots
        case .earL: earL = spots
        case .earR: earR = spots
        }
    }

    func sanitized() -> PatternModel {
        var p = self
        p.selectedPresetId = selectedPresetId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        p.baseColor = Self.hexOrDefault(baseColor, defaultBaseColor)
        p.eyeColor = Self.hexOrDefault(eyeColor, defaultEyeColor)
        p.eyeBgColor = Self.hexOrDefault(eyeBgColor, defaultEyeBgColor)
        p.outlineColor = Self.hexOrDefault(outlineColor, defaultOutlineColor)
        p.eyeColorLeft = Self.hexOrDefault(eyeColorLeft, p.eyeColor)
        p.eyeColorRight = Self.hexOrDefault(eyeColorRight, p.eyeColor)
        for part in PatternPart.allCases {
            // Spot normalization only (clamp >= 0, hex, sort). Silhouette membership gates PAINTING
            // in the editor (PartSilhouettes / isPaintable); out-of-silhouette spots are kept on
            // persist so a stored pattern never silently loses cells.
            let normalized = spots(for: part).map {
                Spot(x: max(0, $0.x), y: max(0, $0.y), color: Self.hexOrDefault($0.color, p.baseColor))
            }
            .sorted { ($0.y, $0.x, $0.color) < ($1.y, $1.x, $1.color) }
            p.setSpots(normalized, for: part)
        }
        return p
    }

    func signature() -> String {
        var sanitized = sanitized()
        sanitized.selectedPresetId = nil
        let data = (try? JSONEncoder.stable.encode(sanitized)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func hexOrDefault(_ raw: String, _ fallback: String) -> String {
        let sanitized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard parseHexRGB(sanitized) != nil else { return fallback }
        return sanitized.uppercased()
    }
}

private func parseHexRGB(_ raw: String) -> UInt32? {
    guard raw.utf8.count == 7 else { return nil }
    var value: UInt32 = 0
    for (index, byte) in raw.utf8.enumerated() {
        if index == 0 {
            guard byte == UInt8(ascii: "#") else { return nil }
            continue
        }
        guard let digit = hexDigit(byte) else { return nil }
        value = (value << 4) | UInt32(digit)
    }
    return value
}

private func hexDigit(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    default: return nil
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension JSONEncoder {
    static var stable: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let value =
            parseHexRGB(hex)
            ?? parseHexRGB(hex.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? 0
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
            Int(round(c.blueComponent * 255)))
    }
}
