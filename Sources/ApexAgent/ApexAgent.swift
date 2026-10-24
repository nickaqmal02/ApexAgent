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
You are ApexAgent, a macOS assistant.
User: Nik, final-year CS student at UPNM. Casual tone, direct, no fluff. Uses vim, terminal-first. Building ApexAgent — a voice-driven macOS agent in Swift.

available tools:
- open_app: Launch an application. args: {"name": "app name"}
- quit_app: Quit an application. args: {"name": "app name"}
- set_volume: Set system volume 0-100. args: {"level": number}
- battery: Read battery status. No args needed.
- list_apps: List running apps. No args needed.

RULE: When the user asks for an action, DO NOT ask for clarification. Pick a reasonable default and execute. For example, if they say "increase volume" without a number, use 75.

If the user wants an action, respond with ONLY this JSON:
{"tool": "tool_name", "args": {...}, "reply": "short confirmation, casual tone"}

If the user is just chatting, respond with:
{"tool": null, "reply": "your response, casual tone, reference things you know about Nik"}
"""

let ollamaURL = "http://localhost:11434/api/chat"
let ollamaModel = "qwen3:8b"

// MARK: Cloud LLM config (phase 3)
let glmURL = "https://rootsys.cloud/v1/chat/completions"
// API key is loaded in main() AFTER loadEnv() runs
nonisolated(unsafe) var glmAPIKey = ""

nonisolated(unsafe) var conversationHistory: [[String: String]] = [] //MARK: this will tell the swift that I know that this is unsafe I will handle this
let MAX_HISTORY = 10

// the shape of the LLM's json responses
// args values can be String or Int, so we use a custom decoder
struct LLMResponse: Decodable {
    let tool: String?
    let args: [String: AnyCodable]?
    let reply: String?
}

// Wrapper that accepts both String and Int values from JSON
enum AnyCodable: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else { self = .string("") }
    }
}

// MARK: Ask Ollama - sends user input to local LLM, gets JSON back
func askOllama(_ userInput: String) -> LLMResponse? {
    guard let url = URL(string: ollamaURL) else { return nil }

    let startTime = Date()

    // Adding user's message to history BEFORE sending
    conversationHistory.append(["role": "user", "content": userInput])

    // trim history if too long (keep only last max history messages)
    if conversationHistory.count > MAX_HISTORY {
        conversationHistory = Array(conversationHistory.suffix(MAX_HISTORY))
    }

    // BUILD MESSAGES: SYSTEM PROMPT + FULL CONVERSATION HISTORY
    var messages: [[String: Any]] = [
        ["role": "system", "content": systemPrompt]
    ]

    for msg in conversationHistory {
        messages.append(msg)
    }
    // build the request body
    let body: [String: Any] = [
        "model": ollamaModel,
        "stream": false,
        "think": false,
        "format": "json",
        "messages": messages,
        "options": ["temperature": 0.1]
    ]

    // CREATE POST request
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 60
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    // The semaphore - makes aync URLSesson syncrhonous
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: LLMResponse? // WARNING: fixing the swiftt 6 warning

    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        // check for the network errors
        guard let data = data, error == nil else {
            print("Network error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        //check HTTP status
        if let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode != 200 {
                print("Ollama returned HTTP \(httpResponse.statusCode)")
                return
            }

        // parse the Ollama's reponse
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = json["message"] as? [String: Any],
                let content = message["content"] as? String else {
            print("Can't parse Ollama reponse")
            return
        }

        // content is a json string like 
        // decode it into out LLMResponse struct
        guard let contentData = content.data(using: .utf8) else { 
            print("DEBUG: can't convert content to Data")
            return 
        }
        do {
            result = try JSONDecoder().decode(LLMResponse.self, from: contentData)
        } catch {
            print("DEBUG: decode failed: \(error)")
            print("DEBUG: content was: \(content)")
        }
    }.resume()

    // block here until the network call finishes
    semaphore.wait()

    let elapsed = Date().timeIntervalSince(startTime)
    print("Response time: \(String(format: "%.2f", elapsed))s")

    return result
}

// MARK: NETWORK CHECKER (PHASE 3)
// Don't ping DeepSeek with HEAD — it returns 401 (no auth on HEAD).
// Instead, try a simple URL that doesn't need auth.
func isOnline() -> Bool {
    guard let url = URL(string: "https://www.google.com") else { return false }
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var online = false

    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 3

    URLSession.shared.dataTask(with: request) { _, response, error in
        defer { semaphore.signal() }
        if error == nil { online = true }
    }.resume()

    semaphore.wait()
    return online
}

// MARK - ASK GLM (CLOUD LLM) - DEEPSEEK API, OPEN-AI COMPATIBLE
func askGLM(_ userInput: String) -> LLMResponse? {
    guard let url = URL(string: glmURL) else { return nil }

    let startTime = Date()

    // build messages (same as Ollama - system + history)
    var messages: [[String: Any]] = [
        ["role": "system", "content": systemPrompt]
    ]

    for msg in conversationHistory {
        messages.append(msg)
    }

    // MARK: - SETUP THE BODY PARAMETER OF THE MODEL
    let body: [String: Any] = [
        "model": "glm-5.2",
        "stream": false,
        "think": false,
        "response_format": ["type": "json_object"],
        "messages": messages,
        "temperature": 0.1
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(glmAPIKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 30
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: LLMResponse?
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        guard let data = data, error == nil else {
            print("❌ GLM network error: \(error?.localizedDescription ?? "unknown")")
            return
        }
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            print("❌ GLM HTTP \(httpResponse.statusCode)")
            return
        }
        // DeepSeek/OpenAI format: {"choices":[{"message":{"content":"..."}}]}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            print("❌ Can't parse GLM response")
            return
        }
        // Save to history
        conversationHistory.append(["role": "assistant", "content": content])
        // Decode content → LLMResponse (same as Ollama)
        guard let contentData = content.data(using: .utf8) else { return }
        do {
            result = try JSONDecoder().decode(LLMResponse.self, from: contentData)
        } catch {
            print("DEBUG GLM: decode failed: \(error)")
            print("DEBUG GLM: content was: \(content)")
        }
    }.resume()
    semaphore.wait()
    let elapsed = Date().timeIntervalSince(startTime)
    print("⏱️ GLM Response time: \(String(format: "%.2f", elapsed))s")
    return result
}

// MARK: The Router - picks cloud or local based on connectivity
func askLLM(_ userInput: String) -> LLMResponse? {
    // add user message to history (shared by both providers)
    conversationHistory.append(["role": "user", "content": userInput])

    if conversationHistory.count > MAX_HISTORY {
        conversationHistory = Array(conversationHistory.suffix(MAX_HISTORY))
    }

    if isOnline() {
        print("online -> trying GLM (cloud)")
        if let decision = askGLM(userInput) {
            return decision
        }

        print("GLM failed -> falling back to ollama ( local )")
    } else {
        print("offline -> using Ollama [local]")
    }

    // NOTE: FALLBACK 
    return askOllamaNoDoubleAdd(userInput)
}

// MARK: - ASK OLLAMA WITHOUT RE-ADDING USER MESSAGE
func askOllamaNoDoubleAdd(_ userInput: String) -> LLMResponse? {
    guard let url = URL(string: ollamaURL) else { return nil }
    let startTime = Date()
    var messages: [[String: Any]] = [
        ["role": "system", "content": systemPrompt]
    ]
    for msg in conversationHistory {
        messages.append(msg)
    }
    let body: [String: Any] = [
        "model": ollamaModel,
        "stream": false,
        "think": false,
        "format": "json",
        "messages": messages,
        "options": ["temperature": 0.1]
    ]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 60
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: LLMResponse?
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        guard let data = data, error == nil else {
            print("Network error: \(error?.localizedDescription ?? "unknown")")
            return
        }
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            print("Ollama returned HTTP \(httpResponse.statusCode)")
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            print("Can't parse Ollama response")
            return
        }
        conversationHistory.append(["role": "assistant", "content": content])
        guard let contentData = content.data(using: .utf8) else { return }
        do {
            result = try JSONDecoder().decode(LLMResponse.self, from: contentData)
        } catch {
            print("DEBUG: decode failed: \(error)")
            print("DEBUG: content was: \(content)")
        }
    }.resume()
    semaphore.wait()
    let elapsed = Date().timeIntervalSince(startTime)
    print("⏱️ Ollama Response time: \(String(format: "%.2f", elapsed))s")
    return result
}

// MARK: Execute llm decision - routes intnet to the right handler
func executeDecision(_ decision: LLMResponse) {
    
    // no tool just conversation
    guard let tool = decision.tool else {
        if let reply = decision.reply {
            print("Agent replies... \(reply)")
        }
        return
    }

    // route to handler
    switch tool {
        case "open_app":
            if let name = decision.args?["name"]?.stringValue {
                handleOpen(name)
            }
        case "quit_app":
            if let name = decision.args?["name"]?.stringValue {
                handleQuit(name)
            }
    case "set_volume":
        if let levelStr = decision.args?["level"]?.stringValue, let level = Int(levelStr) {
            handleVolume(level)
        }
    case "battery":
        handleBattery()
    case "list_apps":
        handleListApps()
    default:
        print("❌ Unknown tool from LLM: \(tool)")
    }
    // Print the LLM's reply
    if let reply = decision.reply {
        print("🤖 \(reply)")
    }
    
}


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
                print("Memory cleared.")
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


