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

func handleBattery() {
    // pmset -g batt
    let result = runShell("/usr/bin/pmset", args: ["-g", "batt"])
    print(" \(result)")
}

func handleListApps() {
    let result = runShell("/bin/ps", args: ["aux"])
    print(" \(result)")
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




