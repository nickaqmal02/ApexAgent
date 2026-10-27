import Foundation
import AVFoundation

// MARK: Voice Layer (phase 4)

nonisolated(unsafe) let audioEngine = AVAudioEngine()

@available(macOS 10.15, *)
nonisolated(unsafe) var webSocketTask: URLSessionWebSocketTask?


nonisolated(unsafe) var micMuted: Bool = false

func setMicMuted(_ muted: Bool) {
    micMuted = muted
}

@available(macOS 10.15, *)
func startVoiceRecognition() {
    // 1. set up deepgram websocket url 
    // Using nova-2 (default model)
    let urlString = "wss://api.deepgram.com/v1/listen?model=nova-2&language=en&encoding=linear16&sample_rate=16000&keywords=ApexAgent:2,Spotify:2,jev:2"
    
    guard let url = URL(string: urlString) else {
        print("❌ Invalid URL")
        return
    }

    // 2. read the api key from the environment
    let deepgramKey = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] ?? ""
    if deepgramKey.isEmpty {
        print("⚠️ DEEPGRAM_API_KEY is missing from environment!")
    } else {
        print("✅ Deepgram key loaded (\(deepgramKey.count) chars)")
    }
    
    // 3. create the websocket request
    var request = URLRequest(url: url)
    request.setValue("Token \(deepgramKey)", forHTTPHeaderField: "Authorization")

    // 4. start the websocket
    let config = URLSessionConfiguration.default
    config.waitsForConnectivity = true
    let session = URLSession(configuration: config)
    
    webSocketTask = session.webSocketTask(with: request)
    webSocketTask?.resume()
    print("🔗 WebSocket connecting...")
    
    // 5. Wait for the socket to ACTUALLY connect using a semaphore
    // This blocks the main thread until the ping succeeds, guaranteeing the socket is open.
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
    
    // Wait up to 3 seconds for the ping to complete
    if connectSemaphore.wait(timeout: .now() + 3) == .timedOut {
        print("❌ WebSocket connection timed out.")
        return
    }
    
    if !didConnect {
        return
    }
    
    print("✅ WebSocket connected!")
    receiveTranscript()

    // 6. tap the microphone
    let inputNode = audioEngine.inputNode
    let sourceFormat = inputNode.outputFormat(forBus: 0)
    
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { buffer, time in
        if micMuted { return }
        // Get the Float32 audio samples from the mic
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        
        // Downsample from 44100Hz to 16000Hz manually
        let downsampleRatio = sourceFormat.sampleRate / 16000.0
        let downsampledCount = Int(Double(frameLength) / downsampleRatio)
        
        // Convert Float32 to Int16 with gain boost
        var int16Data = Data(count: downsampledCount * 2)
        int16Data.withUnsafeMutableBytes { int16Bytes in
            let int16Buffer = int16Bytes.bindMemory(to: Int16.self)
            let gainBoost: Float = 20.0  // Boost the quiet mic
            
            for i in 0..<downsampledCount {
                let sourceIndex = Int(Double(i) * downsampleRatio)
                if sourceIndex < frameLength {
                    let boostedSample = max(-1.0, min(1.0, channelData[sourceIndex] * gainBoost))
                    int16Buffer[i] = Int16(boostedSample * 32767.0)
                }
            }
        }
        
        // Send to Deepgram
        webSocketTask?.send(.data(int16Data)) { error in
            if let error = error {
                print("❌ WebSocket send error: \(error.localizedDescription)")
            }
        }
    }
    
    // 7. Prepare and start the engine
    do {
        audioEngine.prepare()
        try audioEngine.start()
        print("🎙️ Voice recognition started. Speak now.")
    } catch {
        print("❌ Failed to start the audio engine: \(error)")
    }
}

func stopVoiceRecognition() {
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()

    // Close the websocket cleanly
    if #available(macOS 10.15, *) {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }
    print("🛑 Voice recognition stopped.")
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
            print("❌ WebSocket receive error: \(error.localizedDescription)")
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
        print("\n🗣️ You said: \(transcript)")
        print("🧠 Processing...")
        
        // RUN LLM ON A BACKGROUND THREAD SO WE DON'T BLOCK THE WEBSOCKET
        // NOTE: RUN LLM VIA THE FIFO QUEUE
        askLLM(transcript) { _ in }
    } else {
        // PARTIAL transcript — print it inline so you see it live
        // \r returns to the start of the line, overwriting the previous partial
        print("\r🎤 Hearing: \(transcript)                   ", terminator: "")
        FileHandle.standardOutput.write(Data())
    }
}
