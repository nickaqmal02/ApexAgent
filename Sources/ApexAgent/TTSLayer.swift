import Foundation
import AVFoundation

// MARK: - Text-to-Speech Layer (Phase 5)
// Hybrid approach: Deepgram Aura-2 (online) + AVSpeechSynthesizer (offline)

@available(macOS 10.14, *)
nonisolated(unsafe) let synthesizer = AVSpeechSynthesizer()
nonisolated(unsafe) var audioPlayer: AVAudioPlayer?

// The Deepgram TTS API endpoint
let deepgramTTSURL = "https://api.deepgram.com/v1/speak?model=aura-2-apollo-en"

// MARK: - Main TTS Router
// All speech goes through one serial queue, so two replies can never play at the same time.
let speechQueue: DispatchQueue = DispatchQueue(label: "com.apexagent.speech")

@available(macOS 10.14, *)
// requestId: the turn this reply belongs to. Callers that speak later (off the brain queue)
// must capture it when the reply is made, not when the audio starts.
func speak(_ text: String, requestId: String = currentRequestId) {
    speechQueue.sync {
        speechRequestId = requestId
        let startedAt: Double = Date().timeIntervalSince1970
        print(String(format: "▶ speak start %.2f: %@", startedAt.truncatingRemainder(dividingBy: 1000), String(text.prefix(40))))
        setAgentState(.speaking(text, acted: false))
        speakNow(text)
        setAgentState(restingAgentState())
        print(String(format: "■ speak end   %.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))
    }
}

@available(macOS 10.14, *)
func speakNow(_ text: String) {
    guard !text.isEmpty else { return }
    setMicMuted(true)  // mic must not hear our own voice
    
    if isOnline() {
        // Use Deepgram Aura-2 (best quality, sounds human)
        speakWithDeepgram(text)
    
    } else {
        // Fallback to macOS built-in (robot voice, but works offline)
        speakWithLocal(text)
    }

    // WARNING: UNMUTE - GIVE A TINY PAUSE SO WE DONT CATCH THE TAIL OF THE AUDIO
    Thread.sleep(forTimeInterval: 0.3)
    setMicMuted(false)
}

// MARK: - Deepgram Aura-2 TTS (Online)
@available(macOS 10.14, *)
func speakWithDeepgram(_ text: String) {
    // Streaming path first: plays as chunks arrive, returns after playback finishes
    if #available(macOS 10.15, *), speakStreamingBlocking(text) {
        return
    }
    // Make the fallback visible: which reply, and that the streaming path gave no audio
    print("↩️ streaming gave no audio, falling back to full-file download")
    logTrace(TraceRecord(requestId: speechRequestId, stage: "tts_fallback", model: "deepgram-aura-2", route: "online", durationMs: 0, input: nil, output: text))
    // Fallback: download the full MP3, then play it
    guard let url = URL(string: deepgramTTSURL) else {
        speakWithLocal(text)
        return
    }
    
    let deepgramKey = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] ?? ""
    
    // Deepgram TTS expects the text in the JSON body
    // Model goes in the query param, NOT in the body (this was a hard-won lesson from Computah)
    let body: [String: Any] = [
        "text": text
    ]
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Token \(deepgramKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 10
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    
    // We need to run this synchronously so the audio plays in order
    let ttsStart: UInt64 = DispatchTime.now().uptimeNanoseconds
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var audioData: Data? = nil
    
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        guard let data = data, error == nil else {
            print("⚠️ Deepgram TTS failed, falling back to local voice")
            return
        }
        
        // Check if response is actually audio (Deepgram returns raw MP3 bytes)
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 200 {
            audioData = data
        } else {
            // Deepgram returned an error JSON, not audio
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("⚠️ Deepgram TTS returned error: \(statusCode)")
        }
    }.resume()
    
    semaphore.wait()
    
    // tts_fetch = time from request to full MP3 download (the gap before any sound)
    logTrace(TraceRecord(requestId: speechRequestId, stage: "tts_fetch", model: "deepgram-aura-2", route: "online", durationMs: msSince(ttsStart), input: nil, output: nil))
    // If we got audio data, play it
    if let data = audioData {
        playAudioData(data)
    } else {
        // Fallback to local voice if Deepgram failed
        speakWithLocal(text)
    }
}

// MARK: - Play MP3 Data
@available(macOS 10.14, *)
func playAudioData(_ data: Data) {
    let playStart: UInt64 = DispatchTime.now().uptimeNanoseconds
    do {
        // Initialize the audio player with the MP3 data
        audioPlayer = try AVAudioPlayer(data: data)
        audioPlayer?.prepareToPlay()
        // We need to wait for playback to finish before returning
        // Otherwise the next TTS call will cut off this one
        let playbackSemaphore = DispatchSemaphore(value: 0)
        // Set a delegate to know when playback finishes
        // We use a simple polling approach instead of a delegate
        audioPlayer?.play()
        // Poll until playback finishes
        DispatchQueue.global().async {
            while audioPlayer?.isPlaying == true {
                Thread.sleep(forTimeInterval: 0.1)
            }
            playbackSemaphore.signal()
        }
        
        playbackSemaphore.wait()
        // tts_play = how long the audio itself played (length, not latency)
        logTrace(TraceRecord(requestId: speechRequestId, stage: "tts_play", model: "deepgram-aura-2", route: "online", durationMs: msSince(playStart), input: nil, output: nil))
    } catch {
        print("⚠️ Failed to play audio: \(error)")
    }
}

// MARK: - macOS Built-in TTS (Offline Fallback)
@available(macOS 10.14, *)
func speakWithLocal(_ text: String) {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utterance.rate = 0.5
    utterance.pitchMultiplier = 1.0
    synthesizer.speak(utterance)
}
