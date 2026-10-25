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



