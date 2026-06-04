import Foundation

/// Command-line hook mode for the Clawdi app executable.
///
/// Agent hook configs invoke `Clawdi --clawdi-hook <event>` instead of launching a
/// separate helper binary. Normal app launches skip this path because the explicit
/// flag is required.
enum HookCommand {
    static let flag = "--clawdi-hook"

    struct Mapping {
        let event: AgentStateEvent?
        let response: String?
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let rawEvent = hookInput(arguments: arguments) else { return false }
        let mapping = map(input: readInput(), rawEvent: rawEvent)
        if let event = mapping.event { AgentStateClient.send(event) }
        if let response = mapping.response { print(response) }
        return true
    }

    static func mapIfRequested(arguments: [String], input: [String: Any]) -> Mapping? {
        guard let rawEvent = hookInput(arguments: arguments) else { return nil }
        return map(input: input, rawEvent: rawEvent)
    }

    static func map(input: [String: Any], rawEvent: String) -> Mapping {
        let parts =
            rawEvent
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        let agent = parts.count == 2 ? parts[0] : "claude"
        let eventName =
            parts.count == 2
            ? parts[1]
            : (parts.first.flatMap { $0.isEmpty ? nil : $0 }
                ?? HookMapping.string(input, keys: ["hook_event_name", "event"])
                ?? "")
        return Mapping(
            event: HookMapping.event(agent: agent, event: eventName, input: input),
            response: HookMapping.response(agent: agent, event: eventName)
        )
    }

    private static func hookInput(arguments: [String]) -> String? {
        guard let flagIndex = arguments.dropFirst().firstIndex(of: flag) else { return nil }
        let eventIndex = arguments.index(after: flagIndex)
        return eventIndex < arguments.endIndex ? arguments[eventIndex] : ""
    }

    private static func readInput() -> [String: Any] {
        let data = FileHandle.standardInput.readData(ofLength: AgentStateTransport.maxMessageBytes + 1)
        guard data.count <= AgentStateTransport.maxMessageBytes else { return [:] }
        guard !data.isEmpty,
            let any = try? JSONSerialization.jsonObject(with: data),
            let dict = any as? [String: Any]
        else { return [:] }
        return dict
    }
}
