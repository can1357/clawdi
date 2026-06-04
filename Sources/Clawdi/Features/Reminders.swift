import Foundation

enum ReminderRepeat: String, Codable, CaseIterable, Sendable {
    case none, daily, weekdays, weekends, custom
}

struct Reminder: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var time: String
    var message: String
    var repeatRule: ReminderRepeat
    var days: [Int]
    var enabled: Bool
    var lastTriggeredDate: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, time, message, days, enabled, lastTriggeredDate, createdAt
        case repeatRule = "repeat"
    }

    init(
        id: String = UUID().uuidString,
        time: String,
        message: String,
        repeatRule: ReminderRepeat = .none,
        days: [Int] = [],
        enabled: Bool = true,
        lastTriggeredDate: String? = nil,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id.isEmpty ? UUID().uuidString : id
        self.time = time
        self.message = message
        self.repeatRule = repeatRule
        self.days = days
        self.enabled = enabled
        self.lastTriggeredDate = lastTriggeredDate
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        let rawRepeat = try c.decodeIfPresent(String.self, forKey: .repeatRule) ?? ReminderRepeat.none.rawValue
        repeatRule = ReminderRepeat(rawValue: rawRepeat) ?? .none
        days = try c.decodeIfPresent([Int].self, forKey: .days) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        lastTriggeredDate = try c.decodeIfPresent(String.self, forKey: .lastTriggeredDate).flatMap {
            $0.isEmpty ? nil : $0
        }
        createdAt =
            try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ISO8601DateFormatter().string(from: Date())
    }

    func sanitized() -> Reminder? {
        guard let hm = ReminderTime.parse(time) else { return nil }
        let text = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !text.isEmpty else { return nil }
        var r = self
        r.time = String(format: "%02d:%02d", hm.hour, hm.minute)
        r.message = text
        r.days = Array(Set(days.filter { (0...6).contains($0) })).sorted()
        if repeatRule == .custom, r.days.isEmpty { r.repeatRule = .none }
        return r
    }

    func appliesToday(calendar: Calendar = .current, date: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: date) - 1
        switch repeatRule {
        case .none, .daily: return true
        case .weekdays: return (1...5).contains(weekday)
        case .weekends: return weekday == 0 || weekday == 6
        case .custom: return days.contains(weekday)
        }
    }

    func shouldTrigger(now: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, let hm = ReminderTime.parse(time), appliesToday(calendar: calendar, date: now) else {
            return false
        }
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        guard comps.hour == hm.hour, comps.minute == hm.minute else { return false }
        return lastTriggeredDate != Reminder.dateKey(now, calendar: calendar)
    }

    mutating func markTriggered(now: Date, calendar: Calendar = .current) {
        lastTriggeredDate = Reminder.dateKey(now, calendar: calendar)
        if repeatRule == .none { enabled = false }
    }

    static func dateKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    func speech(userName: String, date: Date = Date()) -> String {
        let name =
            userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Human" : userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name), \(ReminderTime.format12Hour(time)) \"\(message)\""
    }
}

struct ReminderTime: Equatable, Sendable {
    var hour: Int
    var minute: Int

    static func parse(_ raw: String) -> ReminderTime? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m)
        else { return nil }
        return ReminderTime(hour: h, minute: m)
    }

    static func format12Hour(_ raw: String) -> String {
        guard let t = parse(raw) else { return raw }
        let suffix = t.hour < 12 ? "AM" : "PM"
        let h = t.hour % 12 == 0 ? 12 : t.hour % 12
        return String(format: "%d:%02d %@", h, t.minute, suffix)
    }
}

final class ReminderScheduler {
    var reminders: [Reminder]
    init(reminders: [Reminder]) { self.reminders = reminders }

    func due(now: Date, calendar: Calendar = .current) -> [Reminder] {
        reminders.filter { $0.shouldTrigger(now: now, calendar: calendar) }
    }

    func markTriggered(ids: Set<String>, now: Date, calendar: Calendar = .current) {
        for i in reminders.indices where ids.contains(reminders[i].id) {
            reminders[i].markTriggered(now: now, calendar: calendar)
        }
    }
}
