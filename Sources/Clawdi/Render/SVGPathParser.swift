import CoreGraphics
import Foundation

enum SVGPathError: Error, Equatable {
    case unsupportedCommand(Character)
    case malformed
}

struct SVGPathParser {
    private let tokens: [Token]
    private var index = 0

    private enum Token: Equatable {
        case command(Character)
        case number(CGFloat)
    }

    init(_ d: String) { tokens = Self.tokenize(d) }

    static func path(_ d: String) throws -> CGPath {
        var parser = SVGPathParser(d)
        return try parser.parse()
    }

    private mutating func parse() throws -> CGPath {
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character?
        while index < tokens.count {
            if case .command(let c) = tokens[index] {
                command = c
                index += 1
            }
            guard let raw = command else { throw SVGPathError.malformed }
            let relative = raw.isLowercase
            let c = Character(raw.uppercased())
            switch c {
            case "M":
                let x = try nextNumber()
                let y = try nextNumber()
                current = point(x, y, relative: relative, current: current)
                path.move(to: current)
                start = current
                command = relative ? "l" : "L"
            case "L":
                while hasNumber {
                    let x = try nextNumber()
                    let y = try nextNumber()
                    current = point(x, y, relative: relative, current: current)
                    path.addLine(to: current)
                }
            case "H":
                while hasNumber {
                    let x = try nextNumber()
                    current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                    path.addLine(to: current)
                }
            case "V":
                while hasNumber {
                    let y = try nextNumber()
                    current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                    path.addLine(to: current)
                }
            case "Z":
                path.closeSubpath()
                current = start
            default:
                throw SVGPathError.unsupportedCommand(raw)
            }
        }
        return path
    }

    private var hasNumber: Bool {
        guard index < tokens.count else { return false }
        if case .number = tokens[index] { return true }
        return false
    }

    private mutating func nextNumber() throws -> CGFloat {
        guard index < tokens.count, case .number(let n) = tokens[index] else { throw SVGPathError.malformed }
        index += 1
        return n
    }

    private func point(_ x: CGFloat, _ y: CGFloat, relative: Bool, current: CGPoint) -> CGPoint {
        relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
    }

    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        var i = d.startIndex
        while i < d.endIndex {
            let ch = d[i]
            if ch.isWhitespace || ch == "," {
                i = d.index(after: i)
                continue
            }
            if ch.isLetter {
                tokens.append(.command(ch))
                i = d.index(after: i)
                continue
            }
            var j = i
            if d[j] == "-" || d[j] == "+" { j = d.index(after: j) }
            while j < d.endIndex, d[j].isNumber { j = d.index(after: j) }
            if j < d.endIndex, d[j] == "." {
                j = d.index(after: j)
                while j < d.endIndex, d[j].isNumber { j = d.index(after: j) }
            }
            if j < d.endIndex, d[j] == "e" || j < d.endIndex && d[j] == "E" {
                j = d.index(after: j)
                if j < d.endIndex, d[j] == "-" || d[j] == "+" { j = d.index(after: j) }
                while j < d.endIndex, d[j].isNumber { j = d.index(after: j) }
            }
            if let value = Double(d[i..<j]) { tokens.append(.number(CGFloat(value))) }
            i = j
        }
        return tokens
    }
}

extension Character {
    fileprivate var isLowercase: Bool {
        String(self).lowercased() == String(self) && String(self).uppercased() != String(self)
    }
}

struct SVGTransformParser {
    private static let operation = try! NSRegularExpression(pattern: #"(translate|scale|rotate)\(([^)]*)\)"#)

    static func parse(_ raw: String?) -> CGAffineTransform {
        guard let raw, !raw.isEmpty else { return .identity }
        var transform = CGAffineTransform.identity
        let ns = raw as NSString
        for m in operation.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let op = ns.substring(with: m.range(at: 1))
            let nums = ns.substring(with: m.range(at: 2)).split { $0 == " " || $0 == "," }.compactMap { Double($0) }.map
            { CGFloat($0) }
            switch op {
            case "translate": transform = transform.translatedBy(x: nums.first ?? 0, y: nums.dropFirst().first ?? 0)
            case "scale":
                transform = transform.scaledBy(x: nums.first ?? 1, y: nums.dropFirst().first ?? nums.first ?? 1)
            case "rotate":
                let angle = (nums.first ?? 0) * .pi / 180
                if nums.count >= 3 {
                    transform = transform.translatedBy(x: nums[1], y: nums[2]).rotated(by: angle).translatedBy(
                        x: -nums[1], y: -nums[2])
                } else {
                    transform = transform.rotated(by: angle)
                }
            default: break
            }
        }
        return transform
    }

    static func about(_ point: CGPoint, _ body: (CGAffineTransform) -> CGAffineTransform) -> CGAffineTransform {
        body(.identity.translatedBy(x: point.x, y: point.y)).translatedBy(x: -point.x, y: -point.y)
    }
}
