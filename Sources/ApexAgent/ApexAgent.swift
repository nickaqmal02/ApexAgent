// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation
// TODO:
// FIXME:
// !!!: Important: 

// ???: Question: 
// WARNING:
// NOTE: 

// MARK: setup the prompt for llm PHASE2
let systemPrompt = """
You are ApexAgent, a macOS assistant running locally.
available tools:
- open_app: Launch an application. args: {"name": "app name"}
- quit_app: Quit an application. args: {"name": "app name"}
- set_volume: Set system volume 0-100. args: {"level": number}
-battery: Read battery status. No args needed.
- list_apps: List running  apps. No args needed

If the user wants an action, respond with only this JSON:
If the user wants an action, respond with ONLY this JSON:
{"tool": "tool_name", "args": {...}, "reply": "short confirmation"}

If the user is just chatting, respond with:
{"tool": null, "reply": "your response"}
"""

let ollamaURL = "http://localhost:1134/api/chat"
let ollamaModel = "qwen3:8b"

// the shape of the LLM's json responses



// MARK: COLOR SETUP
let colorCyan = "\u{001B}[36m"
let colorBold = "\u{001B}[1m"
let reset = "\u{001B}[0m"

struct Command {
    let name: String
    let description: String
    let usage: String
    let category: Category

    enum Category {
        case system
        case apps
        case utility // help, exit
    }
}

// MARK: Command Registry the combination [Array + Dictionary]

let commandRegistry: [Command] = [
    Command(name: "open", description: "Launch an app", usage: "open <appname>", category: .apps),
    Command(name: "quit", description: "Quit an app", usage: "quit <appname>", category: .apps),
    Command(name: "volume", description: "set volume 0-100", usage: "volume <0-100>", category: .system),
    Command(name: "battery", description: "Show battery status", usage: "battery", category: .system),
    Command(name: "list", description: "List running apps", usage: "list apps", category: .apps),
    Command(name: "help", description: "Show this help", usage: "help", category: .utility),
    Command(name: "exit", description: "Quit the ApexAgent", usage: "exit", category: .utility),
]

// MARK: Shell runner section

func runShell(_ command: String, args: [String] = []) -> String{
    let task = Process()
    task.executableURL = URL(fileURLWithPath: command)
    task.arguments = args

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe

    do {
        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } catch {
        return "Error: \(error.localizedDescription)"
    }
}

// MARK: - COMMAND HANDLERS
func handleOpen(_ appName: String) {
    // for example open -a spotify
    let result = runShell("/usr/bin/open", args: ["-a", appName])
    if result.isEmpty {
        print(" Opened \(appName)")
    }else{
        print(" \(appName) - \(result)")
    }
}

func handleQuit(_ appName: String) {
    // osascript -e 'tell application spotify to quit'
    let script = "tell application \"\(appName)\" to quit"
    let result = runShell("/usr/bin/osascript", args: ["-e", script])
    if result.isEmpty {
        print("Quit \(appName)")
    } else {
        print(" \(appName) quit")
    }
}

// definition
func handleVolume(_ level: Int) {
    
    let clamped = max(0, min(100, level))

    _ = runShell("/usr/bin/osascript", args: ["-e", "set volume output volume \(clamped)"])
    print(" volume set to \(clamped)")
}
func handleBattery() {
    // pmset -g batt
    let result = runShell("/usr/bin/pmset", args: ["-g", "batt"])
    print("🔋 \(result)")
}

func handleListApps() {
    // ps.aux - shows all running processes
    let result = runShell("/bin/ps", args: ["aux"])
    print(result)
}

// MARK: - Input Parser — splits "open spotify" into ("open", ["spotify"])
func parseInput(_ input: String) -> (command: String, args: [String]) {
    let parts = input.split(separator: " ").map { String($0) }
    guard let first = parts.first else {
        return ("", [])
    }
    let args = Array(parts.dropFirst())
    return (first, args)
}

// MARK: - Help — iterates the command registry
func printHelp() {
    print("\nCommands:")
    for cmd in commandRegistry {
        print("  \(cmd.usage.padding(toLength: 20, withPad: " ", startingAt: 0)) \(cmd.description)")
    }
    print()
}

// MARK: - Main Door when we first run our program

@main
struct ApexAgent {
    static func main() {
        printBanner()

        // REPL = READ EVALUATE PRINT LOOP
        //
        while true {
            //1. Print prompt
            print("\(colorCyan)\(colorBold)ApexAgent>\(reset) ", terminator: "")

            //2. Read Input ()
            guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                continue
            }

            // 3. We shall handle empty input
            if input.isEmpty {
                continue
            }

            // 4 parse
            let (cmd, args) = parseInput(input)

            switch cmd {
            case "open":
                guard !args.isEmpty else {
                    print("Usage: open <appname>")
                    break
                }
                handleOpen(args[0])

            case "quit":
                guard !args.isEmpty else {
                    print("Usage: quit <appname>")
                    break
                }
                handleQuit(args[0])

            case "volume":
                guard !args.isEmpty else {
                    print("Usage: volume <0-100>")
                    break
                }

                // convert "50" to Int
                if let level = Int(args[0]) {
                    handleVolume(level)
                }else{
                    print("Volume must be a number, not \(args[0])")
                }

            case "battery":
                handleBattery()
            case "list":
                handleListApps()

            case "help":
                printHelp()

            case "exit":
                print("😊 Goodbye Dude")
                return
            default:
                print("Uknown command: \(cmd). Type 'help' for commands.")
            }
        }
    }

    static func printBanner() {
        print("""

        ╔══════════════════════════════════════╗
        ║          ApexAgent v0.1               ║
        ║   Your Mac, controlled by Swift       ║
        ╚══════════════════════════════════════╝
        Type 'help' for commands. Type 'exit' to quit.

        """)
    }
}


