import Foundation
@preconcurrency import Network

/// Fire-and-forget sender for `AgentStateEvent`s over the local Unix socket. Shared by
/// command-line hook mode (`--clawdi-hook`) and the reaction demo CLI (`--clawdi-demo`).
enum AgentStateClient {
    static func send(_ event: AgentStateEvent) {
        guard let data = try? JSONEncoder().encode(event),
            data.count <= AgentStateTransport.maxMessageBytes
        else { return }
        let conn = NWConnection(to: NWEndpoint.unix(path: AgentStateTransport.socketPath), using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        conn.start(queue: .global(qos: .utility))
        conn.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { _ in sem.signal() }
        )
        _ = sem.wait(timeout: .now() + .milliseconds(250))
        conn.cancel()
    }
}
