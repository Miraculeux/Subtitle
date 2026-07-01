import Foundation

/// Parsed WAV metadata used to slice the audio into chunks.
struct WavInfo {
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let dataOffset: Int
    let dataSize: Int

    var bytesPerSecond: Int { sampleRate * channels * bitsPerSample / 8 }
    var duration: Double { bytesPerSecond > 0 ? Double(dataSize) / Double(bytesPerSecond) : 0 }
}

enum WavError: LocalizedError {
    case unsupported
    var errorDescription: String? { "Unsupported WAV format for chunked transcription." }
}

/// Reads a PCM WAV file and produces standalone WAV chunks for time ranges.
struct WavReader {
    let data: Data
    let info: WavInfo

    init(url: URL) throws {
        let d = try Data(contentsOf: url)
        data = d
        info = try WavReader.parse(d)
    }

    static func parse(_ data: Data) throws -> WavInfo {
        func ascii(_ o: Int, _ n: Int) -> String {
            guard o + n <= data.count else { return "" }
            return String(bytes: data[o..<o + n], encoding: .ascii) ?? ""
        }
        func u16(_ o: Int) -> Int { Int(data[o]) | (Int(data[o + 1]) << 8) }
        func u32(_ o: Int) -> Int {
            Int(data[o]) | (Int(data[o + 1]) << 8) | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24)
        }

        guard data.count > 44, ascii(0, 4) == "RIFF", ascii(8, 4) == "WAVE" else { throw WavError.unsupported }

        var sampleRate = 16_000, channels = 1, bits = 16
        var dataOffset = 0, dataSize = 0
        var p = 12
        while p + 8 <= data.count {
            let id = ascii(p, 4)
            let size = u32(p + 4)
            let body = p + 8
            if id == "fmt " {
                channels = u16(body + 2)
                sampleRate = u32(body + 4)
                bits = u16(body + 14)
            } else if id == "data" {
                dataOffset = body
                dataSize = min(size, data.count - body)
                break
            }
            p = body + size + (size & 1) // chunks are word-aligned
        }
        guard dataOffset > 0, dataSize > 0 else { throw WavError.unsupported }
        return WavInfo(sampleRate: sampleRate, channels: channels, bitsPerSample: bits,
                       dataOffset: dataOffset, dataSize: dataSize)
    }

    /// Standalone WAV `Data` covering `[startSec, endSec)`.
    func chunkData(startSec: Double, endSec: Double) -> Data {
        let bps = info.bytesPerSecond
        let align = max(1, info.channels * info.bitsPerSample / 8)
        var startByte = Int(startSec * Double(bps))
        var endByte = Int(endSec * Double(bps))
        startByte -= startByte % align
        endByte -= endByte % align
        startByte = max(0, min(startByte, info.dataSize))
        endByte = max(startByte, min(endByte, info.dataSize))
        let slice = data.subdata(in: (info.dataOffset + startByte)..<(info.dataOffset + endByte))
        return WavReader.wrap(pcm: slice, sampleRate: info.sampleRate,
                              channels: info.channels, bits: info.bitsPerSample)
    }

    private static func wrap(pcm: Data, sampleRate: Int, channels: Int, bits: Int) -> Data {
        let byteRate = sampleRate * channels * bits / 8
        let blockAlign = channels * bits / 8
        let dataLen = pcm.count
        var h = Data()
        func s(_ x: String) { h.append(contentsOf: Array(x.utf8)) }
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        s("RIFF"); u32(36 + dataLen); s("WAVE")
        s("fmt "); u32(16); u16(1); u16(channels); u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bits)
        s("data"); u32(dataLen)
        var out = h
        out.append(pcm)
        return out
    }
}

/// A subtitle cue with absolute start/end times in seconds.
struct TimedCue {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleTime {
    /// Parses `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, or `MM:SS.mmm` into seconds.
    static func parse(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":")
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        } else if parts.count == 2 {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        }
        return nil
    }

    static func formatSRT(_ v: Double) -> String { format(v, sep: ",") }
    static func formatVTT(_ v: Double) -> String { format(v, sep: ".") }

    private static func format(_ v: Double, sep: String) -> String {
        let ms = max(0, Int((v * 1000).rounded()))
        return String(format: "%02d:%02d:%02d\(sep)%03d",
                      ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000)
    }
}

enum SubtitleCodec {
    /// Parses SRT/VTT text into timed cues (ignoring index and header lines).
    static func parse(_ content: String) -> [TimedCue] {
        let norm = content.replacingOccurrences(of: "\r\n", with: "\n")
        var cues: [TimedCue] = []
        for block in norm.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let idx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let comps = lines[idx].components(separatedBy: "-->")
            guard comps.count == 2,
                  let start = SubtitleTime.parse(comps[0]),
                  let end = SubtitleTime.parse(comps[1]) else { continue }
            let text = lines[(idx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            cues.append(TimedCue(start: start, end: end, text: text))
        }
        return cues
    }

    static func render(_ cues: [TimedCue], format: ResponseFormat) -> String {
        switch format {
        case .srt:
            var out = ""
            for (i, c) in cues.enumerated() {
                out += "\(i + 1)\n\(SubtitleTime.formatSRT(c.start)) --> \(SubtitleTime.formatSRT(c.end))\n\(c.text)\n\n"
            }
            return out
        case .vtt:
            var out = "WEBVTT\n\n"
            for c in cues {
                out += "\(SubtitleTime.formatVTT(c.start)) --> \(SubtitleTime.formatVTT(c.end))\n\(c.text)\n\n"
            }
            return out
        }
    }
}

extension WhisperClient {
    /// Transcribes by splitting the audio into fixed-length chunks, offsetting
    /// each chunk's timestamps, and merging. Reports 0...1 progress per chunk,
    /// and structurally prevents giant multi-minute cues.
    func transcribeChunked(audioURL: URL,
                           chunkSeconds: Double = 120,
                           progress: @escaping (Double) -> Void) async throws -> String {
        let reader = try WavReader(url: audioURL)
        let total = reader.info.duration
        guard total > 0 else { throw WavError.unsupported }

        let count = max(1, Int(ceil(total / chunkSeconds)))
        var merged: [TimedCue] = []
        let tmpDir = FileManager.default.temporaryDirectory

        for i in 0..<count {
            try Task.checkCancellation()
            let start = Double(i) * chunkSeconds
            let end = min(start + chunkSeconds, total)

            let chunkURL = tmpDir.appendingPathComponent("chunk-\(UUID().uuidString).wav")
            try reader.chunkData(startSec: start, endSec: end).write(to: chunkURL)
            defer { try? FileManager.default.removeItem(at: chunkURL) }

            let raw: String
            do {
                raw = try await transcribe(audioURL: chunkURL)
            } catch WhisperClientError.emptyResponse {
                raw = "" // silent chunk -> no cues
            }

            for cue in SubtitleCodec.parse(raw) {
                merged.append(TimedCue(start: cue.start + start, end: cue.end + start, text: cue.text))
            }
            progress(Double(i + 1) / Double(count))
        }

        return SubtitleCodec.render(merged, format: responseFormat)
    }
}
