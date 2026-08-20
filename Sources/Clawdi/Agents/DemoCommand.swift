import Foundation

/// Developer CLI for previewing pet reactions: `Clawdi --clawdi-demo <name>` fires the matching
/// reaction on the already-running app by sending synthesized omp events over the agent-state
/// socket. `name` is one of `complete`, `ask`, `plan`, `knead`, `edit`, or `all` (the one-shot
/// reactions in turn; the long-running `knead` preview stays opt-in). Error turns clear silently, so there
/// is no `error` demo target — `just demo complete` covers the happy completion path.
///
/// A unique session id per run sidesteps the notification dedup so a reaction can be triggered
/// repeatedly while iterating on the animation. `complete` needs an active session first, so it
/// sends `agent_start` and then the terminal event over separate connections with a brief gap.
/// `knead` holds a synthetic thinking session open long enough to watch several knead cycles (keep
/// hands off the keyboard — typing pauses it), then shuts the session down silently. `edit` fires
/// a multi-file `file_edit` volley (the flying `project>file +a -r` diff stats), then shuts the
/// session down once the pops have flown. `edit` takes flight tuning after a colon —
/// `edit:flight=1.8,rise=0.6` — where `flight` is seconds airborne and `rise` the apex height as
/// a fraction of the pet square (random 0.5–0.75 when unset); the landed 750ms fade-out is
/// implicit.
enum DemoCommand {
    static let flag = "--clawdi-demo"
    static let names = ["complete", "ask", "plan", "knead", "edit"]
    /// `all` previews the one-shot reactions; the 12s `knead` hold is explicit-only.
    static let allNames = ["complete", "ask", "plan", "edit"]

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let arg = value(arguments: arguments) else { return false }
        let (base, options) = parseTarget(arg)
        let targets = base == "all" ? allNames : [base]
        guard !base.isEmpty, targets.allSatisfy(names.contains) else {
            FileHandle.standardError.write(
                Data("usage: \(flag) <\(names.joined(separator: "|"))|all> (edit takes edit:flight=1.8,rise=0.6)\n".utf8))
            return true
        }
        for (index, name) in targets.enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: 1.6) }
            fire(name, options: options)
        }
        return true
    }

    /// Splits `edit:flight=1.8,rise=0.6` into the demo name and its numeric options; a bare name
    /// yields no options. Malformed pairs are dropped rather than failing the demo.
    static func parseTarget(_ arg: String) -> (name: String, options: [String: Double]) {
        guard let colon = arg.firstIndex(of: ":") else { return (arg, [:]) }
        var options: [String: Double] = [:]
        for pair in arg[arg.index(after: colon)...].split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let value = Double(kv[1]) else { continue }
            options[String(kv[0])] = value
        }
        return (String(arg[..<colon]), options)
    }

    static func events(for name: String) -> [String] {
        switch name {
        case "complete": return ["agent_start", "session_stop"]
        case "ask": return ["ask_prompt"]
        case "plan": return ["plan_approval"]
        case "knead": return ["agent_start", "session_shutdown"]
        case "edit": return ["agent_start", "file_edit", "session_shutdown"]
        default: return []
        }
    }

    /// Seconds between a demo's events: reactions fire back-to-back, the knead preview holds its
    /// thinking session open across several 1.8s knead cycles before ending it.
    static func gap(for name: String) -> TimeInterval {
        switch name {
        case "knead": return 12
        case "edit": return 2.2  // let the diff-stat volley finish flying before the quiet clear
        default: return 0.2
        }
    }

    private static func fire(_ name: String, options: [String: Double] = [:]) {
        let session = "demo-\(name)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let events = events(for: name)
        for (index, event) in events.enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: gap(for: name)) }
            send(event: event, session: session, options: options)
        }
    }

    private static func send(event: String, session: String, options: [String: Double] = [:]) {
        var input: [String: Any] = [
            "session_id": session,
            "cwd": FileManager.default.currentDirectoryPath,
            "title": "demo: \(event)"
        ]
        if event == "file_edit" {
            let cwd = FileManager.default.currentDirectoryPath
            input["files"] = [
                ["path": "\(cwd)/Sources/Clawdi/PetWindow/PetPanel.swift", "added": 12, "removed": 12],
                ["path": "\(cwd)/Sources/Shared/HookMapping.swift", "added": 34, "removed": 0],
                ["path": "\(cwd)/Tests/ClawdiTests/ClawdiTests.swift", "added": 0, "removed": 7],
            ]
            for (key, value) in options { input[key] = value }
        }
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
