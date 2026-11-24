import Foundation

// What the agent is doing right now. The pipeline sets it; the notch only reads it.
// Public because the voice agent (the ApexAgent target) drives it; the StudyNotch app never sets it,
// so there the notch simply stays idle apart from study sessions.
public enum AgentState: Equatable, Sendable {
    case idle
    case listening(String?)                  // your words so far while you talk, nil while waiting
    case thinking(String?)                   // what it heard (or what you typed) while the LLM works
    case acting(String)                      // what the tool did, e.g. "Opened Calculator."
    case speaking(String, acted: Bool)       // the words being spoken; acted = a tool ran this turn

    var logName: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking(let heard): return "thinking: \(heard ?? "")"
        case .acting(let label): return "acting: \(label)"
        case .speaking(let text, let acted): return "speaking\(acted ? " (after action)" : ""): \(text)"
        }
    }
}

nonisolated(unsafe) var currentAgentState: AgentState = .idle
nonisolated(unsafe) var agentStateObserver: (@Sendable (AgentState) -> Void)?
let agentStateQueue: DispatchQueue = DispatchQueue(label: "com.apexagent.state")

public func setAgentState(_ state: AgentState) {
    agentStateQueue.async {
        var state: AgentState = state
        // Speech right after a tool ran keeps the tool's colour and check, but shows the spoken words
        if case .speaking(let text, _) = state, case .acting = currentAgentState {
            state = .speaking(text, acted: true)
        }
        guard state != currentAgentState else { return }
        let wasPartial: Bool = { if case .listening(let t) = currentAgentState { return t != nil }; return false }()
        currentAgentState = state
        // Log real transitions, not every partial-transcript update
        if case .listening(let text) = state, text != nil, wasPartial {} else {
            print("◆ state → \(state.logName)")
        }
        agentStateObserver?(state)
    }
}
