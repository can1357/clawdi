import CoreGraphics
import Foundation

struct ClawdiSettings: Codable, Equatable, Sendable {
    var stretchIntervalMin: Int
    var reminders: [Reminder]
    var catName: String
    var userName: String
    var showCatName: Bool
    var fixedMessage: String
    var catNamePromptShown: Bool
    var taskCompleteSoundVolume: Double
    var petSize: Int
    var petPosition: StoredPoint?
    var pomodoroFocusMin: Int
    var pomodoroRestSec: Int
    var skin: PetSkin
    var launchAtLogin: Bool
    var enabledExtensions: Set<AgentEventSource>

    enum CodingKeys: String, CodingKey {
        case stretchIntervalMin
        case reminders
        case catName
        case userName
        case showCatName
        case fixedMessage
        case catNamePromptShown
        case taskCompleteSoundVolume
        case petSize
        case petPosition
        case pomodoroFocusMin
        case pomodoroRestSec
        case skin
        case launchAtLogin
        case enabledExtensions
    }

    init(
        stretchIntervalMin: Int = 30,
        reminders: [Reminder] = [],
        catName: String = "Clawdi",
        userName: String = "",
        showCatName: Bool = true,
        fixedMessage: String = "",
        catNamePromptShown: Bool = false,
        taskCompleteSoundVolume: Double = 0.1,
        petSize: Int = 100,
        petPosition: StoredPoint? = nil,
        pomodoroFocusMin: Int = 25,
        pomodoroRestSec: Int = 300,
        skin: PetSkin = .flowerClaude,
        launchAtLogin: Bool = true,
        enabledExtensions: Set<AgentEventSource> = AgentEventSource.extensions
    ) {
        self.stretchIntervalMin = stretchIntervalMin
        self.reminders = reminders
        self.catName = catName
        self.userName = userName
        self.showCatName = showCatName
        self.fixedMessage = fixedMessage
        self.catNamePromptShown = catNamePromptShown
        self.taskCompleteSoundVolume = taskCompleteSoundVolume
        self.petSize = petSize
        self.petPosition = petPosition
        self.pomodoroFocusMin = pomodoroFocusMin
        self.pomodoroRestSec = pomodoroRestSec
        self.skin = skin
        self.launchAtLogin = launchAtLogin
        self.enabledExtensions = enabledExtensions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A missing or non-positive rest duration falls back to the 5-minute default.
        let restSec = Self.lenient(c, .pomodoroRestSec, default: 300)
        // Decode every field best-effort: a present-but-malformed value (a hand-edit or a
        // future enum case) falls back to that field's default instead of throwing. A throw
        // here would make `JSONFileStore.load` discard the *entire* settings file and revert
        // every field to `.default` — silently turning a disabled stretch back on
        // (`stretchIntervalMin` 0 -> 30) and losing the user's other settings.
        self.init(
            stretchIntervalMin: Self.lenient(c, .stretchIntervalMin, default: 30),
            reminders: Self.lenient(c, .reminders, default: [Reminder]()),
            catName: Self.lenient(c, .catName, default: "Clawdi"),
            userName: Self.lenient(c, .userName, default: ""),
            showCatName: Self.lenient(c, .showCatName, default: true),
            fixedMessage: Self.lenient(c, .fixedMessage, default: ""),
            catNamePromptShown: Self.lenient(c, .catNamePromptShown, default: false),
            taskCompleteSoundVolume: Self.lenient(c, .taskCompleteSoundVolume, default: 0.1),
            petSize: Self.lenient(c, .petSize, default: 100),
            petPosition: (try? c.decodeIfPresent(StoredPoint.self, forKey: .petPosition)) ?? nil,
            pomodoroFocusMin: Self.lenient(c, .pomodoroFocusMin, default: 25),
            pomodoroRestSec: restSec > 0 ? restSec : 300,
            skin: Self.lenient(c, .skin, default: PetSkin.flowerClaude),
            launchAtLogin: Self.lenient(c, .launchAtLogin, default: true),
            enabledExtensions: Self.lenient(c, .enabledExtensions, default: AgentEventSource.extensions)
        )
        self = sanitized()
    }

    /// Best-effort decode of a single key: a present-but-malformed value degrades to `fallback`
    /// instead of throwing, so one bad field can't make `JSONFileStore.load` discard the whole
    /// settings file (see `init(from:)`). An absent key already defaults via `decodeIfPresent`.
    private static func lenient<T: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, default fallback: T
    ) -> T {
        ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    static var `default`: ClawdiSettings { ClawdiSettings() }

    func sanitized() -> ClawdiSettings {
        var s = self
        s.stretchIntervalMin = max(0, stretchIntervalMin)
        s.reminders = reminders.compactMap { $0.sanitized() }
        s.catName = String(catName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        if s.catName.isEmpty { s.catName = "Clawdi" }
        s.userName = String(userName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        s.fixedMessage = String(fixedMessage.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        s.taskCompleteSoundVolume = taskCompleteSoundVolume.isFinite ? min(1, max(0, taskCompleteSoundVolume)) : 0.1
        s.petSize = min(400, max(20, Int(Double(petSize).rounded())))
        if let p = petPosition { s.petPosition = StoredPoint(x: p.x.rounded(), y: p.y.rounded()) }
        s.pomodoroFocusMin = min(180, max(1, pomodoroFocusMin))
        s.pomodoroRestSec = min(3600, max(30, pomodoroRestSec))
        s.enabledExtensions = enabledExtensions.intersection(AgentEventSource.extensions)
        return s
    }
}

struct StoredPoint: Codable, Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
}

struct WindowGeometry {
    static let defaultSize = 100
    static let petSizeOptions = [20, 30, 40, 60, 80, 100, 120, 140, 160, 200, 240]
    static let windowWidthRatio: CGFloat = 2
    static let minWindowWidth: CGFloat = 500
    static let stretchRatio: CGFloat = 4.8
    static let extraRight: CGFloat = 2
    /// Where the resting cat square sits within its resting region (42% of the slack above it).
    static let catTopFraction: CGFloat = 0.42

    /// Height the cat occupied before reserving dangle room — still drives the resting square's size
    /// and position so a taller window only adds transparent hang space *below* the cat.
    static func restingHeight(petSize: Int) -> CGFloat { (CGFloat(petSize) * stretchRatio).rounded() }

    static func windowWidth(petSize: Int, widthRatio: CGFloat = windowWidthRatio) -> CGFloat {
        max(minWindowWidth, CGFloat(petSize) * widthRatio + extraRight)
    }

    /// Side of the resting cat square (unchanged from the original `min(width, height)`).
    static func catSide(petSize: Int, widthRatio: CGFloat = windowWidthRatio) -> CGFloat {
        min(windowWidth(petSize: petSize, widthRatio: widthRatio), restingHeight(petSize: petSize))
    }

    static func windowSize(petSize: Int, widthRatio: CGFloat = windowWidthRatio) -> CGSize {
        let width = windowWidth(petSize: petSize, widthRatio: widthRatio)
        let resting = restingHeight(petSize: petSize)
        let side = min(width, resting)
        let catTop = (resting - side) * catTopFraction
        let height = max(resting, (catTop + CatLayout.liftRoomBelow(catSide: side)).rounded())
        return CGSize(width: width, height: height)
    }

    static func defaultPosition(displayFrame: CGRect, windowSize: CGSize) -> CGPoint {
        CGPoint(
            x: displayFrame.minX + displayFrame.width - windowSize.width - 80,
            y: displayFrame.minY + displayFrame.height - windowSize.height - 100)
    }

    static func isVisible(_ origin: CGPoint, size: CGSize, screens: [NSScreenLike]) -> Bool {
        let rect = CGRect(origin: origin, size: size)
        return screens.contains { screen in
            let b = screen.visibleFrameLike.insetBy(dx: 20, dy: 20)
            return b.intersects(rect) && rect.maxX > b.minX && rect.minX < b.maxX && rect.maxY > b.minY
                && rect.minY < b.maxY
        }
    }
}

protocol NSScreenLike { var visibleFrameLike: CGRect { get } }

#if canImport(AppKit)
    import AppKit
    extension NSScreen: NSScreenLike { var visibleFrameLike: CGRect { visibleFrame } }
#endif
