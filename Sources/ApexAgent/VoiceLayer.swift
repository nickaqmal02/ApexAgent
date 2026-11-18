import Foundation
import AVFoundation

// MARK: Voice Layer (phase 4)

nonisolated(unsafe) let audioEngine = AVAudioEngine()

@available(macOS 10.15, *)
nonisolated(unsafe) var webSocketTask: URLSessionWebSocketTask?


nonisolated(unsafe) var micMuted: Bool = false
nonisolated(unsafe) var lastAudioSentNs: UInt64 = 0      // time of the last audio send
nonisolated(unsafe) var voiceActive: Bool = false         // true between /mic start and stop; allows reconnects
nonisolated(unsafe) var socketConnected: Bool = false     // false while reconnecting, so the tap drops audio quietly
nonisolated(unsafe) var lastPartialNs: UInt64 = 0         // when the last partial transcript arrived
nonisolated(unsafe) var voiceProcessingOn: Bool = false   // recorded with each final transcript

// Deepgram expects 16 kHz mono 16-bit PCM (linear16)
let deepgramFormat: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

func setMicMuted(_ muted: Bool) {
    micMuted = muted
}

// Opens the Deepgram listening socket and waits up to 3 s for it to answer a ping.
@available(macOS 10.15, *)
func connectDeepgramSocket() -> Bool {
    let urlString = "wss://api.deepgram.com/v1/listen?model=nova-2&language=en&encoding=linear16&sample_rate=16000&interim_results=true&keywords=ApexAgent:2,Spotify:2,jev:2,exit:3,quit:3"

    guard let url = URL(string: urlString) else {
        print("❌ Invalid URL")
        return false
    }

    let deepgramKey = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] ?? ""
    if deepgramKey.isEmpty {
        print("⚠️ DEEPGRAM_API_KEY is missing from environment!")
    } else {
        print("✅ Deepgram key loaded (\(deepgramKey.count) chars)")
    }

    var request = URLRequest(url: url)
    request.setValue("Token \(deepgramKey)", forHTTPHeaderField: "Authorization")

    let config = URLSessionConfiguration.default
    config.waitsForConnectivity = true
    let session = URLSession(configuration: config)

    webSocketTask = session.webSocketTask(with: request)
    webSocketTask?.resume()
    print("🔗 WebSocket connecting...")

    // Wait for the socket to actually connect: a ping only succeeds on an open socket
    let connectSemaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var didConnect = false

    webSocketTask?.sendPing { error in
        if let error = error {
            print("❌ WebSocket failed to connect: \(error.localizedDescription)")
        } else {
            didConnect = true
        }
        connectSemaphore.signal()
    }

    if connectSemaphore.wait(timeout: .now() + 3) == .timedOut {
        print("❌ WebSocket connection timed out.")
        return false
    }

    if !didConnect {
        return false
    }

    socketConnected = true
    print("✅ WebSocket connected!")
    return true
}

@available(macOS 10.15, *)
func startVoiceRecognition() {
    // APEX_STT=apple uses on-device recognition instead of Deepgram
    if ProcessInfo.processInfo.environment["APEX_STT"] == "apple" {
        startAppleRecognition()
        return
    }
    guard connectDeepgramSocket() else { return }
    voiceActive = true
    receiveTranscript()

    // Tap the microphone
    let inputNode = audioEngine.inputNode

    applyVoiceProcessingIfEnabled(inputNode)
    let sourceFormat = inputNode.outputFormat(forBus: 0)

    // Filtered resample from the mic rate (usually 48 kHz) to 16 kHz Int16, with no fixed gain.
    // The old code multiplied by 20 and kept every 3rd sample: that clipped loud speech,
    // amplified room noise, and folded high frequencies back into the speech band.
    // One converter for the whole session keeps its filter state continuous across chunks.
    guard let converter = AVAudioConverter(from: sourceFormat, to: deepgramFormat) else {
        print("❌ Could not create an audio converter for \(sourceFormat)")
        return
    }

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { buffer, time in
        // Reconnecting: drop the audio instead of sending into a closed socket
        if !socketConnected { return }

        if micMuted {
            // Keep the stream alive while we speak by sending silence of the same length
            let silentCount: Int = Int(Double(buffer.frameLength) / (sourceFormat.sampleRate / 16000.0))
            lastAudioSentNs = DispatchTime.now().uptimeNanoseconds
            webSocketTask?.send(.data(Data(count: silentCount * 2))) { _ in }
            return
        }

        guard let int16Data = convertForDeepgram(buffer, converter: converter) else { return }

        // Send to Deepgram
        lastAudioSentNs = DispatchTime.now().uptimeNanoseconds
        webSocketTask?.send(.data(int16Data)) { error in
            if let error = error {
                print("❌ WebSocket send error: \(error.localizedDescription)")
            }
        }
    }

    // Prepare and start the engine
    do {
        audioEngine.prepare()
        try audioEngine.start()
        print("🎙️ Voice recognition started. Speak now.")
        setAgentState(.listening(nil))
    } catch {
        print("❌ Failed to start the audio engine: \(error)")
    }
}

// Converts one mic buffer to 16 kHz Int16 bytes. Returns nil if nothing was produced.
func convertForDeepgram(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) -> Data? {
    let capacity: AVAudioFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / buffer.format.sampleRate) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: deepgramFormat, frameCapacity: capacity) else { return nil }

    nonisolated(unsafe) var given: Bool = false
    // The input block runs synchronously inside convert(), so this capture is not shared across threads
    nonisolated(unsafe) let inputBuffer: AVAudioPCMBuffer = buffer
    var conversionError: NSError?
    let status: AVAudioConverterOutputStatus = converter.convert(to: out, error: &conversionError) { _, inputStatus in
        if given {
            inputStatus.pointee = .noDataNow
            return nil
        }
        given = true
        inputStatus.pointee = .haveData
        return inputBuffer
    }

    if status == .error {
        print("❌ audio conversion failed: \(conversionError?.localizedDescription ?? "unknown")")
        return nil
    }
    guard out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return nil }
    return Data(bytes: samples, count: Int(out.frameLength) * 2)
}

func stopVoiceRecognition() {
    // Mark the session as stopped first, so the socket closing below does not trigger a reconnect
    voiceActive = false
    socketConnected = false
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    stopAppleRecognition()

    // Close the websocket cleanly
    if #available(macOS 10.15, *) {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }
    print("🛑 Voice recognition stopped.")
    setAgentState(.idle)
}

// Retries the connection after 1, 2, 4, 8 and 8 seconds, then gives up.
@available(macOS 10.15, *)
func scheduleReconnect(attempt: Int) {
    let delay: Double = min(8.0, pow(2.0, Double(attempt - 1)))
    print("🔁 Reconnecting to Deepgram in \(Int(delay)) s (attempt \(attempt) of 5)")
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
        guard voiceActive else { return }
        if connectDeepgramSocket() {
            logTrace(TraceRecord(requestId: UUID().uuidString, stage: "stt_reconnect", model: "deepgram-nova-2", route: "online", durationMs: Double(attempt), input: nil, output: nil))
            receiveTranscript()
        } else if attempt < 5 {
            scheduleReconnect(attempt: attempt + 1)
        } else {
            print("❌ Could not reconnect after 5 attempts. Press ENTER, then run /mic again.")
        }
    }
}

// This function loops forever, listening for JSON transcripts from Deepgram
@available(macOS 10.15, *)
func receiveTranscript() {
    webSocketTask?.receive { result in
        switch result {
        case .success(let message):
            switch message {
            case .data(let data):
                processDeepgramJSON(data)
            case .string(let text):
                if let data = text.data(using: .utf8) {
                    processDeepgramJSON(data)
                }
            @unknown default:
                break
            }

            // Keep listening (recursive call)
            receiveTranscript()

        case .failure(let error):
            socketConnected = false
            // A stop we asked for is not a drop
            guard voiceActive else { return }

            let nsError: NSError = error as NSError
            let closeCode: Int = webSocketTask?.closeCode.rawValue ?? -1
            let closeReason: String = webSocketTask?.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
            let sinceAudioMs: Double = lastAudioSentNs == 0 ? -1 : msSince(lastAudioSentNs)
            print("❌ WebSocket receive error: \(error.localizedDescription)")
            print("   details: domain=\(nsError.domain) code=\(nsError.code) closeCode=\(closeCode) reason=\(closeReason) msSinceLastAudio=\(Int(sinceAudioMs))")
            logTrace(TraceRecord(requestId: UUID().uuidString, stage: "stt_socket_closed", model: "deepgram-nova-2", route: "online", durationMs: sinceAudioMs, input: nil, output: "code=\(nsError.code) closeCode=\(closeCode) reason=\(closeReason)"))
            scheduleReconnect(attempt: 1)
        }
    }
}

// Helper function to parse the JSON and route the transcript
@available(macOS 10.15, *)
func processDeepgramJSON(_ data: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let channel = json["channel"] as? [String: Any],
          let alternative = channel["alternatives"] as? [[String: Any]],
          let transcript = alternative.first?["transcript"] as? String else {
        return
    }

    if transcript.isEmpty { return }

    let isFinal = (json["is_final"] as? Bool ?? false)

    if isFinal {
        let sinceLastPartial: Double = lastPartialNs == 0 ? -1 : msSince(lastPartialNs)
        lastPartialNs = 0
        handleFinalTranscript(transcript, engine: "deepgram-nova-2", sinceLastPartialMs: sinceLastPartial)
    } else {
        lastPartialNs = DispatchTime.now().uptimeNanoseconds
        setAgentState(.listening(transcript))
        // PARTIAL transcript — print it inline so you see it live
        // \r returns to the start of the line, overwriting the previous partial
        print("\r🎤 Hearing: \(transcript)                   ", terminator: "")
        FileHandle.standardOutput.write(Data())
    }
}

// Turns on macOS voice processing (noise suppression, echo cancellation, auto level) when
// APEX_VOICE_PROCESSING=1. Must run before reading the mic format, because it can change it.
func applyVoiceProcessingIfEnabled(_ inputNode: AVAudioInputNode) {
    guard ProcessInfo.processInfo.environment["APEX_VOICE_PROCESSING"] == "1" else { return }
    do {
        try inputNode.setVoiceProcessingEnabled(true)
        voiceProcessingOn = true
        print("🎛️ Voice processing ON (noise suppression, echo cancellation, auto level)")
    } catch {
        print("⚠️ Voice processing could not be enabled: \(error.localizedDescription)")
    }
}

// Shared by both recognizers: log the transcript, handle a spoken exit, otherwise send it to the LLM.
// sinceLastPartialMs is the wait between the recognizer's last partial update and this final text.
func handleFinalTranscript(_ transcript: String, engine: String, sinceLastPartialMs: Double) {
    print("\n🗣️ You said: \(transcript)")
    print("🧠 Processing...")

    logTrace(TraceRecord(requestId: UUID().uuidString, stage: "stt_final", model: engine, route: engine == "apple-ondevice" ? "offline" : "online", durationMs: sinceLastPartialMs, input: transcript, output: "voice_processing=\(voiceProcessingOn ? "on" : "off")"))

    // Voice exit, handled before the LLM
    if isExitPhrase(transcript) {
        stopVoiceRecognition()
        print("😊 Goodbye Dude")
        exit(0)
    }

    askLLM(transcript) { _ in }
}

// True for short requests to close ApexAgent itself, spoken or typed:
// "exit", "quit apex agent", "close this application", "stop listening".
// Every word besides the verb must refer to ApexAgent or be filler, so requests that name
// another app ("quit chrome", "close spotify application") go to the LLM instead of closing us.
func isExitPhrase(_ text: String) -> Bool {
    let cleaned: String = String(text.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " })
    let words: [String] = cleaned.split(separator: " ").map(String.init)
    guard !words.isEmpty, words.count <= 5 else { return false }

    let verbs: Set<String> = ["exit", "quit", "close", "stop", "shut"]
    let pointsAtUs: Set<String> = ["application", "app", "apex", "agent", "apexagent", "listening", "yourself", "program"]
    let filler: Set<String> = ["this", "the", "please", "now", "down"]

    guard words.contains(where: { verbs.contains($0) }) else { return false }
    let others: [String] = words.filter { !verbs.contains($0) }
    guard others.allSatisfy({ pointsAtUs.contains($0) || filler.contains($0) }) else { return false }

    // "exit" and "quit" alone mean us; "close", "stop" and "shut" alone are too vague (stop the music?)
    if words.contains("exit") || words.contains("quit") {
        return true
    }
    return others.contains(where: { pointsAtUs.contains($0) })
}
