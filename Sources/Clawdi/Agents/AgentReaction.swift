import Foundation

/// What the pet does in response to an agent output that warrants a visible reaction. Kept as a
/// pure value so the per-event routing — which animation/sound/speech the omp ask / plan-approval /
/// error / completion moments each map to — is unit-testable without the AppKit pet view.
struct AgentReaction: Equatable {
    enum Animation: Equatable { case jump, tilt, pop, shake, none }
    enum Sound: Equatable { case completion, reminder, none }

    var animation: Animation
    var sound: Sound
    var speech: String
    var bubbleKind: SpeechBubbleKind

    /// Reaction for `AgentOutput.complete` (a finished turn). A failed omp turn is routed to
    /// `.idle` in `HookMapping` and never reaches here — errors clear silently, with no shake or
    /// alert. omp completions lead with the session title (`"Fix tests" finished.`).
    static func completion(for event: AgentStateEvent) -> AgentReaction {
        let name = displayName(for: event)
        // omp completions come from the main-session `session_stop` event (never fired for
        // subagents); a no-title or aborted/failed stop is routed to .idle in HookMapping, so
        // subagent/internal continuations clear silently. Lead with the title per user preference:
        // `"Fix tests" finished.` instead of `omp finished: Fix tests.`
        if event.agentId == "omp" {
            let title = title(for: event) ?? name
            return AgentReaction(
                animation: .jump, sound: .completion,
                speech: "\"\(title)\" finished.", bubbleKind: .notice)
        }
        return AgentReaction(
            animation: .jump, sound: .completion,
            speech: sentence(name, "finished", title(for: event)), bubbleKind: .notice)
    }

    /// Reaction for `AgentOutput.notification` (the agent needs the user). omp distinguishes a
    /// pending question (`ask_prompt`, a curious head-tilt + ❓) from a plan awaiting approval
    /// (`plan_approval`, a scale "pop" + 📋); other agents fall through to the generic attention
    /// nudge with no body animation, matching the pre-existing behavior.
    static func notification(for event: AgentStateEvent) -> AgentReaction {
        let name = displayName(for: event)
        switch event.event {
        case "ask_prompt":
            return AgentReaction(
                animation: .tilt, sound: .reminder,
                speech: sentence(name, "has a question", title(for: event)), bubbleKind: .reminder)
        case "plan_approval":
            return AgentReaction(
                animation: .pop, sound: .reminder,
                speech: sentence(name, "wants plan approval", title(for: event)), bubbleKind: .reminder)
        default:
            return AgentReaction(
                animation: .none, sound: .reminder,
                speech: sentence(name, "needs attention", title(for: event)), bubbleKind: .reminder)
        }
    }

    private static func sentence(_ name: String, _ verb: String, _ title: String?) -> String {
        guard let title else { return "\(name) \(verb)." }
        return "\(name) \(verb): \(title)."
    }

    static func displayName(for event: AgentStateEvent) -> String {
        switch event.agentId {
        case "claude-code": return "Claude Code"
        case "antigravity": return "Antigravity"
        case "cursor": return "Cursor"
        case "omp": return "omp"
        default: return "Agent"
        }
    }

    static func title(for event: AgentStateEvent) -> String? {
        guard let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        return String(title.prefix(80))
    }
}
