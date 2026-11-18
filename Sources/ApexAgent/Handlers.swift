import Foundation
// NOTE: SPM will handle it nick Swift Package Manager

// NOTE: METHOD TO HANDLES THE COMMAND
func handleOpen(_ appName: String) {
    let result = runShell("/usr/bin/open", args: ["-a", appName])
    if result.isEmpty {
        print(" Opened \(appName)")
    } else {
        print(" \(appName) - \(result)")
    }
}

func handleQuit(_ appName: String) {
    // we accept the appName
    let script = "tell application \"\(appName)\" to quit"
    let result = runShell("/usr/bin/osascript", args: ["-e", script])
    if result.isEmpty {
        print(" Quit \(appName)")
    } else {
        print(" \(appName) - \(result)")
    }
}

func handleVolume(_ level: Int) {
    
    let clamped = max(0, min(100, level))

    _ = runShell("/usr/bin/osascript", args: ["-e", "set volume output volume \(clamped)"])
    print("volume set to \(clamped)")
}

// Returns the real reading, e.g. "Battery 30%, discharging.", so the agent loop can decide on it
func handleBattery() -> String {
    // pmset -g batt
    let result = runShell("/usr/bin/pmset", args: ["-g", "batt"])
    print(" \(result)")
    // the line looks like: -InternalBattery-0 (id=...)	30%; discharging; 1:09 remaining present: true
    guard let line = result.split(separator: "\n").first(where: { $0.contains("%") }) else {
        return "I couldn't read the battery."
    }
    let fields = line.split(separator: "\t").last?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    guard let percent = fields.first else { return "I couldn't read the battery." }
    let status: String = fields.count > 1 ? ", \(fields[1])" : ""
    return "Battery \(percent)\(status)."
}

// Returns the apps you can see (Dock apps), not every background process, so the list is short enough to reason about
func handleListApps() -> String {
    let result = runShell("/usr/bin/osascript", args: ["-e", "tell application \"System Events\" to get name of every application process whose background only is false"])
    let names: String = result.trimmingCharacters(in: .whitespacesAndNewlines)
    print(" \(names)")
    return names.isEmpty ? "I couldn't list the apps." : "Running apps: \(names)."
}

// MARK: - Kitty Terminal Handler (Nik's personal tool)
func handleKittyWindow() {
    // kitty --single-instance opens a new OS window in the running kitty instance
    // (if kitty isn't running, it just launches it fresh)
    _ = runShell("/opt/homebrew/bin/kitty", args: ["--single-instance", "--directory", NSHomeDirectory()])
    print(" Kitty window opened")
}

// MARK: - Audio Device Handler (demo setup)
func handleAudioDevice(_ device: String, type: String) {
    // Try exact match first
    var result = runShell("/opt/homebrew/bin/SwitchAudioSource",
                          args: ["-t", type, "-s", device])

    // Verify the switch actually happened
    let current = runShell("/opt/homebrew/bin/SwitchAudioSource",
                           args: ["-c", "-t", type])

    if !current.contains(device) {
        // Exact match failed — try fuzzy match against available devices
        let devices = runShell("/opt/homebrew/bin/SwitchAudioSource",
                               args: ["-a", "-t", type])
        let deviceList = devices.split(separator: "\n").map { String($0) }

        let match = deviceList.first { d in
            d.lowercased().contains(device.lowercased()) ||
            device.lowercased().contains(d.lowercased().split(separator: " ").first ?? "")
        }

        if let matched = match {
            result = runShell("/opt/homebrew/bin/SwitchAudioSource",
                              args: ["-t", type, "-s", matched])
            print("🎚️ Switched \(type) to: \(matched)")
        } else {
            print("❌ Couldn't find device '\(device)'. Available \(type) devices:")
            print(devices)
        }
    } else {
        print("🎚️ \(result)")
    }
}

func listAudioDevices() {
    let inputs = runShell("/opt/homebrew/bin/SwitchAudioSource", args: ["-a", "-t", "input"])
    let outputs = runShell("/opt/homebrew/bin/SwitchAudioSource", args: ["-a", "-t", "output"])
    print("Input: \(inputs)")
    print("Outputs: \(outputs)")
}





// MARK: - Daily commands
// Each returns the sentence to speak, describing what actually happened.

func handleTime() -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateFormat = "h:mm a, EEEE d MMMM"
    return "It's \(formatter.string(from: Date()))."
}

func handleMedia(action: String, app: String) -> String {
    let verbs: [String: String] = ["play": "play", "pause": "pause", "next": "next track", "previous": "previous track"]
    guard let verb = verbs[action.lowercased()] else {
        return "I can play, pause, skip or go back."
    }
    let target: String = app.lowercased() == "music" ? "Music" : "Spotify"
    // Only "play" may launch the app; pause and skip need it running already
    if verb != "play" && !runningAppExists(target) {
        return "\(target) isn't running."
    }
    _ = runShell("/usr/bin/osascript", args: ["-e", "tell application \"\(target)\" to \(verb)"])
    let spoken: [String: String] = ["play": "Playing on \(target).", "pause": "Paused.", "next track": "Next track.", "previous track": "Previous track."]
    return spoken[verb] ?? "Done."
}

func handleOpenURL(_ url: String) -> String {
    _ = runShell("/usr/bin/open", args: [url])
    let host: String = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? "the page"
    return "Opening \(host)."
}

func handleTimer(seconds: Int) -> String {
    let duration: Int = max(1, min(seconds, 3 * 60 * 60))   // 1 s to 3 h
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(duration)) {
        _ = runShell("/usr/bin/osascript", args: ["-e", "display notification \"Your timer is done\" with title \"ApexAgent\" sound name \"Glass\""])
        speak("Your timer is done.", requestId: "timer")
    }
    let text: String = duration % 60 == 0
        ? "\(duration / 60) minute\(duration / 60 == 1 ? "" : "s")"
        : "\(duration) second\(duration == 1 ? "" : "s")"
    return "Timer set for \(text)."
}

func handleShortcut(_ name: String) -> String {
    let result: String = runShell("/usr/bin/shortcuts", args: ["run", name])
    return result.lowercased().contains("error") ? "The \(name) shortcut failed." : "Ran \(name)."
}

func handleScreenshot() -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let path: String = NSHomeDirectory() + "/Desktop/ApexAgent screenshot \(formatter.string(from: Date())).png"
    _ = runShell("/usr/sbin/screencapture", args: ["-x", path])
    return FileManager.default.fileExists(atPath: path)
        ? "Screenshot saved to your Desktop."
        : "The screenshot failed. Check Screen Recording permission."
}

func handleLockScreen() -> String {
    _ = runShell("/usr/bin/pmset", args: ["displaysleepnow"])
    return "Locking the screen."
}

func handleDarkMode(_ mode: String) -> String {
    let value: String
    switch mode.lowercased() {
    case "on": value = "true"
    case "off": value = "false"
    default: value = "not dark mode"
    }
    let result: String = runShell("/usr/bin/osascript", args: ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)"])
    if result.lowercased().contains("error") || result.contains("not allowed") {
        return "I couldn't change dark mode. Allow control of System Events in Privacy settings."
    }
    let now: String = runShell("/usr/bin/osascript", args: ["-e", "tell application \"System Events\" to tell appearance preferences to get dark mode"])
    return now == "true" ? "Dark mode is on." : "Dark mode is off."
}
