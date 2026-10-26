// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation
// TODO:
// FIXME:
// !!!: Important: 

// ???: Question: 
// WARNING:
// NOTE: 

// MARK: - Load system prompt from text file (Phase 3)
// Context lives in prompts/system_prompt.txt, not in code.
// SPM bundles it as a resource accessible via Bundle.module.

// MARK: COLOR SETUP
let colorCyan = "\u{001B}[36m"
let colorBold = "\u{001B}[1m"
let reset = "\u{001B}[0m"

// NOTE: LOADING ENV METHOD
func loadEnv() {
    let envPath = FileManager.default.currentDirectoryPath + "/.env"
    guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else { return }

    for line in content.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        if let equalsIndex = trimmed.firstIndex(of: "=") {
            let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")

            setenv(key, value, 1)
        }
    }
}
// MARK: - Main Door when we first run our program

@main
struct ApexAgent {
    static func main() {
        loadEnv()
        glmAPIKey = ProcessInfo.processInfo.environment["GLM_API_KEY"] ?? ""
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

            let lower = input.lowercased()

            if lower == "help" {
                printHelp()
                continue
            }
            if lower == "exit" || lower == "quit" {
                print("😊 Goodbye Dude")
                return
            }
            if lower == "clear" {
                conversationHistory.removeAll()
                print("🧠 Memory cleared.")
                continue
            }

            if lower == "/mic" {
                if #available(macOS 10.15, *) {
                    startVoiceRecognition()
                    print("Press Enter to stop mic.. ")
                    _ = readLine()
                    stopVoiceRecognition()
                } else {
                    print(" Voice recognition requires macOS 10.15 or newer")
                }
                continue
            }
            // MARK: Model switching commands
            if lower.hasPrefix("/model") {
                let parts = lower.split(separator: " ")
                if parts.count < 2 {
                    print("\n📋 Available models:")
                    for (name, desc) in availableModels.sorted(by: { $0.key < $1.key }) {
                        let marker = name == ollamaModel ? " ← current" : ""
                        print("  \(name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(desc)\(marker)")
                    }
                    print("\n  Usage: /model <name>")
                } else {
                    let newModel = String(parts[1])
                    if availableModels[newModel] != nil {
                        ollamaModel = newModel
                        print("✅ Model changed to \(newModel)")
                        print("   \(availableModels[newModel] ?? "")")
                    } else {
                        print("❌ Unknown model: \(newModel)")
                        print("   Available: \(availableModels.keys.sorted().joined(separator: ", "))")
                    }
                }
                continue
            }
            
            if lower.hasPrefix("/thinking") {
                let parts = lower.split(separator: " ")
                if parts.count < 2 {
                    print("🧠 Thinking is \(thinkingEnabled ? "ON" : "OFF")")
                    print("   Usage: /thinking on  or  /thinking off")
                } else {
                    let mode = String(parts[1])
                    if mode == "on" {
                        thinkingEnabled = true
                        print("✅ Thinking ON — model will reason before answering (slower)")
                    } else if mode == "off" {
                        thinkingEnabled = false
                        print("✅ Thinking OFF — fast responses (default)")
                    } else {
                        print("❌ Usage: /thinking on  or  /thinking off")
                    }
                }
                continue
            }

            //5. everything else sends to local LLM
            print(" Your Agent thinking dude :) ")

            if let decision = askLLM(input) {
                executeDecision(decision)
            } else {
                print("No reponse from LLM.")
                print("Check: ollama serve, internet connection or even in .env file")
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


