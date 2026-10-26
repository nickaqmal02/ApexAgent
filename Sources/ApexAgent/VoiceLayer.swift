import Foundation
import AVFoundation

// MARK: Voice Layer (phase 4)

// MARK: Audio Engine is the heart of the voice pipeline
nonisolated(unsafe) let audioEngine = AVAudioEngine()

// NOTE: WEB SOCKET CONNECTION TO DEEPGRAM
@available(macOS 10.15, *)
nonisolated(unsafe) var webSocketTask: URLSessionWebSocketTask?

@available(macOS 10.15, *)
func startVoiceRecognition() {
    // 1. set up deepgram websocket url
    let urlString = "wss://api.deepgram.com/v1/listen?model=nova-2&language=en&keywords=ApexAgent:2,Spotify:2,jev:2"
    guard let url = URL(string: urlString) else { return }

    // 2. read the api key from the environment
    let deepgramKey = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] ?? ""

    // 3. create the websocket request
    var request = URLRequest(url: url)
    request.setValue("Token \(deepgramKey)", forHTTPHeaderField: "Authorization")

    // 4. start the websocket
    webSocketTask = URLSession.shared.webSocketTask(with: request)
    webSocketTask?.resume()

    receiveTranscript()

    // 5. tap the microphone
    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)

    // NOTE: EVERYTIME THE MIC PRODUCES AUDIO, RUN THIS CLOSURE
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, time in
        // Convert the audio buffer to raw bytes
        let audioBufferList = buffer.audioBufferList
        let audioData = withUnsafeBytes(of: audioBufferList) { Data($0) }

        // 7. Send the raw bytes to deepgram over websocket
        webSocketTask?.send(.data(audioData)) { error in
            if let error = error {
                print("❌ WebSocket send error: \(error)")
            }
        }
    }

    // 5. Prepare and start the engine
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
                // Parse the deepgram JSON
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let channel = json["channel"] as? [String: Any],
                   let alternative = channel["alternatives"] as? [[String: Any]],
                   let transcript = alternative.first?["transcript"] as? String {

                    // Check if it's a final transcript
                    if let isFinal = json["is_final"] as? Bool, isFinal {
                        if !transcript.isEmpty {
                            print("\n🗣️ You said: \(transcript)")
                            // TODO: SEND THIS TRANSCRIPT TO ASK LLM
                        }
                    }
                }
            case .string(let text):
                print("Received text: \(text)")
            @unknown default:
                break
            }

            // Keep listening (recursive call)
            receiveTranscript()

        case .failure(let error):
            print("❌ WebSocket receive error: \(error)")
        }
    }
}
