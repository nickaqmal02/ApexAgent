import Testing
@testable import ApexAgent

// Requests that must close ApexAgent itself
@Test(arguments: [
    "exit", "Exit.", "quit", "quit apex agent", "Quit ApexAgent.", "exit this application",
    "please exit this application", "close this application", "close this app", "stop listening",
    "shut down apex agent", "close the app",
])
func closesApexAgent(_ phrase: String) {
    #expect(isExitPhrase(phrase))
}

// Requests that must NOT close ApexAgent: they name another app, are too vague, or are too long
@Test(arguments: [
    "quit chrome", "quit spotify", "exit chrome now", "close spotify", "close spotify application",
    "close the window", "stop", "stop the music", "what's my battery", "",
    "can you please quit this application right now",
])
func doesNotCloseApexAgent(_ phrase: String) {
    #expect(!isExitPhrase(phrase))
}
