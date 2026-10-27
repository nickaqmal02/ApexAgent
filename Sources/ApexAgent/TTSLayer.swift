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
@available(macOS 10.14, *)
func speak(_ text: String) {
    guard !text.isEmpty else { return }
    
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
