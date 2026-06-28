import Foundation
import AVFoundation

enum AudioExtractorError: LocalizedError {
    case noAudioTrack
    case readerInitFailed
    case readingFailed(String?)
    case writeFailed
    case unsupportedNoFFmpeg(String)
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "未找到音频轨道。该文件可能没有声音,或封装格式不受支持。"
        case .readerInitFailed:
            return "无法初始化音频解码器。"
        case .readingFailed(let reason):
            return "音频解码失败。\(reason ?? "")"
        case .writeFailed:
            return "无法写入提取的音频文件。"
        case .unsupportedNoFFmpeg(let detail):
            return "系统无法解码该文件(可能是 MKV/WebM 容器或 HEVC/特殊音频编码),且未找到 ffmpeg。请安装 ffmpeg 后重试:brew install ffmpeg。(系统提示:\(detail))"
        case .ffmpegFailed(let detail):
            return "ffmpeg 提取音频失败:\(detail)"
        }
    }
}

/// Extracts the audio track from a video file and writes it as a
/// 16 kHz, mono, 16-bit PCM WAV file — the format Whisper models expect.
struct AudioExtractor {
    static let sampleRate = 16_000
    static let channels = 1
    static let bitsPerSample = 16

    /// Extracts the audio track to a 16 kHz mono WAV. Tries AVFoundation first
    /// (fast, native), and on failure transparently falls back to ffmpeg so
    /// unsupported containers/codecs (MKV, WebM, HEVC, etc.) still work.
    /// - Parameters:
    ///   - videoURL: Source media (video or audio) file.
    ///   - outputURL: Destination `.wav` file (overwritten if it exists).
    ///   - progress: Reports a 0.0...1.0 fraction as decoding proceeds.
    static func extractWAV(from videoURL: URL,
                           to outputURL: URL,
                           progress: @escaping (Double) -> Void) async throws {
        do {
            try await extractWithAVFoundation(from: videoURL, to: outputURL, progress: progress)
        } catch let avError {
            // AVFoundation could not handle this file. Try ffmpeg if present.
            guard let ffmpeg = findFFmpeg() else {
                throw AudioExtractorError.unsupportedNoFFmpeg(avError.localizedDescription)
            }
            progress(0)
            try await extractWithFFmpeg(ffmpeg: ffmpeg, from: videoURL, to: outputURL, progress: progress)
        }
    }

    private static func extractWithAVFoundation(from videoURL: URL,
                                                to outputURL: URL,
                                                progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: videoURL)

        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioExtractorError.noAudioTrack
        }

        let duration = try await asset.load(.duration)
        let totalSeconds = max(CMTimeGetSeconds(duration), 0.001)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioExtractorError.readerInitFailed
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitsPerSample,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw AudioExtractorError.readerInitFailed
        }
        reader.add(readerOutput)

        // Prepare destination file with a placeholder WAV header.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            throw AudioExtractorError.writeFailed
        }
        defer { try? handle.close() }

        try handle.write(contentsOf: wavHeader(dataLength: 0))

        guard reader.startReading() else {
            throw AudioExtractorError.readingFailed(reader.error?.localizedDescription)
        }

        var totalDataBytes = 0
        while reader.status == .reading {
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let result = CMBlockBufferGetDataPointer(blockBuffer,
                                                     atOffset: 0,
                                                     lengthAtOffsetOut: nil,
                                                     totalLengthOut: &length,
                                                     dataPointerOut: &dataPointer)
            guard result == kCMBlockBufferNoErr, let pointer = dataPointer, length > 0 else { continue }

            let data = Data(bytes: pointer, count: length)
            try handle.write(contentsOf: data)
            totalDataBytes += length

            let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let seconds = CMTimeGetSeconds(presentation)
            if seconds.isFinite {
                progress(min(max(seconds / totalSeconds, 0), 1))
            }
        }

        if reader.status == .failed {
            throw AudioExtractorError.readingFailed(reader.error?.localizedDescription)
        }

        // Patch the WAV header now that we know the real data length.
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: wavHeader(dataLength: totalDataBytes))
        progress(1.0)
    }

    /// Builds a canonical 44-byte PCM WAV header.
    private static func wavHeader(dataLength: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let chunkSize = 36 + dataLength

        var header = Data()
        func appendString(_ s: String) { header.append(contentsOf: Array(s.utf8)) }
        func appendUInt32(_ value: Int) {
            var v = UInt32(truncatingIfNeeded: value).littleEndian
            withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: Int) {
            var v = UInt16(truncatingIfNeeded: value).littleEndian
            withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
        }

        appendString("RIFF")
        appendUInt32(chunkSize)
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)              // Subchunk1Size for PCM
        appendUInt16(1)               // AudioFormat = PCM
        appendUInt16(channels)
        appendUInt32(sampleRate)
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)
        appendString("data")
        appendUInt32(dataLength)
        return header
    }

    // MARK: - ffmpeg fallback

    /// Locates an ffmpeg executable in common install locations or on PATH.
    static func findFFmpeg() -> URL? {
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let path = String(dir) + "/ffmpeg"
                if fm.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    /// Runs ffmpeg to decode the audio track into a 16 kHz mono PCM WAV.
    private static func extractWithFFmpeg(ffmpeg: URL,
                                          from videoURL: URL,
                                          to outputURL: URL,
                                          progress: @escaping (Double) -> Void) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin", "-hide_banner",
            "-i", videoURL.path,
            "-vn",
            "-ac", String(channels),
            "-ar", String(sampleRate),
            "-c:a", "pcm_s16le",
            "-y", outputURL.path
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        // ffmpeg writes progress to stderr; parse Duration/time to drive the bar.
        let state = FFmpegProgressState()
        let handle = stderrPipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            state.append(chunk)
            if let fraction = state.fraction() {
                progress(min(max(fraction, 0), 1))
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let tail = state.tail()
                    continuation.resume(throwing: AudioExtractorError.ffmpegFailed(tail))
                }
            }
            do {
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                continuation.resume(throwing: AudioExtractorError.ffmpegFailed(error.localizedDescription))
            }
        }
        progress(1.0)
    }
}

/// Accumulates ffmpeg stderr and extracts the total duration and current
/// timestamp so progress can be reported. Reference type so the escaping
/// readability handler can mutate shared state safely on the pipe's queue.
private final class FFmpegProgressState {
    private var buffer = ""
    private var totalSeconds: Double = 0

    func append(_ chunk: String) {
        buffer = String((buffer + chunk).suffix(8000))
        if totalSeconds == 0, let d = Self.parseHMS(after: "Duration: ", in: buffer) {
            totalSeconds = d
        }
    }

    func fraction() -> Double? {
        guard totalSeconds > 0,
              let current = Self.parseLastHMS(after: "time=", in: buffer) else { return nil }
        return current / totalSeconds
    }

    func tail() -> String {
        String(buffer.suffix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseHMS(after marker: String, in text: String) -> Double? {
        guard let range = text.range(of: marker) else { return nil }
        return parseToken(text[range.upperBound...])
    }

    private static func parseLastHMS(after marker: String, in text: String) -> Double? {
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        return parseToken(text[range.upperBound...])
    }

    private static func parseToken<S: StringProtocol>(_ rest: S) -> Double? {
        let token = rest.prefix(11) // HH:MM:SS.ss
        let parts = token.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]) else { return nil }
        let secDigits = parts[2].prefix { $0.isNumber || $0 == "." }
        guard let s = Double(secDigits) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
