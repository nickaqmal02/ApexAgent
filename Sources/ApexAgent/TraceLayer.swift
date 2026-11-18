import Foundation

struct TraceRecord: Codable {
      let requestId: String   // one per user input, shared by all stages
      let stage: String       // "route" | "llm" | "tool" | ...
      let model: String       // "qwen3:8b" etc.
      let route: String       // "online" | "offline"
      let durationMs: Double  // measured by the caller
      let input: String?      // user text
      let output: String?     // raw model content, before JSON parsing
      // Wall-clock time the record was created, in ms since 1970. Has a default, so existing calls don't change.
      var tsMs: Double = Date().timeIntervalSince1970 * 1000
}

let traceQueue: DispatchQueue = DispatchQueue(label: "com.apexagent.trace")

// One ID per user turn, set in askLLM.
nonisolated(unsafe) var currentRequestId: String = "none"
// The turn whose reply is being spoken right now. Speech can still be playing after the
// next turn has started (and changed currentRequestId), so the TTS timers read this one.
nonisolated(unsafe) var speechRequestId: String = "none"

func msSince(_ start: UInt64) -> Double {
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func logTrace(_ record: TraceRecord){
    traceQueue.async {
        // 1. turn the record into bytes. Which encoder to use? what does encode return ?
        guard var data = try? JSONEncoder().encode(record) else { return }
        // 2. each record must end with a newline.
        data.append(contentsOf: "\n".data(using: .utf8)!)

        let logPath: String = "logs/latency.jsonl"

        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: Data())
        } else {
            
        }
        
        // step 4: saves a record and™ add one record's bytes to the end of an exisiting files
        let url: URL = URL(fileURLWithPath: logPath) // 1. selecting which file we want to select
        guard let handle: FileHandle = try? FileHandle(forWritingTo: url) else { return }// 2. open it for writing
        handle.seekToEndOfFile() // move the write position to the end
        handle.write(data) // write this bytes at that positions
        handle.closeFile() // close the file this is swift style
        
         

        
    }
}


