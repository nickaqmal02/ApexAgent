import Foundation

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
