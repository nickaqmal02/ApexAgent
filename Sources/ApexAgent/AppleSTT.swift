import AVFoundation
import Foundation
import Speech

// On-device speech recognition, selected with APEX_STT=apple. Works offline.
// Apple's live recognizer does not mark where one spoken command ends, so we treat
// 0.9 s without any change to the partial transcript as the end of the command,
// hand that text on, and start a fresh recognition request for the next one.

let appleEndOfSpeechMs: Double = 900

nonisolated(unsafe) var appleRecognizer: SFSpeechRecognizer?
nonisolated(unsafe) var appleRequest: SFSpeechAudioBufferRecognitionRequest?
nonisolated(unsafe) var appleTask: SFSpeechRecognitionTask?
nonisolated(unsafe) var appleText: String = ""            // latest partial transcript
nonisolated(unsafe) var appleLastChangeNs: UInt64 = 0     // when the partial last changed
nonisolated(unsafe) var appleTimer: DispatchSourceTimer?

// Recognition state is only changed on this queue
let appleQueue: DispatchQueue = DispatchQueue(label: "com.apexagent.applestt")

@available(macOS 10.15, *)
func startAppleRecognition() {
    // 1. Permission (the prompt appears once; the usage description is embedded in the binary)
    let authDone: DispatchSemaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    SFSpeechRecognizer.requestAuthorization { status in
        authStatus = status
        authDone.signal()
    }
    if authDone.wait(timeout: .now() + 30) == .timedOut || authStatus != .authorized {
        print("❌ Speech recognition is not allowed (status \(authStatus.rawValue)). Turn it on in System Settings → Privacy & Security → Speech Recognition.")
        return
    }

    // 2. On-device recognizer
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition else {
        print("❌ On-device speech recognition for English is not available on this Mac.")
        return
    }
    recognizer.queue = OperationQueue()   // results off the main thread
    appleRecognizer = recognizer
    voiceActive = true
    appleQueue.sync { beginAppleRequest() }

    // 3. Feed the mic straight in: Apple accepts the mic's own format, so no conversion is needed
    let inputNode = audioEngine.inputNode
    applyVoiceProcessingIfEnabled(inputNode)
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        if micMuted { return }   // don't feed our own spoken reply to the recognizer
        appleRequest?.append(buffer)
    }

    // 4. Check for the end of a command five times a second
    let timer: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: appleQueue)
    timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
    timer.setEventHandler { checkAppleEndOfSpeech() }
    timer.resume()
    appleTimer = timer

    do {
        audioEngine.prepare()
        try audioEngine.start()
        print("🎙️ Voice recognition started (Apple on-device). Speak now.")
        setAgentState(.listening(nil))
    } catch {
        print("❌ Failed to start the audio engine: \(error)")
    }
}

func stopAppleRecognition() {
    appleTimer?.cancel()
    appleTimer = nil
    appleRequest?.endAudio()
    appleTask?.cancel()
    appleRequest = nil
    appleTask = nil
}

// Runs on appleQueue. Starts a new recognition request for the next command.
@available(macOS 10.15, *)
private func beginAppleRequest() {
    guard let recognizer = appleRecognizer else { return }
    let request: SFSpeechAudioBufferRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.contextualStrings = ["ApexAgent", "Spotify", "exit", "quit"]   // same boost words as Deepgram
    appleRequest = request
    appleText = ""
    appleLastChangeNs = 0

    nonisolated(unsafe) let thisRequest: SFSpeechAudioBufferRecognitionRequest = request
    appleTask = recognizer.recognitionTask(with: request) { result, error in
        let text: String? = result?.bestTranscription.formattedString
        let failed: Bool = error != nil
        appleQueue.async {
            // Ignore late callbacks from a request we already finished
            guard thisRequest === appleRequest else { return }
            if let text = text, text != appleText {
                appleText = text
                setAgentState(.listening(text))
                appleLastChangeNs = DispatchTime.now().uptimeNanoseconds
                print("\r🎤 Hearing: \(text)                   ", terminator: "")
                FileHandle.standardOutput.write(Data())
            }
            if failed && voiceActive {
                // The task ended on its own (for example after a long silence)
                if !appleText.isEmpty {
                    finishAppleUtterance()
                } else {
                    appleQueue.asyncAfter(deadline: .now() + 0.3) { restartAppleRequest() }
                }
            }
        }
    }
}

// Runs on appleQueue.
@available(macOS 10.15, *)
private func checkAppleEndOfSpeech() {
    guard voiceActive, !appleText.isEmpty, appleLastChangeNs != 0 else { return }
    if msSince(appleLastChangeNs) >= appleEndOfSpeechMs {
        finishAppleUtterance()
    }
}

// Runs on appleQueue. Hands the finished command on and starts listening for the next one.
@available(macOS 10.15, *)
private func finishAppleUtterance() {
    let text: String = appleText
    let sinceLastChange: Double = msSince(appleLastChangeNs)
    restartAppleRequest()
    // Off the recognition queue, so the LLM call can't hold up listening
    DispatchQueue.global().async {
        handleFinalTranscript(text, engine: "apple-ondevice", sinceLastPartialMs: sinceLastChange)
    }
}

// Runs on appleQueue.
@available(macOS 10.15, *)
private func restartAppleRequest() {
    guard voiceActive else { return }
    appleRequest?.endAudio()
    appleTask?.cancel()
    appleRequest = nil
    appleTask = nil
    beginAppleRequest()
}
