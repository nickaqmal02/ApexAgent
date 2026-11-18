import AVFoundation
import Foundation

// Runs each clip through three audio pipelines and writes raw 16 kHz Int16 files for Deepgram.
// OLD    = the app's current code: x20 gain, clip, keep every 3rd sample
// NEW_x1 = AVAudioConverter (filtered resample), no gain
// NEW_x4 = AVAudioConverter, x4 gain with clip
// Each clip is tested at two peak levels, with low room noise added, in 1024-frame chunks like the mic tap.

let chunk: Int = 1024
let outFormat: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

func loadSamples(_ path: String) -> ([Float], AVAudioFormat) {
    let file: AVAudioFile = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    let buf: AVAudioPCMBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: buf)
    let n: Int = Int(buf.frameLength)
    return (Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n)), file.processingFormat)
}

func prepare(_ samples: [Float], peak: Float, seed: UInt64) -> [Float] {
    let currentPeak: Float = samples.map { abs($0) }.max() ?? 1
    var rng: UInt64 = seed
    let pad: [Float] = Array(repeating: 0, count: 24000)          // 0.5 s of silence after the phrase
    return (samples + pad).map { s in
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        let noise: Float = (Float(rng >> 40) / Float(1 << 24) - 0.5) * noiseAmp
        return s / currentPeak * peak + noise
    }
}

func oldPipeline(_ x: [Float], rate: Double) -> Data {
    var out: Data = Data()
    let ratio: Double = rate / 16000.0
    var start: Int = 0
    while start < x.count {
        let frame: [Float] = Array(x[start..<min(start + chunk, x.count)])
        let count: Int = Int(Double(frame.count) / ratio)
        for i in 0..<count {
            let idx: Int = Int(Double(i) * ratio)
            if idx < frame.count {
                let v: Float = max(-1, min(1, frame[idx] * 20))
                var s: Int16 = Int16(v * 32767).littleEndian
                out.append(Data(bytes: &s, count: 2))
            }
        }
        start += chunk
    }
    return out
}

func newPipeline(_ x: [Float], format: AVAudioFormat, gain: Float) -> Data {
    let converter: AVAudioConverter = AVAudioConverter(from: format, to: outFormat)!
    var out: Data = Data()
    var start: Int = 0
    while start < x.count {
        let n: Int = min(chunk, x.count - start)
        let inBuf: AVAudioPCMBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        inBuf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { inBuf.floatChannelData![0][i] = max(-1, min(1, x[start + i] * gain)) }
        let cap: AVAudioFrameCount = AVAudioFrameCount(Double(n) * 16000.0 / format.sampleRate) + 32
        let outBuf: AVAudioPCMBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap)!
        var given: Bool = false
        var err: NSError?
        _ = converter.convert(to: outBuf, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return inBuf
        }
        out.append(Data(bytes: outBuf.int16ChannelData![0], count: Int(outBuf.frameLength) * 2))
        start += chunk
    }
    return out
}

let dir: String = CommandLine.arguments[1]
let noiseAmp: Float = Float(CommandLine.arguments[2]) ?? 0.006
let levels: [(String, Float)] = [("quiet", 0.05), ("normal", 0.6)]
for i in 1...10 {
    let (raw, format) = loadSamples("\(dir)/clips/p\(i).wav")
    for (levelName, peak) in levels {
        let x: [Float] = prepare(raw, peak: peak, seed: UInt64(i * 7 + Int(peak * 100)))
        try! oldPipeline(x, rate: format.sampleRate).write(to: URL(fileURLWithPath: "\(dir)/out/p\(i)_\(levelName)_OLD.raw"))
        try! newPipeline(x, format: format, gain: 1).write(to: URL(fileURLWithPath: "\(dir)/out/p\(i)_\(levelName)_NEW_x1.raw"))
        try! newPipeline(x, format: format, gain: 4).write(to: URL(fileURLWithPath: "\(dir)/out/p\(i)_\(levelName)_NEW_x4.raw"))
    }
}
print("wrote", (try! FileManager.default.contentsOfDirectory(atPath: "\(dir)/out")).count, "files")
