import Foundation
@preconcurrency import Network

enum AgentOutput: Equatable, Sendable {
    case active(AgentStateEvent)
    case complete(AgentStateEvent)
    case notification(AgentStateEvent)
    case cleared(AgentStateEvent)
    case ignored
}

/// The model vendor whose brand mark represents a running session in the thinking bubble.
/// Classified by the running model when the hook reports one (model-agnostic agents like
/// omp/cursor can run either vendor); otherwise by the agent's first-party vendor. Sessions
/// that match neither (Gemini, unknown local models, kiro logs) stay unclassified.
enum AgentProvider: Equatable, Sendable {
    case openai
    case anthropic

    init?(agentId: String, model: String?) {
        if let model, let provider = AgentProvider(model: model) {
            self = provider
            return
        }
        switch agentId {
        case "codex": self = .openai
        case "claude-code": self = .anthropic
        default: return nil
        }
    }

    /// Best-effort vendor from a model identifier (e.g. `anthropic/claude-sonnet-4-5`,
    /// `openai-codex/gpt-5.3-codex`). omp forwards `provider/id`, so the vendor token is present.
    init?(model: String) {
        let id = model.lowercased()
        if id.contains("anthropic") || id.contains("claude") || id.contains("sonnet")
            || id.contains("opus") || id.contains("haiku")
        {
            self = .anthropic
            return
        }
        if id.contains("openai") || id.contains("gpt") || id.contains("codex") {
            self = .openai
            return
        }
        return nil
    }
}

/// Active-session tallies split by model vendor, rendered as `<openai> <anthropic>` counts.
struct AgentProviderCounts: Equatable, Sendable {
    var openai = 0
    var anthropic = 0
}

struct AgentStateMachine: Sendable {
    static let activeTTL: TimeInterval = 10 * 60
    static let notificationDedup: TimeInterval = 5
    static let validAgentIds: Set<String> = ["claude-code", "antigravity", "cursor", "codex", "kiro", "omp"]
    private struct ActiveSession {
        var deadline: TimeInterval
        var provider: AgentProvider?
    }
    private var active: [String: ActiveSession] = [:]
    private var lastNotification: [String: TimeInterval] = [:]

    var hasActiveSessions: Bool { !active.isEmpty }
    var activeCount: Int { active.count }

    /// Active sessions grouped by the model vendor recorded when each session went active.
    func activeCounts() -> AgentProviderCounts {
        var counts = AgentProviderCounts()
        for session in active.values {
            switch session.provider {
            case .openai: counts.openai += 1
            case .anthropic: counts.anthropic += 1
            case nil: continue
            }
        }
        return counts
    }

    mutating func handle(_ event: AgentStateEvent, now: TimeInterval = Date().timeIntervalSince1970) -> AgentOutput {
        prune(now: now)
        guard Self.validAgentIds.contains(event.agentId), !event.sessionId.isEmpty else { return .ignored }
        let key = sessionKey(event)
        switch event.state {
        case .thinking, .working:
            // A later event for the same session may omit the model; keep the known vendor.
            let provider = AgentProvider(agentId: event.agentId, model: event.model) ?? active[key]?.provider
            active[key] = ActiveSession(deadline: now + Self.activeTTL, provider: provider)
            return .active(event)
        case .complete:
            // Fire the completion when the session was live. omp's main-only `session_stop` stays
            // authoritative even when its active key was already removed: clawdi delivers each omp
            // hook event from an independent process over its own socket, so the session's trailing
            // `agent_end` (.idle) can overtake this event. Other agents keep the strict gate — a
            // complete with no live session is stray noise that should stay ignored.
            let wasActive = active.removeValue(forKey: key) != nil
            guard wasActive || (event.agentId == "omp" && event.event == "session_stop") else { return .ignored }
            return .complete(event)
        case .notification:
            let nkey = notificationKey(event)
            if let last = lastNotification[nkey], now - last < Self.notificationDedup { return .ignored }
            lastNotification[nkey] = now
            return .notification(event)
        case .idle, .error:
            active.removeValue(forKey: key)
            return .cleared(event)
        }
    }

    mutating func prune(now: TimeInterval) {
        active = active.filter { $0.value.deadline > now }
        lastNotification = lastNotification.filter { now - $0.value < Self.notificationDedup }
    }

    private func sessionKey(_ event: AgentStateEvent) -> String { "\(event.agentId):\(event.sessionId)" }
    private func notificationKey(_ event: AgentStateEvent) -> String {
        "\(event.agentId):\(event.event):\(event.sessionId):\(event.cwd ?? "")"
    }
}

@MainActor
final class AgentStateServer {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var socketPath: String?
    private var machine = AgentStateMachine()
    private let decoder = JSONDecoder()
    private var watchdog: Timer?
    /// Hook origins currently allowed to affect socket-delivered activity.
    var enabledExtensions = AgentEventSource.extensions
    /// Another Clawdi process's `prepareSocket` (or a /tmp cleaner) can unlink the bound
    /// socket path out from under this still-running listener: the fd stays open but new hook
    /// clients hit ENOENT and every agent event is dropped silently. Re-check the node on a
    /// timer and rebind when it has vanished.
    private static let socketWatchdogInterval: TimeInterval = 3
    var onOutput: (@MainActor (AgentOutput) -> Void)?
    /// Fired from the watchdog sweep when stale sessions age out without any event arriving.
    var onSessionsExpired: (@MainActor () -> Void)?
    var hasActiveSessions: Bool { machine.hasActiveSessions }
    var activeProviderCounts: AgentProviderCounts { machine.activeCounts() }

    func start(socketPath: String = AgentStateTransport.socketPath) throws {
        stop()
        try prepareSocket(at: socketPath)

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global(qos: .utility))
                Task { @MainActor in
                    guard let self else {
                        conn.cancel()
                        return
                    }
                    self.connections[ObjectIdentifier(conn)] = conn
                    self.receive(on: conn)
                }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
            self.socketPath = socketPath
            scheduleWatchdog()
        } catch {
            cleanupSocket(at: socketPath)
            throw error
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        if let socketPath {
            cleanupSocket(at: socketPath)
            self.socketPath = nil
        }
    }

    /// Rebind if the listener believes it is up but its socket node is gone from disk.
    /// Safe to call repeatedly; a no-op while the node is present.
    func ensureListening() {
        guard let socketPath, listener != nil,
            !FileManager.default.fileExists(atPath: socketPath)
        else { return }
        try? start(socketPath: socketPath)
    }

    private func scheduleWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.socketWatchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.ensureListening()
                self?.sweepExpiredSessions()
            }
        }
    }

    /// An agent killed without a terminal hook (closed terminal, crash, machine sleep) never sends
    /// the complete/idle event that would clear its session, and the TTL was only checked when the
    /// next event arrived — none ever does from a dead agent, so the stale session kept
    /// `hasActiveSessions` (and the cat's thinking knead) on indefinitely. Sweep on the watchdog
    /// cadence and tell the controller when sessions age out so it can drop the stale state.
    func sweepExpiredSessions(now: TimeInterval = Date().timeIntervalSince1970) {
        let before = machine.activeCount
        machine.prune(now: now)
        if machine.activeCount != before { onSessionsExpired?() }
    }

    @discardableResult
    func handle(_ event: AgentStateEvent) -> AgentOutput {
        let out = machine.handle(event)
        onOutput?(out)
        return out
    }

    @discardableResult
    func handle(message data: Data) -> AgentOutput {
        guard data.count <= AgentStateTransport.maxMessageBytes,
            let event = try? decoder.decode(AgentStateEvent.self, from: data),
            event.source != .legacy,
            !event.source.isExtension || enabledExtensions.contains(event.source)
        else { return .ignored }
        return handle(event)
    }

    private func receive(on conn: NWConnection, buffer: Data = Data()) {
        conn.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1024
        ) { [weak self, weak conn] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let conn else { return }

                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.count > AgentStateTransport.maxMessageBytes {
                    self.close(conn)
                    return
                }

                if isComplete {
                    if !buffer.isEmpty { self.handle(message: buffer) }
                    self.close(conn)
                } else if error == nil {
                    self.receive(on: conn, buffer: buffer)
                } else {
                    self.close(conn)
                }
            }
        }
    }

    private func close(_ conn: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(conn))
        conn.cancel()
    }

    private func prepareSocket(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        cleanupSocket(at: path)
    }

    private func cleanupSocket(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
