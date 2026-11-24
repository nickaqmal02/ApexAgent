import NotchCore

// Where to go after a turn finishes: back to listening if the mic is on, otherwise idle.
// Lives in the agent (not NotchCore) because only the agent knows about the microphone.
func restingAgentState() -> AgentState {
    return voiceActive ? .listening(nil) : .idle
}
