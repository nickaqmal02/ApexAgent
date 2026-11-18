import Foundation

// THE FIFO QUEUE FOR THE LLM BRAIN
let brainQueue = DispatchQueue(label: "com.apexagent.brain")

let systemPrompt: String = {
    // SPM copies the "prompts" folder into the bundle, so the file is at:
    // ApexAgent_ApexAgent.bundle/prompts/system_prompt.txt
    // Try multiple paths to be safe
    let possiblePaths = [
        "prompts/system_prompt",
        "system_prompt",
    ]

    for path in possiblePaths {
        if let url = Bundle.module.url(forResource: path, withExtension: "txt"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            print("✅ System prompt loaded (\(content.count) chars) from \(path)")
            return content
        }
    }
    print("⚠️ system_prompt.txt not found! Using fallback.")
    return "You are ApexAgent, a macOS assistant. Reply with JSON: {tool, args, reply}"
}()

let ollamaURL = "http://localhost:11434/api/chat"
// Model config — changeable at runtime via commands
nonisolated(unsafe) var ollamaModel = "qwen3:8b"
nonisolated(unsafe) var thinkingEnabled = false  // qwen3 "think" parameter

// Available models for /change-model command
let availableModels = [
    "qwen3:8b": "8B params, 5GB, ~15 tok/s — good default",
    "qwen3:4b": "4B params, 2.5GB, ~30 tok/s — faster, less smart",
    "qwen2.5:3b": "3B params, 2GB, ~40 tok/s — fastest, basic",
    "llama3.2:3b": "3B params, 2GB, ~40 tok/s — Meta's small model",
]

// MARK: Cloud LLM config (phase 3)
let glmURL = "https://api.deepseek.com/v1/chat/completions"  // DeepSeek, OpenAI-compatible path
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
        "think": thinkingEnabled,
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
    let forceOffline: Bool = ProcessInfo.processInfo.environment["APEX_FORCE_OFFLINE"] == "1"
    if forceOffline { return false }
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
    // NOTE: GLM/DeepSeek does NOT support "think" parameter — only Ollama/qwen3 does
    let body: [String: Any] = [
        "model": "deepseek-chat",
        "stream": false,
        "response_format": ["type": "json_object"],
        "messages": messages,
        "temperature": 0.1,
        "max_tokens": 150
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
        // Strip markdown code blocks (GLM wraps JSON in ```json ... ```)
        var cleanContent = content
        if cleanContent.hasPrefix("```") {
            if let firstNewline = cleanContent.firstIndex(of: "\n") {
                cleanContent = String(cleanContent[cleanContent.index(after: firstNewline)...])
            }
            if cleanContent.hasSuffix("```") {
                cleanContent = String(cleanContent.dropLast(3))
            }
            cleanContent = cleanContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // GLM sometimes returns TWO JSON objects — only take the first one
        // Find the first complete JSON object by tracking brace depth
        if let firstBrace = cleanContent.firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escape = false
            var idx = firstBrace
            while idx < cleanContent.endIndex {
                let ch = cleanContent[idx]
                if escape { escape = false; idx = cleanContent.index(after: idx); continue }
                if ch == "\\" { escape = true; idx = cleanContent.index(after: idx); continue }
                if ch == "\"" { inString.toggle() }
                if !inString {
                    if ch == "{" { depth += 1 }
                    if ch == "}" {
                        depth -= 1
                        if depth == 0 {
                            // Found the first complete JSON object
                            cleanContent = String(cleanContent[firstBrace...idx])
                            break
                        }
                    }
                }
                idx = cleanContent.index(after: idx)
            }
        }
        // Decode content → LLMResponse (same as Ollama)
        cleanContent = cleanContent.replacingOccurrences(of: "\n", with: "\\n")
        guard let contentData = cleanContent.data(using: .utf8) else { return }
        do {
            result = try JSONDecoder().decode(LLMResponse.self, from: contentData)
        } catch {
            print("DEBUG GLM: decode failed: \(error)")
            print("DEBUG GLM: content was: \(cleanContent)")
        }
    }.resume()

    semaphore.wait()
    let elapsed = Date().timeIntervalSince(startTime)

    print("⏱️ GLM Response time: \(String(format: "%.2f", elapsed))s")
    return result
}

// NOTE: WE USE ROUTER FIFO - PICKS CLOUD OR LOCAL BASED ON CONNECTIVITY
// MARK: The Router - picks cloud or local based on connectivity
func askLLM(_ userInput: String, completion: @escaping @Sendable (LLMResponse?) -> Void) {
    brainQueue.async {
        let llmStart: UInt64 = DispatchTime.now().uptimeNanoseconds
        currentUserInput = userInput
        currentRequestId = UUID().uuidString
     // add user message to history (shared by both providers)
        conversationHistory.append(["role": "user", "content": userInput])

        if conversationHistory.count > MAX_HISTORY {
            conversationHistory = Array(conversationHistory.suffix(MAX_HISTORY))
        }

        var result: LLMResponse? = nil

        let online: Bool = isOnline()
        if online {
            print("online -> trying cloud LLM")
            result = askGLM(userInput)
            if result == nil {
                print("cloud LLM failed -> falling back to Ollama (local)")
            }
        } else {
            print("offline -> using Ollama [local]")
        }
        
        if result == nil {
            result = askOllama(userInput)
        }

        // execute the decision on main thread
        if let decision = result {
            DispatchQueue.global().async {
                executeDecision(decision)
            }
        } else {
            print("No response from LLM")
        }
        logTrace(TraceRecord(requestId: currentRequestId, stage: "llm", model: online ? "deepseek-chat" : ollamaModel, route: online ? "online" : "offline", durationMs: msSince(llmStart), input: userInput, output: result?.reply))
        // return result via completion handler
        completion(result)
    }
}

// MARK: - ASK OLLAMA WITHOUT llamaE-ADDING USER MESSAGE
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
        "think": thinkingEnabled,
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
    
    // no tool or empty tool = just conversation
    guard let tool = decision.tool, !tool.isEmpty else {
        if let reply = decision.reply {
            print("Agent replies... \(reply)")
            if #available(macOS 10.14, *) {
                speak(reply)
            }
        }
        return
    }

    // set when the guard rejects the tool, so the refusal is spoken instead of the LLM's claim
    var refusal: String? = nil
    // set by tools that know the real result (the time, what played), so that is spoken instead of the LLM's guess
    var toolReply: String? = nil

    // route to handler
    switch tool {
        case "open_app":
            if let name = decision.args?["name"]?.stringValue {
                if nameAppearsInInput(name) && installedAppExists(name) {
                    handleOpen(name)
                } else {
                    refusal = "I can't open \(name). Say the app name you want."
                    print("🛡️ guard: no installed app named \(name); nothing opened")
                }
            }
        case "quit_app":
            if let name = decision.args?["name"]?.stringValue {
                if nameAppearsInInput(name) && runningAppExists(name) {
                    handleQuit(name)
                } else {
                    refusal = "I didn't quit \(name). Say the app name you want to quit."
                    print("🛡️ guard: no running app named \(name); nothing quit")
                }
            }
        case "set_volume":
            if let levelStr = decision.args?["level"]?.stringValue, let level = Int(levelStr) {
                handleVolume(level)
            }
        case "audio_device":
            if let device = decision.args?["device"]?.stringValue,
                let type = decision.args?["type"]?.stringValue {
                    handleAudioDevice(device, type: type)
                }
        case "list_audio_devices":
            listAudioDevices()
        case "battery":
            handleBattery()
        case "list_apps":
            handleListApps()
        case "open_kitty":
            handleKittyWindow()
        case "get_time":
            toolReply = handleTime()
        case "media_control":
            let action: String = decision.args?["action"]?.stringValue ?? "play"
            let app: String = decision.args?["app"]?.stringValue ?? "Spotify"
            toolReply = handleMedia(action: action, app: app)
        case "open_url":
            if let url = decision.args?["url"]?.stringValue, isWebURL(url) {
                toolReply = handleOpenURL(url)
            } else {
                refusal = "I can only open web addresses."
                print("🛡️ guard: not a web URL (\(decision.args?["url"]?.stringValue ?? "none")); nothing opened")
            }
        case "set_timer":
            if let raw = decision.args?["seconds"]?.stringValue, let seconds = Double(raw), seconds >= 1 {
                toolReply = handleTimer(seconds: Int(seconds))
            } else {
                refusal = "How long should the timer be?"
            }
        case "run_shortcut":
            if let name = decision.args?["name"]?.stringValue,
               let actual = matchingShortcut(name), shortcutNamedInInput(actual) {
                toolReply = handleShortcut(actual)
            } else {
                refusal = "I couldn't find that shortcut. Say its exact name."
                print("🛡️ guard: no shortcut matching \(decision.args?["name"]?.stringValue ?? "none") in your request; nothing run")
            }
        case "screenshot":
            toolReply = handleScreenshot()
        case "lock_screen":
            toolReply = handleLockScreen()
        case "dark_mode":
            toolReply = handleDarkMode(decision.args?["mode"]?.stringValue ?? "toggle")
        default:
            // LLM hallucinated a tool — treat as conversation, print reply
            if let reply = decision.reply {
                print("🤖 \(reply)")
            } else {
                print("❌ LLM hallucinated tool: \(tool). No reply given.")
            }
        }
    // Print and SPEAK the reply: the refusal if the guard rejected the tool, otherwise the LLM's reply
    if let reply = refusal ?? toolReply ?? decision.reply {
        print("🤖 \(reply)")
        if #available(macOS 10.14, *) {
            speak(reply)
        }
    }
}
