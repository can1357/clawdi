import Foundation

/// Developer CLI for previewing pet reactions: `Clawdi --clawdi-demo <name>` fires the matching
/// reaction on the already-running app by sending synthesized omp events over the agent-state
/// socket. `name` is one of `complete`, `ask`, `plan`, `knead`, or `all` (the one-shot reactions
/// in turn; the long-running `knead` preview stays opt-in). Error turns clear silently, so there
/// is no `error` demo target — `just demo complete` covers the happy completion path.
///
/// A unique session id per run sidesteps the notification dedup so a reaction can be triggered
/// repeatedly while iterating on the animation. `complete` needs an active session first, so it
/// sends `agent_start` and then the terminal event over separate connections with a brief gap.
/// `knead` holds a synthetic thinking session open long enough to watch several knead cycles (keep
/// hands off the keyboard — typing pauses it), then shuts the session down silently.
enum DemoCommand {
    static let flag = "--clawdi-demo"
    static let names = ["complete", "ask", "plan", "knead"]
    /// `all` previews the one-shot reactions; the 12s `knead` hold is explicit-only.
    static let allNames = ["complete", "ask", "plan"]

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let arg = value(arguments: arguments) else { return false }
        let targets = arg == "all" ? allNames : [arg]
        guard !arg.isEmpty, targets.allSatisfy(names.contains) else {
            FileHandle.standardError.write(Data("usage: \(flag) <\(names.joined(separator: "|"))|all>\n".utf8))
            return true
        }
        for (index, name) in targets.enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: 1.6) }
            fire(name)
        }
        return true
    }

    static func events(for name: String) -> [String] {
        switch name {
        case "complete": return ["agent_start", "session_stop"]
        case "ask": return ["ask_prompt"]
        case "plan": return ["plan_approval"]
        case "knead": return ["agent_start", "session_shutdown"]
        default: return []
        }
    }

    /// Seconds between a demo's events: reactions fire back-to-back, the knead preview holds its
    /// thinking session open across several 1.8s knead cycles before ending it.
    static func gap(for name: String) -> TimeInterval { name == "knead" ? 12 : 0.2 }

    private static func fire(_ name: String) {
        let session = "demo-\(name)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let events = events(for: name)
        for (index, event) in events.enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: gap(for: name)) }
            send(event: event, session: session)
        }
    }

    private static func send(event: String, session: String) {
        let input: [String: Any] = [
            "session_id": session,
            "cwd": FileManager.default.currentDirectoryPath,
            "title": "demo: \(event)"
        ]
        guard var stateEvent = HookMapping.event(agent: "omp", event: event, input: input) else { return }
        stateEvent.source = .direct
        AgentStateClient.send(stateEvent)
    }

    private static func value(arguments: [String]) -> String? {
        guard let flagIndex = arguments.dropFirst().firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        return valueIndex < arguments.endIndex ? arguments[valueIndex] : ""
    }
}
