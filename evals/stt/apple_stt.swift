import Foundation
import Speech

// Transcribes each WAV with Apple's on-device recognizer and prints one JSON line per file.
let files: [String] = Array(CommandLine.arguments.dropFirst())

let authDone: DispatchSemaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
SFSpeechRecognizer.requestAuthorization { status in
    authStatus = status
    authDone.signal()
}
if authDone.wait(timeout: .now() + 60) == .timedOut {
    print("{\"error\":\"authorization timed out\"}")
    exit(2)
}
guard authStatus == .authorized else {
    print("{\"error\":\"not authorized, status \(authStatus.rawValue)\"}")
    exit(3)
}

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
    print("{\"error\":\"no en-US recognizer\"}")
    exit(4)
}
recognizer.queue = OperationQueue()   // callbacks off the main thread, which we block below
print("{\"on_device_supported\":\(recognizer.supportsOnDeviceRecognition)}")

for path in files {
    let request: SFSpeechURLRecognitionRequest = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    request.contextualStrings = ["ApexAgent", "Spotify", "exit", "quit"]   // same boost words as Deepgram

    let done: DispatchSemaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var text: String = ""
    nonisolated(unsafe) var errorText: String = ""
    let start: UInt64 = DispatchTime.now().uptimeNanoseconds
    nonisolated(unsafe) var elapsedMs: Double = -1

    let task: SFSpeechRecognitionTask = recognizer.recognitionTask(with: request) { result, error in
        if let result = result, result.isFinal {
            text = result.bestTranscription.formattedString
            elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            done.signal()
        } else if let error = error {
            errorText = error.localizedDescription
            elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            done.signal()
        }
    }
    if done.wait(timeout: .now() + 30) == .timedOut {
        task.cancel()
        errorText = "timed out"
    }
    let line: [String: Any] = ["file": (path as NSString).lastPathComponent, "text": text, "ms": elapsedMs, "error": errorText]
    let json: Data = try! JSONSerialization.data(withJSONObject: line)
    print(String(decoding: json, as: UTF8.self))
}
