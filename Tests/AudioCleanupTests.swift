import Foundation

private final class MockSubtitleServer: URLProtocol {
    static var failTranslation = false
    static var transcriptionCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "subtitle-cleanup.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let translating = request.url!.path.contains("chat/completions")
        if !translating { Self.transcriptionCount += 1 }
        let status = translating && Self.failTranslation ? 500 : 200
        let body = translating
            ? #"{"choices":[{"message":{"content":"{\"0\":\"Translated\"}"}}]}"#
            : "1\n00:00:00,000 --> 00:00:00,100\nHello\n\n"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
private struct AudioCleanupTests {
    @MainActor
    static func main() async throws {
        let suite = "subtitle-cleanup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        precondition(URLProtocol.registerClass(MockSubtitleServer.self))
        defer { URLProtocol.unregisterClass(MockSubtitleServer.self) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("subtitle-cleanup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fatalError("Test fixture cleanup failed: \(error)") }
        }

        let settings = AppSettings(defaults: defaults)
        settings.serverURL = "https://subtitle-cleanup.test"
        settings.translationServerURL = "https://subtitle-cleanup.test"
        settings.apiKey = ""
        settings.translationApiKey = ""
        settings.targetLanguage = "zh"
        settings.workingDirectory = root.path
        settings.keepExtractedAudio = false

        let input = root.appendingPathComponent("input.wav")
        try wav(sampleRate: 8_000).write(to: input)
        let model = TranscriptionViewModel()
        model.attach(settings: settings)
        model.addFiles([input])
        model.start()
        try await waitForCompletion(model)
        precondition(model.stage == .finished, model.statusMessage)
        try require(workingAudio(in: root).isEmpty)
        precondition(model.hasTranscript && !model.hasAudio)
        precondition(model.isStepDone(.extract))
        precondition(FileManager.default.fileExists(atPath: input.path))
        print("PASS: translation completion removes generated WAV, not source")

        let transcriptions = MockSubtitleServer.transcriptionCount
        model.runFrom(.translate)
        try await waitForCompletion(model)
        precondition(model.stage == .finished, model.statusMessage)
        precondition(MockSubtitleServer.transcriptionCount == transcriptions)
        try require(workingAudio(in: root).isEmpty)
        model.runFrom(.transcribe)
        try await waitForCompletion(model)
        precondition(model.stage == .finished, model.statusMessage)
        precondition(MockSubtitleServer.transcriptionCount == transcriptions + 1)
        try require(workingAudio(in: root).isEmpty)
        print("PASS: re-translation reuses transcript; re-transcription regenerates audio")

        settings.targetLanguage = ""
        model.runFrom(.extract)
        try await waitForCompletion(model)
        precondition(model.stage == .finished, model.statusMessage)
        try require(workingAudio(in: root).isEmpty)
        print("PASS: transcription-only completion removes generated WAV")

        settings.targetLanguage = "zh"
        MockSubtitleServer.failTranslation = true
        model.runFrom(.extract)
        try await waitForCompletion(model)
        precondition(model.canRetry && model.hasAudio && model.hasTranscript)
        try require(workingAudio(in: root).count == 1)
        MockSubtitleServer.failTranslation = false
        model.retry()
        try await waitForCompletion(model)
        precondition(model.stage == .finished, model.statusMessage)
        try require(workingAudio(in: root).isEmpty)
        print("PASS: failed translation retains audio; successful retry removes it")

        settings.keepExtractedAudio = true
        let second = root.appendingPathComponent("second.wav")
        try wav(sampleRate: 8_000).write(to: second)
        model.addFiles([second])
        model.start()
        try await waitForCompletion(model)
        precondition(model.stage == .finished, model.statusMessage)
        try require(workingAudio(in: root).count == 2)
        model.clearQueue()
        try require(workingAudio(in: root).count == 2)
        print("PASS: retained audio survives queue transitions and clearing")

        settings.keepExtractedAudio = false
        let external = root.appendingPathComponent("original.wav")
        let original = wav(sampleRate: 16_000)
        try original.write(to: external)
        model.addFiles([external])
        model.start()
        try await waitForCompletion(model)
        precondition(model.stage == .finished, model.statusMessage)
        model.clearQueue()
        try require(Data(contentsOf: external) == original)
        print("PASS: ready-to-use original WAV remains unchanged")
    }

    private static func require(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
        precondition(condition, file: file, line: line)
    }

    @MainActor
    private static func waitForCompletion(_ model: TranscriptionViewModel) async throws {
        for _ in 0..<1_500 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if !model.isRunning {
                switch model.stage {
                case .finished, .failed: return
                default: break
                }
            }
        }
        fatalError("Pipeline timed out: \(model.statusMessage)")
    }

    private static func workingAudio(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("subtitle-") && $0.pathExtension == "wav" }
    }

    private static func wav(sampleRate: Int) -> Data {
        let pcm = Data(repeating: 0, count: sampleRate / 5)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + pcm.count)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(sampleRate)); number(UInt32(sampleRate * 2))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
