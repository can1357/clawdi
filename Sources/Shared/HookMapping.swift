import Foundation

/// Origin of an event delivered to Clawdi's local socket.
///
/// Values are encoded as `UInt8` so stale hook processes can be rejected after their extension is disabled.
enum AgentEventSource: UInt8, CaseIterable, Codable, Sendable {
    case direct = 0
    case claudeCode = 1
    case antigravity = 2
    case cursor = 3
    case omp = 4
    case legacy = 255

    static let extensions: Set<AgentEventSource> = [.claudeCode, .antigravity, .cursor, .omp]

    var isExtension: Bool { Self.extensions.contains(self) }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        case .omp: return "omp"
        case .direct, .legacy: return ""
        }
    }
}

/// Current agent activity associated with a socket event.
enum AgentActivityState: String, Codable, Sendable {
    case idle, thinking, working, complete, notification, error
}

/// Per-file line-change counts for one successful agent edit. Carried on `file_edit` events and
/// rendered by the pet as a flying `project>file +a -r` stat (see `EditPop`).
struct FileEditStat: Codable, Equatable, Sendable {
    var path: String
    var added: Int
    var removed: Int
}

/// Demo-only flight tuning for the edit-pop animation, riding a `file_edit` event: `flight` is
/// seconds airborne (launch to landing), `rise` the apex height as a fraction of the pet square
/// (0.5–0.75 when unset). Only `--clawdi-demo edit:flight=…,rise=…` sets it — real omp events
/// never do — so animation timing can be iterated without rebuilding.
struct EditPopTuning: Codable, Equatable, Sendable {
    var flight: Double?
    var rise: Double?
}

/// Decoded agent activity reported over the local Unix socket stream.
///
/// Hook events carry their [`AgentEventSource`] so disabled integrations can be ignored even if a stale process
/// sends after its hook configuration was removed.
struct AgentStateEvent: Codable, Equatable, Sendable {
    var agentId: String
    var sessionId: String
    var event: String
    var state: AgentActivityState
    var cwd: String?
    var title: String?
    var model: String?
    /// Per-file ±line counts riding a `file_edit` event; nil for every other event.
    var edits: [FileEditStat]?
    /// Demo-only edit-pop animation overrides riding a `file_edit` event.
    var editTuning: EditPopTuning?
    var source: AgentEventSource

    enum CodingKeys: String, CodingKey {
        case agentId, sessionId, event, state, cwd, title, model, edits, editTuning, source
    }

    init(
        agentId: String,
        sessionId: String,
        event: String,
        state: AgentActivityState,
        cwd: String?,
        title: String? = nil,
        model: String? = nil,
        edits: [FileEditStat]? = nil,
        editTuning: EditPopTuning? = nil,
        source: AgentEventSource = .direct
    ) {
        self.agentId = agentId
        self.sessionId = sessionId
        self.event = event
        self.state = state
        self.cwd = cwd
        self.title = title
        self.model = model
        self.edits = edits
        self.editTuning = editTuning
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try container.decode(String.self, forKey: .agentId)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        event = try container.decode(String.self, forKey: .event)
        state = try container.decode(AgentActivityState.self, forKey: .state)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        edits = try container.decodeIfPresent([FileEditStat].self, forKey: .edits)
        editTuning = try container.decodeIfPresent(EditPopTuning.self, forKey: .editTuning)
        source = try container.decodeIfPresent(AgentEventSource.self, forKey: .source) ?? .legacy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentId, forKey: .agentId)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(event, forKey: .event)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(edits, forKey: .edits)
        try container.encodeIfPresent(editTuning, forKey: .editTuning)
        try container.encode(source, forKey: .source)
    }
}

enum AgentStateTransport {
    static let socketDirectory = "/tmp/clawdi-\(getuid())"
    static let socketPath = "\(socketDirectory)/agent-state.sock"
    static let maxMessageBytes = 1024 * 1024
}

/// Event→state maps and required stdout responses for the three native agent hooks.
///
/// This is the single source of truth: Clawdi's command-line hook mode computes one event +
/// response per invocation from here, and the unit tests exercise the same code.
enum HookMapping {
    /// `agent` is "claude" (default), "antigravity", "cursor", or "omp".
    static func event(agent: String, event: String, input: [String: Any]) -> AgentStateEvent? {
        let title = string(input, keys: ["title", "session_title", "sessionTitle", "session_name", "sessionName"])
        let model = string(input, keys: ["model", "modelId", "model_id"])
        switch agent {
        case "antigravity":
            guard let state = antigravityState(event: event, input: input) else { return nil }
            let cwd = firstString(input, keys: ["cwd", "workspace", "project_path", "projectPath", "workspacePaths"])
            let session =
                string(input, keys: ["conversationId", "conversation_id", "session_id", "sessionId"]) ?? cwd
                ?? "antigravity"
            return AgentStateEvent(
                agentId: "antigravity", sessionId: session, event: event, state: state, cwd: cwd, title: title,
                model: model, source: .antigravity
            )
        case "cursor":
            guard let state = cursorState(event: event) else { return nil }
            let cwd = firstString(
                input, keys: ["cwd", "workspace", "project_path", "projectPath", "workspace_roots", "workspaceRoots"])
            let session =
                string(input, keys: ["conversation_id", "conversationId", "session_id", "sessionId"]) ?? cwd ?? "cursor"
            return AgentStateEvent(
                agentId: "cursor", sessionId: session, event: event, state: state, cwd: cwd, title: title, model: model,
                source: .cursor
            )
        case "omp":
            guard let state = ompState(event: event, input: input) else { return nil }
            let cwd = firstString(input, keys: ["cwd", "workspace", "project_path", "projectPath"])
            let session = string(input, keys: ["session_id", "sessionId"]) ?? cwd ?? "omp"
            let edits = event == "file_edit" ? editStats(input) : []
            return AgentStateEvent(
                agentId: "omp", sessionId: session, event: event, state: state, cwd: cwd, title: title, model: model,
                edits: edits.isEmpty ? nil : edits, editTuning: edits.isEmpty ? nil : popTuning(input), source: .omp
            )
        default:
            guard let state = claudeState(event: event) else { return nil }
            let cwd = firstString(input, keys: ["cwd", "workspace", "project_path", "projectPath"])
            let session = string(input, keys: ["session_id", "sessionId"]) ?? cwd ?? "claude-code"
            return AgentStateEvent(
                agentId: "claude-code", sessionId: session, event: event, state: state, cwd: cwd, title: title,
                model: model, source: .claudeCode
            )
        }
    }

    /// Claude Code EVENT_TO_STATE — exactly 11 events; anything else is ignored.
    static func claudeState(event: String) -> AgentActivityState? {
        switch event {
        case "SessionStart", "SessionEnd": return .idle
        case "UserPromptSubmit": return .thinking
        case "PreToolUse", "PostToolUse": return .working
        case "PermissionRequest", "Notification", "Elicitation": return .notification
        case "PostToolUseFailure", "StopFailure": return .error
        case "Stop": return .complete
        default: return nil
        }
    }

    /// Antigravity EVENT_TO_STATE. Note PreToolUse and PermissionRequest report no state
    /// (they only carry a stdout decision/are unregistered).
    static func antigravityState(event: String, input: [String: Any]) -> AgentActivityState? {
        switch event {
        case "PreInvocation": return .thinking
        case "PostToolUse": return input["error"] != nil ? .error : .working
        case "PostInvocation": return .complete
        case "Stop":
            if input["error"] != nil || string(input, keys: ["terminationReason"]) == "error" { return .error }
            if input["fullyIdle"] as? Bool == false { return .working }
            return .complete
        default: return nil
        }
    }

    /// Cursor — only the two execution events report a state.
    static func cursorState(event: String) -> AgentActivityState? {
        switch event {
        case "beforeShellExecution", "beforeMCPExecution": return .notification
        default: return nil
        }
    }

    /// `omp` extension lifecycle events. The generated `clawdi-omp-hook.js` extension
    /// spawns `Clawdi --clawdi-hook omp:<event>` per omp event. Completion is reported on
    /// `session_stop`, which omp emits only for the MAIN session (never task/subagent sessions)
    /// just before that session's final `agent_end`. This is the single completion path: a real
    /// finish (a `session_stop` carrying a session title) reports `.complete` and
    /// `AgentReaction.completion` renders it as `"title" finished.`, while a no-output run
    /// (`empty`), a cancelled turn (`aborted`), or a failure (re-emitted by the JS hook as
    /// `agent_error`) maps to `.idle` and clears quietly. `session_stop` is a pre-settle hook, so
    /// in the rare case another extension's `session_stop` handler returns `{ continue: true }`, the
    /// pet announces "finished" once before that continuation and again at the true settle; omp's own
    /// continuations (todo/rewind/compaction) bypass `session_stop`, so this does not fire for them.
    ///
    /// `agent_end` fires for the main session AND every subagent, so it is now a quiet clear
    /// (always `.idle`): it removes the already-completed main session without a second bubble and
    /// clears finished subagent sessions so they don't linger until the TTL — a finished subagent
    /// no longer surfaces a spurious "finished" alert. Two synthesized events drive distinct
    /// attention reactions: `ask_prompt` (the interactive `ask` tool) and `plan_approval` (plan
    /// mode submitting its plan via `resolve { action: "apply", extra: { title } }`). Per-tool
    /// failures stay `.working` — the agent keeps going, so they neither clear nor alert.
    static func ompState(event: String, input: [String: Any]) -> AgentActivityState? {
        switch event {
        case "session_start", "session_shutdown": return .idle
        case "agent_start", "turn_start": return .thinking
        case "tool_call", "tool_result", "file_edit": return .working
        case "ask_prompt", "plan_approval": return .notification
        case "session_stop":
            // The only completion path. The JS hook classifies the stop payload before it reaches
            // here: a cancelled turn (`aborted`) or no-output run (`empty`) clears quietly, and a
            // titled stop surfaces the completion reaction. (A failed stop is re-emitted by the JS
            // hook as `agent_error`, not `session_stop`.)
            if input["aborted"] != nil || input["empty"] != nil { return .idle }
            let title = string(input, keys: ["title", "session_title", "sessionTitle", "session_name", "sessionName"])
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? .complete : .idle
        case "agent_end":
            // Quiet clear only. Fires for the main session (right after its session_stop) and every
            // subagent (which never emit session_stop); clearing to `.idle` avoids a second bubble
            // on the main session and stops finished subagents from notifying.
            return .idle
        case "agent_error": return .idle
        default: return nil
        }
    }

    /// Required stdout JSON per SRC `hookResponse()`. Claude prints nothing (returns nil); antigravity
    /// and cursor always print at least "{}".
    static func response(agent: String, event: String) -> String? {
        switch agent {
        case "cursor":
            switch event {
            case "beforeShellExecution":
                return
                    #"{"permission":"ask","user_message":"Clawdi noticed a Cursor shell command needs your approval.","agent_message":"Wait for the user to approve or deny this shell command."}"#
            case "beforeMCPExecution":
                return
                    #"{"permission":"ask","user_message":"Clawdi noticed a Cursor MCP tool needs your approval.","agent_message":"Wait for the user to approve or deny this MCP tool call."}"#
            default:
                return "{}"
            }
        case "antigravity":
            switch event {
            case "PreToolUse":
                return #"{"decision":"ask","reason":"Clawdi does not approve Antigravity tool calls automatically."}"#
            case "Stop": return #"{"decision":"allow"}"#
            case "PostInvocation": return #"{"injectSteps":[],"terminationBehavior":""}"#
            default: return "{}"
            }
        default:
            return nil
        }
    }

    /// First non-empty string value among `keys`.
    static func string(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Per-file ±line counts from an omp `file_edit` payload (synthesized by the generated
    /// clawdi-omp-hook.js as `files: [{ path, added, removed }]`). Entries with no path or no
    /// net change are dropped; counts are clamped non-negative and the list is capped at 8.
    static func editStats(_ input: [String: Any]) -> [FileEditStat] {
        guard let files = input["files"] as? [[String: Any]] else { return [] }
        let stats = files.compactMap { file -> FileEditStat? in
            guard let path = string(file, keys: ["path"]) else { return nil }
            let added = max(0, (file["added"] as? NSNumber)?.intValue ?? 0)
            let removed = max(0, (file["removed"] as? NSNumber)?.intValue ?? 0)
            guard added > 0 || removed > 0 else { return nil }
            return FileEditStat(path: path, added: added, removed: removed)
        }
        return Array(stats.prefix(8))
    }

    /// Demo-only edit-pop animation overrides from optional `flight`/`rise` numbers on a
    /// `file_edit` payload, clamped to sane bounds (flight 0.3–6s, rise 0.1–1). Nil when neither
    /// is present, i.e. for every real omp event.
    static func popTuning(_ input: [String: Any]) -> EditPopTuning? {
        let flight = (input["flight"] as? NSNumber).map { min(6, max(0.3, $0.doubleValue)) }
        let rise = (input["rise"] as? NSNumber).map { min(1, max(0.1, $0.doubleValue)) }
        guard flight != nil || rise != nil else { return nil }
        return EditPopTuning(flight: flight, rise: rise)
    }

    /// Like `string`, but also unwraps the first element of array-valued fields (e.g. workspacePaths).
    static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        if let direct = string(dict, keys: keys) { return direct }
        for key in keys {
            if let values = dict[key] as? [String], let value = values.first, !value.isEmpty { return value }
            if let values = dict[key] as? [Any], let value = values.first as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
