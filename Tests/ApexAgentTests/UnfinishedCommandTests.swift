import Testing
@testable import ApexAgent

// A pause after these: wait for the rest of the sentence
@Test(arguments: ["open spotify and", "Open Spotify and.", "set volume to 30 then", "open notes, and", "take a screenshot also"])
func holdsUnfinishedCommand(_ phrase: String) {
    #expect(isUnfinishedCommand(phrase))
}

// Complete commands go straight to the LLM, with no extra wait
@Test(arguments: ["open spotify and play music", "play music", "quit kitty", "rock and roll radio please", "", "stand"])
func sendsFinishedCommand(_ phrase: String) {
    #expect(!isUnfinishedCommand(phrase))
}
