import CoreFoundation
import Foundation

struct HookInstaller {
    var home: URL
    var helperPath: String

    private var helperCommand: String { shellQuote(helperPath) }
    private let commandMarkers = ["clawdi-hook", HookCommand.flag]
    private static let claudeEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "PostToolUseFailure", "Stop", "StopFailure", "Notification", "Elicitation",
    ]
    private static let antigravityMatcherEvents = ["PostToolUse"]
    private static let antigravityDirectEvents = ["PreInvocation", "PostInvocation", "Stop"]
    private static let cursorEvents = ["beforeShellExecution", "beforeMCPExecution"]

    func installAll() throws {
        try reconcile(enabled: AgentEventSource.extensions)
    }

    /// Aligns each supported hook configuration with the persisted extension settings.
    func reconcile(enabled: Set<AgentEventSource>) throws {
        if enabled.contains(.claudeCode) { try installClaude() } else { try removeClaude() }
        if enabled.contains(.antigravity) { try installAntigravity() } else { try removeAntigravity() }
        if enabled.contains(.cursor) { try installCursor() } else { try removeCursor() }
        if enabled.contains(.omp) { try installOmp() } else { try removeOmp() }
    }

    func installClaude() throws {
        let url = home.appendingPathComponent(".claude/settings.json")
        var root = try JSONObject.load(url)
        var hooks = root.object["hooks"]?.objectValue ?? [:]
        for event in Self.claudeEvents {
            var entries = normalizedArray(hooks[event])
            entries.removeAll(where: isClawdiHookCommand)
            entries.append(
                .object([
                    "matcher": .string(""),
                    "hooks": .array([
                        .object([
                            "type": .string("command"),
                            "command": .string("\(helperCommand) \(HookCommand.flag) \(event)"),
                        ])
                    ]),
                ]))
            hooks[event] = .array(entries)
        }
        for staleEvent in ["SubagentStop", "PreCompact", "Error"] {
            hooks[staleEvent] = removingMarkedEntries(from: hooks[staleEvent])
        }
        root.object["hooks"] = .object(hooks)
        try root.write(url)
    }

    func installAntigravity() throws {
        let url = home.appendingPathComponent(".gemini/config/hooks.json")
        var root = try JSONObject.load(url)
        // PostToolUse is matcher-style; the rest are direct command entries. PreToolUse and
        // PermissionRequest are NOT registered (PreToolUse is stale-removed) — Antigravity only
        // reports state for these four events.
        let matcherEvents = Self.antigravityMatcherEvents
        let directEvents = Self.antigravityDirectEvents
        let staleEvents = ["PreToolUse", "PermissionRequest"]
        var clawdi = root.object["clawdi"]?.objectValue ?? [:]
        if clawdi["enabled"] != .bool(false) {
            clawdi["enabled"] = .bool(true)
        }
        for stale in staleEvents {
            clawdi[stale] = removingMarkedEntries(from: clawdi[stale])
        }

        for event in matcherEvents {
            var entries = normalizedArray(clawdi[event])
            entries.removeAll(where: isClawdiHookCommand)
            entries.append(
                .object([
                    "matcher": .string(""),
                    "hooks": .array([
                        .object([
                            "type": .string("command"),
                            "command": .string("\(helperCommand) \(HookCommand.flag) antigravity:\(event)"),
                            "timeout": .number(1),
                        ])
                    ]),
                ]))
            clawdi[event] = .array(entries)
        }

        for event in directEvents {
            var entries = normalizedArray(clawdi[event])
            entries.removeAll(where: isClawdiHookCommand)
            entries.append(
                .object([
                    "type": .string("command"),
                    "command": .string("\(helperCommand) \(HookCommand.flag) antigravity:\(event)"),
                    "timeout": .number(1),
                ]))
            clawdi[event] = .array(entries)
        }

        root.object["clawdi"] = .object(clawdi)
        try root.write(url)
    }

    func installCursor() throws {
        let url = home.appendingPathComponent(".cursor/hooks.json")
        var root = try JSONObject.load(url)
        root.object["version"] = root.object["version"] ?? .number(1)
        var hooks = root.object["hooks"]?.objectValue ?? [:]
        for event in Self.cursorEvents {
            root.object[event] = removingMarkedEntries(from: root.object[event])
            var entries = normalizedArray(hooks[event])
            entries.removeAll(where: isClawdiHookCommand)
            entries.append(.object(["command": .string("\(helperCommand) \(HookCommand.flag) cursor:\(event)")]))
            hooks[event] = .array(entries)
        }
        root.object["hooks"] = .object(hooks)
        try root.write(url)
    }

    func removeClaude() throws {
        let url = home.appendingPathComponent(".claude/settings.json")
        var root = try JSONObject.load(url)
        var hooks = root.object["hooks"]?.objectValue ?? [:]
        for event in Self.claudeEvents + ["SubagentStop", "PreCompact", "Error"] {
            if let entries = removingMarkedEntries(from: hooks[event]) {
                hooks[event] = entries
            } else {
                hooks.removeValue(forKey: event)
            }
        }
        root.object["hooks"] = .object(hooks)
        try root.write(url)
    }

    func removeAntigravity() throws {
        let url = home.appendingPathComponent(".gemini/config/hooks.json")
        var root = try JSONObject.load(url)
        root.object.removeValue(forKey: "clawdi")
        try root.write(url)
    }

    func removeCursor() throws {
        let url = home.appendingPathComponent(".cursor/hooks.json")
        var root = try JSONObject.load(url)
        var hooks = root.object["hooks"]?.objectValue ?? [:]
        for event in Self.cursorEvents {
            if let entries = removingMarkedEntries(from: hooks[event]) {
                hooks[event] = entries
            } else {
                hooks.removeValue(forKey: event)
            }
            if let entries = removingMarkedEntries(from: root.object[event]) {
                root.object[event] = entries
            } else {
                root.object.removeValue(forKey: event)
            }
        }
        root.object["hooks"] = .object(hooks)
        try root.write(url)
    }

    func removeOmp() throws {
        let url = home.appendingPathComponent(".omp/agent/extensions/clawdi-omp-hook.js")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// `omp` loads JS/TS extension modules rather than shell-command hooks, so we drop a
    /// self-contained extension into the user-level native auto-discovery root (`~/.omp/agent/extensions`).
    /// It registers omp lifecycle handlers that spawn Clawdi's hook mode, reusing the shared
    /// HookMapping + Unix socket sender. We own the whole file, so install is an idempotent atomic overwrite.
    func installOmp() throws {
        let dir = home.appendingPathComponent(".omp/agent/extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("clawdi-omp-hook.js")
        let data = Data(ompHookModule().utf8)
        let tmp = dir.appendingPathComponent(".clawdi-omp-hook.\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    /// Source of the generated omp extension module, with the absolute Clawdi executable path baked in.
    private func ompHookModule() -> String { ompHookPreamble() + "\n" + ompHookEntry() }

    /// Imports, the helper invoker, and payload-shaping helpers for the generated omp module.
    private func ompHookPreamble() -> String {
        """
        import { spawn } from "node:child_process";

        // Generated by Clawdi (HookInstaller.installOmp). Bridges omp agent lifecycle events to
        // the running Clawdi desktop pet: each registered event spawns Clawdi in hook mode, which
        // maps the event through the shared HookMapping and writes one best-effort message to the
        // local Unix socket. Completion is reported on the main-session session_stop event (never
        // fired for subagents), so finished subagents and per-turn tool loops produce no "done" alert.
        const HELPER = \(jsString(helperPath));
        const EVENTS = [
          "session_start", "agent_start", "turn_start", "tool_call", "tool_result",
          "agent_end", "session_stop", "session_shutdown",
        ];

        function fire(event, payload) {
          try {
            const child = spawn(HELPER, [\(jsString(HookCommand.flag)), "omp:" + event], { stdio: ["pipe", "ignore", "ignore"] });
            child.on("error", () => {});
            if (child.stdin) {
              child.stdin.on("error", () => {});
              child.stdin.end(JSON.stringify(payload));
            }
            child.unref();
          } catch {}
        }

        function nonEmptyString(value) {
          return typeof value === "string" && value.trim() ? value.trim() : null;
        }

        function modelString(ctx) {
          try {
            const model = ctx && ctx.model;
            if (!model) return null;
            if (typeof model === "string") return nonEmptyString(model);
            const id = nonEmptyString(model.id) || nonEmptyString(model.name);
            const provider = nonEmptyString(model.provider);
            if (provider && id) return provider + "/" + id;
            return id || provider || nonEmptyString(model.api) || null;
          } catch {
            return null;
          }
        }

        // Returns the last assistant message so the caller can classify how a turn ended from both
        // its stopReason and errorMessage. An agent_end with no assistant output is an internal/no-op
        // run and should only clear the synthetic active session. A clean caller-abort reports
        // stopReason "aborted"; a racy or tool-phase abort can instead surface as stopReason "error"
        // with an abort-shaped message, so both are inspected before deciding whether to alert.
        function lastAssistantMessage(messages) {
          if (!Array.isArray(messages)) return null;
          for (let i = messages.length - 1; i >= 0; i--) {
            const message = messages[i];
            if (message && message.role === "assistant") return message;
          }
          return null;
        }

        // Per-file +N/-N line counts for a successful `edit` tool result, aggregated by path so a
        // multi-op edit to one file reports a single entry. Counts come from each per-file unified
        // diff (falling back to the single-file top-level diff); files with no +/- lines are
        // dropped, and the list is capped so a sweeping refactor can't flood the socket payload.
        function editStats(details) {
          const entries = Array.isArray(details.perFileResults) && details.perFileResults.length
            ? details.perFileResults
            : [details];
          const byPath = new Map();
          for (const entry of entries) {
            if (!entry || entry.isError) continue;
            const path = nonEmptyString(entry.move) || nonEmptyString(entry.path);
            if (!path || typeof entry.diff !== "string") continue;
            let added = 0;
            let removed = 0;
            for (const line of entry.diff.split(/\\r?\\n/)) {
              if (line.startsWith("+") && !line.startsWith("+++")) added++;
              else if (line.startsWith("-") && !line.startsWith("---")) removed++;
            }
            if (!added && !removed) continue;
            const prev = byPath.get(path) || { path, added: 0, removed: 0 };
            prev.added += added;
            prev.removed += removed;
            byPath.set(path, prev);
          }
          return [...byPath.values()].slice(0, 8);
        }

        function sessionTitle(pi, ctx) {
          try {
            const title = typeof pi.getSessionName === "function" ? pi.getSessionName() : null;
            const text = nonEmptyString(title);
            if (text) return text;
          } catch {}
          try {
            const sm = ctx && ctx.sessionManager;
            const title = sm && typeof sm.getSessionName === "function" ? sm.getSessionName() : null;
            const text = nonEmptyString(title);
            if (text) return text;
          } catch {}
          return null;
        }
        """
    }

    /// The extension entry point: per-event handlers that classify each omp lifecycle event and
    /// forward the synthesized event name to Clawdi's hook mode.
    private func ompHookEntry() -> String {
        """
        export default function clawdiOmpHook(pi) {
          for (const event of EVENTS) {
            pi.on(event, (data, ctx) => {
              const cwd = (ctx && ctx.cwd) || (data && data.cwd) || process.cwd();
              let session = cwd;
              try {
                const sm = ctx && ctx.sessionManager;
                const file = sm && typeof sm.getSessionFile === "function" ? sm.getSessionFile() : null;
                if (file) session = file;
              } catch {}
              const title = sessionTitle(pi, ctx);
              const payload = { cwd, session_id: session };
              if (title) payload.title = title;
              const model = modelString(ctx);
              if (model) payload.model = model;
              if (event === "session_stop") {
                // session_stop fires for the MAIN session only (never task/subagent sessions). It is
                // the sole completion signal: a titled stop surfaces the "title" finished. bubble,
                // while a cancel (aborted), no-output settle (empty), or failure (re-emitted as
                // agent_error) clears quietly. The session's trailing agent_end stays a plain quiet
                // clear; because the two hook processes can be delivered out of order, Clawdi's
                // state machine treats this completion as authoritative even if an overtaking
                // agent_end already cleared the active session.
                const last = data ? (data.last_assistant_message || lastAssistantMessage(data.messages)) : null;
                if (!last) {
                  // A stop with no assistant output is an internal/no-op settle, not a real finish.
                  payload.empty = true;
                } else {
                  const reason = last.stopReason;
                  const errorText = typeof last.errorMessage === "string" ? last.errorMessage : "";
                  // A user cancel (stopReason "aborted", or an abort/cancel-shaped error message)
                  // clears the pet quietly. A genuine failure (stopReason "error" with a
                  // substantive, non-abort message) is re-emitted as agent_error, which Clawdi maps
                  // to .idle — the session clears with no alert. A bare "error" stop with no message
                  // is a normal end of turn and falls through to the completion reaction.
                  const aborted = reason === "aborted" || /\\b(abort|cancel)/i.test(errorText);
                  if (aborted) payload.aborted = true;
                  else if (reason === "error" && errorText.trim()) { fire("agent_error", payload); return; }
                }
                fire("session_stop", payload);
                return;
              }
              // A successful edit tool result is re-emitted as file_edit carrying per-file +/-
              // line counts, which the pet renders as flying damage-number diff stats. A failed
              // or no-op edit falls through to the plain tool_result forward (still .working).
              if (event === "tool_result" && data && data.toolName === "edit" && !data.isError && data.details) {
                try {
                  const files = editStats(data.details);
                  if (files.length) {
                    payload.files = files;
                    fire("file_edit", payload);
                    return;
                  }
                } catch {}
              }
              // agent_end fires for the main session AND every subagent; it falls through to a plain
              // forward that Clawdi maps to a quiet clear (.idle). The main session's completion is
              // owned by the preceding session_stop, and a finished subagent (which never emits
              // session_stop) clears here with no "finished" bubble.
              if (event === "tool_call" && data) {
                if (data.toolName === "ask") { fire("ask_prompt", payload); return; }
                // Plan-mode completion submits the finalized plan via resolve { action: "apply",
                // extra: { title } }; that title (a non-empty string) distinguishes it from a
                // preview-apply resolve (ast_edit etc.), which carries no title.
                if (data.toolName === "resolve") {
                  const input = data.input;
                  const planTitle = input && input.extra && input.extra.title;
                  if (input && input.action === "apply" && typeof planTitle === "string" && planTitle.trim()) {
                    fire("plan_approval", payload);
                    return;
                  }
                }
              }
              fire(event, payload);
            });
          }
        }
        """
    }
    private func jsString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func normalizedArray(_ value: JSONValue?) -> [JSONValue] {
        guard let value else { return [] }
        if let array = value.arrayValue { return array }
        if case .null = value { return [] }
        return [value]
    }

    private func removingMarkedEntries(from value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        if case .array(let array) = value {
            let kept = array.filter { !isClawdiHookCommand($0) }
            return kept.isEmpty ? nil : .array(kept)
        }
        return isClawdiHookCommand(value) ? nil : value
    }

    private func isClawdiHookCommand(_ value: JSONValue) -> Bool {
        commandMarkers.contains { value.containsCommand($0) }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum JSONValue: Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    func containsCommand(_ needle: String) -> Bool {
        switch self {
        case .string(let s): return s.contains(needle)
        case .array(let a): return a.contains { $0.containsCommand(needle) }
        case .object(let o): return o.values.contains { $0.containsCommand(needle) }
        default: return false
        }
    }

    var any: Any {
        switch self {
        case .object(let o): return o.mapValues { $0.any }
        case .array(let a): return a.map { $0.any }
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }

    static func from(_ any: Any) -> JSONValue {
        if let o = any as? [String: Any] { return .object(o.mapValues(from)) }
        if let a = any as? [Any] { return .array(a.map(from)) }
        if let s = any as? String { return .string(s) }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        return .null
    }
}

struct JSONObject {
    var object: [String: JSONValue]

    static func load(_ url: URL) throws -> JSONObject {
        guard let data = try? Data(contentsOf: url),
            let any = try? JSONSerialization.jsonObject(with: data),
            let dict = any as? [String: Any]
        else { return JSONObject(object: [:]) }
        return JSONObject(object: dict.mapValues(JSONValue.from))
    }

    func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: object.mapValues { $0.any }, options: [.prettyPrinted, .sortedKeys])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
