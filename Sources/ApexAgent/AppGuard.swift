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
