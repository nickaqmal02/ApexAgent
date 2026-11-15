import Foundation

struct TraceRecord: Codable {
      let requestId: String   // one per user input, shared by all stages
      let stage: String       // "route" | "llm" | "tool" | ...
      let model: String       // "qwen3:8b" etc.
      let route: String       // "online" | "offline"
      let durationMs: Double  // measured by the caller
      let input: String?      // user text
      let output: String?     // raw model content, before JSON parsing
}

let traceQueue: DispatchQueue = DispatchQueue(label: "com.apexagent.trace")

func logTrace(_ record: TraceRecord){
    traceQueue.async {
        // 1. turn the record into bytes. Which encoder to use? what does encode return ?
        let data 

        
    }
}


