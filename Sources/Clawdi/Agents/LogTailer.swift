import Foundation

struct LogTailState: Sendable {
    var offset: UInt64
    var partial: String
    var lastSeen: Date

    init(offset: UInt64 = 0, partial: String = "", lastSeen: Date = Date()) {
        self.offset = offset
        self.partial = partial
        self.lastSeen = lastSeen
    }
}

struct LogCandidate: Sendable {
    var url: URL
    var startAtEndIfOld: Bool

    init(_ url: URL, startAtEndIfOld: Bool = true) {
        self.url = url
        self.startAtEndIfOld = startAtEndIfOld
    }
}

final class LogTailer {
    private var states: [URL: LogTailState] = [:]
    private let maxTrackedFiles: Int
    private let maxReadBytes: UInt64
    private let maxPartialCharacters: Int
    private let staleAfter: TimeInterval
    private let startedAt: Date

    init(
        maxTrackedFiles: Int = 80, maxReadBytes: UInt64 = 256 * 1024, maxPartialCharacters: Int = 64 * 1024,
        staleAfter: TimeInterval = 10 * 60
    ) {
        self.maxTrackedFiles = maxTrackedFiles
        self.maxReadBytes = maxReadBytes
        self.maxPartialCharacters = maxPartialCharacters
        self.staleAfter = staleAfter
        startedAt = Date()
    }

    func poll(files: [URL], parse: (String) -> AgentStateEvent?, emit: (AgentStateEvent) -> Void) {
        poll(candidates: files.map { LogCandidate($0) }, parse: { line, _ in parse(line) }, emit: emit)
    }

    func poll(candidates: [LogCandidate], parse: (String, URL) -> AgentStateEvent?, emit: (AgentStateEvent) -> Void) {
        let now = Date()
        let capped = Array(candidates.prefix(maxTrackedFiles))
        let live = Set(capped.map(\.url))
        states = states.filter { live.contains($0.key) && now.timeIntervalSince($0.value.lastSeen) <= staleAfter }

        for candidate in capped {
            poll(candidate: candidate, now: now, parse: parse, emit: emit)
        }

        if states.count > maxTrackedFiles {
            let keep = Set(states.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(maxTrackedFiles).map(\.key))
            states = states.filter { keep.contains($0.key) }
        }
    }

    private func poll(
        candidate: LogCandidate, now: Date, parse: (String, URL) -> AgentStateEvent?, emit: (AgentStateEvent) -> Void
    ) {
        let url = candidate.url
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = fileSize(from: attrs)
        else { return }

        let modified = (attrs[.modificationDate] as? Date) ?? now
        var state =
            states[url]
            ?? initialState(size: size, modified: modified, startAtEndIfOld: candidate.startAtEndIfOld, now: now)

        if size < state.offset {
            state.offset = 0
            state.partial = ""
        }
        guard size > state.offset else {
            state.lastSeen = now
            states[url] = state
            return
        }

        let unread = size - state.offset
        if unread > maxReadBytes {
            state.offset = size - maxReadBytes
            state.partial = ""
        }

        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: state.offset)
        } catch { return }
        guard let data = try? fh.readToEnd() else { return }

        state.offset += UInt64(data.count)
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            state.lastSeen = now
            states[url] = state
            return
        }

        let chunk = state.partial + text
        var lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        state.partial = chunk.hasSuffix("\n") ? "" : (lines.popLast() ?? "")
        if state.partial.count > maxPartialCharacters { state.partial = "" }

        for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let event = parse(line, url) { emit(event) }
        }

        state.lastSeen = now
        states[url] = state
    }

    private func fileSize(from attrs: [FileAttributeKey: Any]) -> UInt64? {
        if let value = attrs[.size] as? NSNumber { return value.uint64Value }
        if let value = attrs[.size] as? UInt64 { return value }
        if let value = attrs[.size] as? Int, value >= 0 { return UInt64(value) }
        return nil
    }
    private func initialState(size: UInt64, modified: Date, startAtEndIfOld: Bool, now: Date) -> LogTailState {
        let oldAtStart = modified < startedAt.addingTimeInterval(-1.5)
        let offset = startAtEndIfOld && oldAtStart ? size : 0
        return LogTailState(offset: offset, lastSeen: now)
    }
}

/// Discovers and tails third-party agent log files (Codex, Kiro, Cursor) and forwards parsed
/// events to `emit` on the main actor.
///
/// All filesystem work runs on `Engine`, an actor scheduled off the main thread. Discovery
/// (recursive directory walks — Cursor's log tree alone is hundreds of entries) previously ran
/// on the main actor every poll and cost more CPU than rendering the pet; it is now cached for
/// `Engine.discoveryInterval` so each poll normally only re-reads the tails of known files.
@MainActor
final class AgentLogMonitors {
    private static let pollInterval: TimeInterval = 1.5

    private let engine = Engine()
    private var pollTask: Task<Void, Never>?
    var emit: ((AgentStateEvent) -> Void)?

    func start() {
        stop()
        let engine = engine
        pollTask = Task(priority: .utility) { [weak self] in
            await engine.reset()
            while !Task.isCancelled {
                let events = await engine.poll()
                guard !Task.isCancelled else { return }
                if let emit = self?.emit {
                    for event in events { emit(event) }
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Owns the tail offsets and the discovery cache; every filesystem touch happens here.
    private actor Engine {
        /// Directory walks re-run at most this often; between scans polls reuse the cached
        /// candidate list, so a brand-new log file is picked up within one discovery interval.
        private static let discoveryInterval: TimeInterval = 20
        private static let recentLogAge: TimeInterval = 10 * 60
        private static let maxCandidates = 80

        private var tailers: [String: LogTailer] = [:]
        private var discovered: [String: (at: TimeInterval, candidates: [LogCandidate])] = [:]

        func reset() {
            tailers.removeAll()
            discovered.removeAll()
        }

        func poll() -> [AgentStateEvent] {
            var events: [AgentStateEvent] = []
            let home = FileManager.default.homeDirectoryForCurrentUser
            tailer("codex").poll(
                candidates: candidates("codex") { codexFiles(home: home) },
                parse: { CodexLogParser.parse(line: $0, url: $1) }
            ) { events.append($0) }
            tailer("kiro").poll(
                candidates: candidates("kiro") {
                    recursiveLogs(
                        home.appendingPathComponent("Library/Application Support/Kiro/logs"), suffix: ".log")
                },
                parse: { KiroLogParser.parse(line: $0, url: $1) }
            ) { events.append($0) }
            tailer("cursor").poll(
                candidates: candidates("cursor") {
                    recursiveLogs(
                        home.appendingPathComponent("Library/Application Support/Cursor/logs"),
                        names: ["Kiro Logs.log", "q-client.log"])
                },
                parse: { CursorLogParser.parse(line: $0, url: $1) }
            ) { events.append($0) }
            return events
        }

        private func candidates(_ key: String, scan: () -> [LogCandidate]) -> [LogCandidate] {
            let now = Date().timeIntervalSinceReferenceDate
            if let cached = discovered[key], now - cached.at < Self.discoveryInterval {
                return cached.candidates
            }
            let scanned = scan()
            discovered[key] = (now, scanned)
            return scanned
        }

        private func tailer(_ key: String) -> LogTailer {
            if let tailer = tailers[key] { return tailer }
            let tailer = LogTailer(maxTrackedFiles: Self.maxCandidates)
            tailers[key] = tailer
            return tailer
        }

        private func codexFiles(home: URL) -> [LogCandidate] {
            let base = home.appendingPathComponent(".codex/sessions")
            let calendar = Calendar(identifier: .gregorian)
            let today = Date()
            var candidates: [LogCandidate] = []

            for daysAgo in 0...2 {
                guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = components.year, let month = components.month, let day = components.day else {
                    continue
                }
                let dir =
                    base
                    .appendingPathComponent(String(format: "%04d", year))
                    .appendingPathComponent(String(format: "%02d", month))
                    .appendingPathComponent(String(format: "%02d", day))
                candidates.append(
                    contentsOf: directLogs(dir, prefix: "rollout-", suffix: ".jsonl", startAtEndIfOld: true))
            }

            return newest(candidates, limit: 50)
        }

        private func directLogs(_ base: URL, prefix: String, suffix: String, startAtEndIfOld: Bool) -> [LogCandidate] {
            guard
                let urls = try? FileManager.default.contentsOfDirectory(
                    at: base, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles])
            else { return [] }
            return urls.compactMap { url in
                let name = url.lastPathComponent
                guard name.hasPrefix(prefix), name.hasSuffix(suffix), isRegularFile(url) else { return nil }
                return LogCandidate(url, startAtEndIfOld: startAtEndIfOld)
            }
        }

        private func recursiveLogs(_ base: URL, suffix: String? = nil, names: Set<String>? = nil) -> [LogCandidate] {
            var found: [LogCandidate] = []
            visitLogs(base, depth: 0, suffix: suffix, names: names, found: &found)
            return newest(found, limit: Self.maxCandidates)
        }

        private func visitLogs(
            _ dir: URL, depth: Int, suffix: String?, names: Set<String>?, found: inout [LogCandidate]
        ) {
            guard depth <= 5, found.count < Self.maxCandidates,
                let urls = try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles])
            else { return }

            for url in urls {
                if found.count >= Self.maxCandidates { return }
                if isDirectory(url) {
                    visitLogs(url, depth: depth + 1, suffix: suffix, names: names, found: &found)
                    continue
                }
                let name = url.lastPathComponent
                if let names, !names.contains(name) { continue }
                if let suffix, !name.hasSuffix(suffix) { continue }
                guard isRegularFile(url), isRecent(url, age: Self.recentLogAge) else { continue }
                found.append(LogCandidate(url))
            }
        }

        private func newest(_ candidates: [LogCandidate], limit: Int) -> [LogCandidate] {
            candidates.sorted { modificationDate($0.url) > modificationDate($1.url) }.prefix(limit).map { $0 }
        }

        private func isDirectory(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        private func isRegularFile(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }

        private func isRecent(_ url: URL, age: TimeInterval) -> Bool {
            Date().timeIntervalSince(modificationDate(url)) <= age
        }

        private func modificationDate(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
    }
}
