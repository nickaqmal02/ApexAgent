import AVFoundation
import Foundation

// Streaming TTS: Deepgram sends raw PCM chunks over a WebSocket, and we play them as they arrive.
// speakStreamingBlocking() returns only after the audio has finished playing, so the caller can
// keep the mic muted for the whole reply.

let streamingTTSURL: String = "wss://api.deepgram.com/v1/speak?model=aura-2-apollo-en&encoding=linear16&sample_rate=24000"

// Deepgram sends 16-bit signed little-endian mono PCM at 24 kHz; the player wants Float32.
let streamingFormat: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

nonisolated(unsafe) let streamEngine: AVAudioEngine = AVAudioEngine()
nonisolated(unsafe) let streamNode: AVAudioPlayerNode = AVAudioPlayerNode()
nonisolated(unsafe) var streamReady: Bool = false

func prepareStreamPlayback() -> Bool {
    if streamReady { return true }
    streamEngine.attach(streamNode)
    streamEngine.connect(streamNode, to: streamEngine.mainMixerNode, format: streamingFormat)
    do {
        try streamEngine.start()
    } catch {
        print("⚠️ streaming playback engine failed: \(error)")
        return false
    }
    streamNode.play()
    streamReady = true
    return true
}

// Shared state for one utterance. Callbacks run on different threads, so every field is guarded by the lock.
final class StreamState: @unchecked Sendable {
    let lock: NSLock = NSLock()
    let start: UInt64
    let done: DispatchSemaphore = DispatchSemaphore(value: 0)
    var leftover: Data = Data()   // a chunk can end mid-sample; keep the odd byte for the next chunk
    var scheduled: Int = 0
    var played: Int = 0
    var flushed: Bool = false
    var firstChunkMs: Double = -1
    var finished: Bool = false

    init(start: UInt64) {
        self.start = start
    }
}

// Speaks `text` through the streaming connection. Returns true if audio was played,
// false if the stream failed before any audio arrived (the caller should then fall back).
@available(macOS 10.15, *)
func speakStreamingBlocking(_ text: String) -> Bool {
    guard prepareStreamPlayback() else { return false }
    let key: String = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] ?? ""
    guard !key.isEmpty, let url = URL(string: streamingTTSURL) else {
        print("⚠️ streaming TTS: missing key or URL")
        return false
    }

    var request: URLRequest = URLRequest(url: url)
    request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
    let socket: URLSessionWebSocketTask = URLSession.shared.webSocketTask(with: request)
    socket.resume()

    let state: StreamState = StreamState(start: DispatchTime.now().uptimeNanoseconds)
    let speakJSON: Data = (try? JSONSerialization.data(withJSONObject: ["type": "Speak", "text": text])) ?? Data()
    socket.send(.string(String(decoding: speakJSON, as: UTF8.self))) { _ in }
    socket.send(.string("{\"type\":\"Flush\"}")) { _ in }

    receiveStream(socket: socket, state: state)

    // Block until the last buffer has played, or give up after 30 s
    if state.done.wait(timeout: .now() + 30) == .timedOut {
        print("⚠️ streaming TTS timed out after 30 s")
    }

    state.lock.lock()
    let gotAudio: Bool = state.firstChunkMs >= 0
    state.lock.unlock()
    return gotAudio
}

@available(macOS 10.15, *)
private func receiveStream(socket: URLSessionWebSocketTask, state: StreamState) {
    socket.receive { result in
        switch result {
        case .success(let message):
            switch message {
            case .data(let bytes):
                state.lock.lock()
                if state.firstChunkMs < 0 { state.firstChunkMs = msSince(state.start) }
                state.lock.unlock()
                scheduleChunk(bytes, state: state)
            case .string(let text):
                if text.contains("Flushed") {
                    // Every audio frame has arrived before this message
                    state.lock.lock()
                    state.flushed = true
                    let allPlayed: Bool = state.played == state.scheduled
                    state.lock.unlock()
                    socket.cancel(with: .goingAway, reason: nil)
                    if allPlayed { finishStream(state) }
                    return
                }
            @unknown default:
                break
            }
            receiveStream(socket: socket, state: state)
        case .failure(let error):
            print("⚠️ streaming TTS receive failed: \(error.localizedDescription)")
            finishStream(state)
        }
    }
}

@available(macOS 10.15, *)
private func scheduleChunk(_ incoming: Data, state: StreamState) {
    state.lock.lock()
    let bytes: Data = state.leftover + incoming
    let usable: Int = bytes.count - (bytes.count % 2)
    state.leftover = Data(bytes[usable...])
    state.scheduled += 1
    state.lock.unlock()

    let frames: Int = usable / 2
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: streamingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
        // Nothing playable in this chunk: count it as played so the end condition still holds
        state.lock.lock()
        state.played += 1
        let allPlayed: Bool = state.flushed && state.played == state.scheduled
        state.lock.unlock()
        if allPlayed { finishStream(state) }
        return
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    guard let out = buffer.floatChannelData?[0] else { return }

    bytes.withUnsafeBytes { raw in
        for i in 0..<frames {
            let lo: UInt16 = UInt16(raw[2 * i])
            let hi: UInt16 = UInt16(raw[2 * i + 1])
            out[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768.0
        }
    }

    streamNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
        state.lock.lock()
        state.played += 1
        let allPlayed: Bool = state.flushed && state.played == state.scheduled
        state.lock.unlock()
        if allPlayed { finishStream(state) }
    }
}

// Logs the two numbers that matter, then releases the waiting caller.
private func finishStream(_ state: StreamState) {
    state.lock.lock()
    if state.finished {
        state.lock.unlock()
        return
    }
    state.finished = true
    let firstMs: Double = state.firstChunkMs
    let totalMs: Double = msSince(state.start)
    state.lock.unlock()

    print("🔊 streaming TTS: first chunk \(Int(firstMs)) ms, played out at \(Int(totalMs)) ms")
    logTrace(TraceRecord(requestId: speechRequestId, stage: "tts_first_chunk", model: "deepgram-aura-2-stream", route: "online", durationMs: firstMs, input: nil, output: nil))
    logTrace(TraceRecord(requestId: speechRequestId, stage: "tts_stream_total", model: "deepgram-aura-2-stream", route: "online", durationMs: totalMs, input: nil, output: nil))
    state.done.signal()
}
