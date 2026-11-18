import AppKit
import Foundation

// Checks that an app the LLM names really exists (before open) or really runs (before quit).
// Keeps wrong tool choices, like "close the window" -> quit "Window", from doing anything.

func installedAppExists(_ name: String) -> Bool {
    let wanted: String = name.lowercased() + ".app"
    let folders: [String] = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
    for folder in folders {
        let items: [String] = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        if items.contains(where: { $0.lowercased() == wanted }) {
            return true
        }
    }
    return false
}

func runningAppExists(_ name: String) -> Bool {
    let wanted: String = name.lowercased()
    return NSWorkspace.shared.runningApplications.contains { app in
        (app.localizedName ?? "").lowercased() == wanted
    }
}

// The text of the request being handled now. Set by askLLM before the model is called.
nonisolated(unsafe) var currentUserInput: String = ""

// The app name must appear in what the user said. Stops the model from choosing a name it invented,
// like quitting the open terminal for "close the window".
func nameAppearsInInput(_ name: String) -> Bool {
    let wanted: String = name.lowercased()
    return !wanted.isEmpty && currentUserInput.lowercased().contains(wanted)
}

// open_url only accepts web addresses, never files, apps or other URL schemes.
func isWebURL(_ text: String) -> Bool {
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host else { return false }
    return (scheme == "https" || scheme == "http") && !host.isEmpty
}

// Returns the real Shortcut name if one matches (ignoring case), so the model can't invent one.
func matchingShortcut(_ name: String) -> String? {
    let all: [String] = runShell("/usr/bin/shortcuts", args: ["list"]).components(separatedBy: "\n")
    return all.first { $0.lowercased() == name.lowercased() }
}

// Every main word (3+ letters) of the Shortcut's name must be in what the user said.
// Some Shortcuts send messages, so a vague request must never trigger one.
func shortcutNamedInInput(_ name: String) -> Bool {
    let said: String = currentUserInput.lowercased()
    let words: [String] = name.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 3 }
    return !words.isEmpty && words.allSatisfy { said.contains($0) }
}
