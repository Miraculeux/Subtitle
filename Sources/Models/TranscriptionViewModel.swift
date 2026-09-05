import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum PipelineError: LocalizedError {
    case missingAudio
    case missingTranscript
    case invalidServer

    var errorDescription: String? {
        switch self {
        case .missingAudio: return "Extracted audio is missing; re-run extraction."
        case .missingTranscript: return "Transcript is missing; re-run transcription."
        case .invalidServer: return "Invalid server address. Check Settings."
        }
    }
}

@MainActor
final class TranscriptionViewModel: ObservableObject {
    struct QueueItem: Identifiable {
        enum Status {
            case pending
            case processing
            case completed
            case failed(String)

            var isProcessing: Bool {
                if case .processing = self { return true }
                return false
            }
        }

        let id = UUID()
        let url: URL
        var status: Status = .pending
    }

    enum Stage: Equatable {
        case idle
        case extractingAudio
        case transcribing
        case translating
        case finished
        case failed(String)
    }

    @Published var videoURL: URL?
    @Published var stage: Stage = .idle
    @Published var extractionProgress: Double = 0
    @Published var transcriptionProgress: Double = 0
    @Published var translationProgress: Double = 0
    @Published var subtitleText: String = ""
    @Published var statusMessage: String = "Select a video file to begin."
    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var isQueueRunning = false

    private var settings: AppSettings?
    private var sleepAssertion: NSObjectProtocol?

    /// Resumable pipeline steps, in order.
    enum Step: Int { case extract = 0, transcribe = 1, translate = 2 }

    /// Intermediate artifacts kept so a retry can resume mid-pipeline.
    private var workingWAV: URL?
    /// True when `workingWAV` points at the user's original file (already in the
    /// target format) and therefore must never be deleted.
    private var workingWAVIsExternal = false
    private var rawTranscript: String?
    private var resumeStep: Step?
    private var currentTask: Task<Void, Never>?

    func attach(settings: AppSettings) {
        self.settings = settings
    }

    /// True when the last run failed and can be resumed from a known step.
    var canRetry: Bool {
        if case .failed = stage { return resumeStep != nil && !isRunning }
        return false
    }

    var canCancel: Bool { isRunning }

    /// Which pipeline step is currently executing, if any.
    var activeStep: Step? {
        switch stage {
        case .extractingAudio: return .extract
        case .transcribing: return .transcribe
        case .translating: return .translate
        default: return nil
        }
    }

    var hasAudio: Bool { workingWAV != nil }
    var hasTranscript: Bool { rawTranscript != nil }

    /// Whether the user may (re)start the pipeline from a given step.
    func canRun(_ step: Step) -> Bool {
        guard videoURL != nil, !isRunning else { return false }
        switch step {
        case .extract:   return true
        case .transcribe: return true // reuses existing audio, else extracts first
        case .translate:  return settings?.translationEnabled ?? false
        }
    }

    /// Marks a step as already completed (for the UI status indicator).
    func isStepDone(_ step: Step) -> Bool {
        switch step {
        case .extract:   return hasAudio
        case .transcribe: return hasTranscript
        case .translate:  return stage == .finished && (settings?.translationEnabled ?? false)
        }
    }

    /// Runs the pipeline starting at the chosen step, reusing prior artifacts.
    func runFrom(_ step: Step) {
        isQueueRunning = false
        run(from: step)
    }

    /// Requests cancellation of the in-progress pipeline.
    func cancel() {
        guard isRunning else { return }
        isQueueRunning = false
        statusMessage = "Cancelling…"
        currentTask?.cancel()
    }

    /// Prevents the system from idle-sleeping while a job is in progress.
    private func beginPreventSleep() {
        guard sleepAssertion == nil else { return }
        sleepAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Extracting audio, transcribing and translating")
    }

    private func endPreventSleep() {
        if let token = sleepAssertion {
            ProcessInfo.processInfo.endActivity(token)
            sleepAssertion = nil
        }
    }

    var isRunning: Bool {
        if isQueueRunning { return true }
        switch stage {
        case .extractingAudio, .transcribing, .translating: return true
        default: return false
        }
    }

    var canStart: Bool {
        !queue.isEmpty && !isRunning
    }

    func selectVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        var types: [UTType] = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie]
        let extraExtensions = ["mkv", "webm", "avi", "flv", "ts", "m4v", "wmv", "mpg", "mpeg",
                               "mp3", "wav", "m4a", "aac", "flac", "ogg", "opus"]
        for ext in extraExtensions {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.message = "Choose video or audio files to add to the queue"
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    /// Adds one file from a drag-and-drop operation.
    func setVideo(url: URL) {
        addFiles([url])
    }

    func addFiles(_ urls: [URL]) {
        guard !isRunning else { return }
        var knownPaths = Set(queue.map { $0.url.standardizedFileURL.path })
        let additions = urls.filter { url in
            let path = url.standardizedFileURL.path
            return url.isFileURL && knownPaths.insert(path).inserted
        }
        guard !additions.isEmpty else { return }

        queue.append(contentsOf: additions.map { QueueItem(url: $0) })
        if videoURL == nil, let first = queue.first {
            prepareVideo(first.url)
        }
        statusMessage = "Queue ready: \(queue.count) file\(queue.count == 1 ? "" : "s")."
    }

    func removeFromQueue(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }),
              !queue[index].status.isProcessing else { return }
        let removedCurrent = queue[index].url == videoURL
        queue.remove(at: index)
        if removedCurrent {
            if let first = queue.first {
                prepareVideo(first.url)
            } else {
                resetCurrentVideo()
            }
        }
        statusMessage = queue.isEmpty ? "Select video or audio files to begin." : "Queue ready: \(queue.count) file\(queue.count == 1 ? "" : "s")."
    }

    func canRemoveFromQueue(id: UUID) -> Bool {
        queue.first(where: { $0.id == id }).map { !$0.status.isProcessing } ?? false
    }

    func clearQueue() {
        guard !isRunning else { return }
        queue.removeAll()
        resetCurrentVideo()
        statusMessage = "Select video or audio files to begin."
    }

    private func prepareVideo(_ url: URL) {
        cleanupWorkingWAV()
        rawTranscript = nil
        resumeStep = nil
        videoURL = url
        subtitleText = ""
        stage = .idle
        statusMessage = "Ready: \(url.lastPathComponent)"
    }

    private func resetCurrentVideo() {
        cleanupWorkingWAV()
        rawTranscript = nil
        resumeStep = nil
        videoURL = nil
        subtitleText = ""
        stage = .idle
    }

    private func cleanupWorkingWAV() {
        if let wav = workingWAV, !workingWAVIsExternal {
            try? FileManager.default.removeItem(at: wav)
        }
        workingWAV = nil
        workingWAVIsExternal = false
    }

    func start() {
        guard !queue.isEmpty, !isRunning else { return }
        guard settings?.transcriptionEndpoint != nil else {
            stage = .failed("Invalid server address. Check Settings.")
            statusMessage = "Invalid server address."
            return
        }
        for index in queue.indices {
            queue[index].status = .pending
        }
        isQueueRunning = true
        runNextQueuedFile()
    }

    /// Retries from the step that failed, reusing already-completed work.
    func retry() {
        run(from: resumeStep ?? .extract)
    }

    private func runNextQueuedFile() {
        guard isQueueRunning else { return }
        guard let index = queue.firstIndex(where: {
            if case .pending = $0.status { return true }
            return false
        }) else {
            isQueueRunning = false
            endPreventSleep()
            let completed = queue.filter {
                if case .completed = $0.status { return true }
                return false
            }.count
            let failed = queue.count - completed
            stage = failed == 0 ? .finished : .failed("\(failed) file\(failed == 1 ? "" : "s") failed")
            statusMessage = "Queue finished: \(completed) completed, \(failed) failed."
            return
        }

        let item = queue[index]
        queue[index].status = .processing
        prepareVideo(item.url)
        run(from: .extract, queueItemID: item.id)
    }

    private func run(from requestedStep: Step, queueItemID: UUID? = nil) {
        guard let videoURL, let settings else { return }
        guard settings.transcriptionEndpoint != nil else {
            stage = .failed("Invalid server address. Check Settings.")
            statusMessage = "Invalid server address."
            resumeStep = .transcribe
            return
        }

        // Normalise the resume point against the artifacts we actually have.
        var step = requestedStep
        if step == .translate && rawTranscript == nil { step = .transcribe }
        if step == .transcribe && workingWAV == nil { step = .extract }

        resumeStep = nil
        beginPreventSleep()

        currentTask = Task {
            defer {
                if queueItemID == nil || !isQueueRunning {
                    endPreventSleep()
                }
            }
            var failedAt: Step = step
            do {
                if step == .extract {
                    failedAt = .extract
                    stage = .extractingAudio
                    extractionProgress = 0
                    statusMessage = "Extracting audio…"
                    try await runExtract(videoURL: videoURL)
                }

                try Task.checkCancellation()

                if step.rawValue <= Step.transcribe.rawValue {
                    failedAt = .transcribe
                    stage = .transcribing
                    statusMessage = "Transcribing with Whisper…"
                    try await runTranscribe(settings: settings)
                }

                try Task.checkCancellation()

                if settings.translationEnabled {
                    failedAt = .translate
                    try await runTranslate(settings: settings)
                } else {
                    subtitleText = rawTranscript ?? ""
                }

                stage = .finished
                // Keep the extracted audio and transcript so the user can
                // re-run any single step (e.g. just re-translate) without
                // redoing earlier work. Artifacts are cleared on new file.
                let audioNote = (settings.keepExtractedAudio && !workingWAVIsExternal)
                    ? workingWAV.map { "Audio: \($0.path)" } : nil
                autoSaveSubtitle(extraNote: audioNote)
                resumeStep = nil
            } catch {
                resumeStep = failedAt
                if Task.isCancelled || error is CancellationError {
                    stage = .failed("Cancelled")
                    statusMessage = "Cancelled at \(stepName(failedAt)). Click Retry to resume."
                } else {
                    let message = error.localizedDescription
                    stage = .failed(message)
                    statusMessage = "Failed at \(stepName(failedAt)): \(message)"
                }
            }
            currentTask = nil
            if let queueItemID,
               let index = queue.firstIndex(where: { $0.id == queueItemID }) {
                if case .finished = stage {
                    queue[index].status = .completed
                } else if case .failed(let message) = stage {
                    queue[index].status = .failed(message)
                }
                runNextQueuedFile()
            }
        }
    }

    private func stepName(_ step: Step) -> String {
        switch step {
        case .extract: return "audio extraction"
        case .transcribe: return "transcription"
        case .translate: return "translation"
        }
    }

    private func runExtract(videoURL: URL) async throws {
        // Fast path: the input is already a 16 kHz mono WAV — use it directly,
        // skipping any extraction/transcoding (and never delete the original).
        if AudioExtractor.isReadyToUse(videoURL) {
            cleanupWorkingWAV()
            workingWAV = videoURL
            workingWAVIsExternal = true
            extractionProgress = 1.0
            return
        }

        let directory = workingDirectory(for: videoURL)
        let wav = directory.appendingPathComponent("subtitle-\(UUID().uuidString).wav")
        try await AudioExtractor.extractWAV(from: videoURL, to: wav) { [weak self] value in
            Task { @MainActor in self?.extractionProgress = value }
        }
        cleanupWorkingWAV()
        workingWAV = wav
        workingWAVIsExternal = false
    }

    /// Resolves where to write the extracted audio. Uses an explicitly
    /// configured folder when set; otherwise defaults to the folder containing
    /// the source video (falling back to the temp folder if not writable).
    private func workingDirectory(for videoURL: URL) -> URL {
        let fm = FileManager.default
        if let configured = settings?.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return settings?.workingDirectoryURL ?? fm.temporaryDirectory
        }
        let folder = videoURL.deletingLastPathComponent()
        if fm.isWritableFile(atPath: folder.path) {
            return folder
        }
        return fm.temporaryDirectory
    }

    private func runTranscribe(settings: AppSettings) async throws {
        guard let wav = workingWAV else { throw PipelineError.missingAudio }
        guard let endpoint = settings.transcriptionEndpoint else { throw PipelineError.invalidServer }
        let client = WhisperClient(endpoint: endpoint,
                                   model: settings.modelName,
                                   language: settings.sourceLanguage,
                                   apiKey: settings.apiKey,
                                   responseFormat: settings.responseFormat)
        transcriptionProgress = 0
        let result = try await client.transcribeChunked(audioURL: wav) { [weak self] value in
            Task { @MainActor in self?.transcriptionProgress = value }
        }
        rawTranscript = result
        subtitleText = result // show the transcript immediately
    }

    /// Runs the optional translation pass over the generated subtitles.
    private func runTranslate(settings: AppSettings) async throws {
        guard let raw = rawTranscript else { throw PipelineError.missingTranscript }
        guard let endpoint = settings.translationEndpoint else {
            throw TranslatorError.invalidEndpoint
        }
        let target = Language.all.first { $0.code == settings.targetLanguage }
            ?? Language(code: settings.targetLanguage, name: settings.targetLanguage, nativeName: settings.targetLanguage)
        let source = Language.all.first { $0.code == settings.sourceLanguage }

        let translator = SubtitleTranslator(endpoint: endpoint,
                                            model: settings.translationModel,
                                            apiKey: settings.translationApiKey,
                                            targetLanguage: target,
                                            sourceLanguage: source,
                                            bilingual: settings.bilingualOutput,
                                            originalOnTop: settings.originalOnTop,
                                            disableThinking: settings.disableThinking)

        stage = .translating
        translationProgress = 0
        statusMessage = "Translating to \(target.promptName)…"

        let translated = try await translator.translate(raw) { [weak self] value in
            Task { @MainActor in self?.translationProgress = value }
        }
        subtitleText = translated
    }

    /// Automatically writes the finished subtitle next to the source file.
    /// Falls back to a Save panel when the folder is not writable.
    private func autoSaveSubtitle(extraNote: String?) {
        guard !subtitleText.isEmpty else {
            statusMessage = "Done, but no subtitles were produced."
            return
        }
        let ext = settings?.responseFormat.fileExtension ?? "srt"

        guard let videoURL else {
            promptSaveSubtitle(defaultName: "subtitle.\(ext)", directory: nil)
            return
        }

        let dir = videoURL.deletingLastPathComponent()
        let base = videoURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default

        if fm.isWritableFile(atPath: dir.path) {
            var target = dir.appendingPathComponent("\(base).\(ext)")
            if fm.fileExists(atPath: target.path) {
                target = dir.appendingPathComponent("\(base).\(timestampString()).\(ext)")
            }
            do {
                try subtitleText.write(to: target, atomically: true, encoding: .utf8)
                var message = "Saved: \(target.path)"
                if let extraNote { message += "  •  \(extraNote)" }
                statusMessage = message
                return
            } catch {
                // Fall through to prompting the user for a destination.
            }
        }

        promptSaveSubtitle(defaultName: "\(base).\(ext)", directory: dir)
    }

    private func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Shown only when the target folder is not writable or the write failed.
    private func promptSaveSubtitle(defaultName: String, directory: URL?) {
        let ext = settings?.responseFormat.fileExtension ?? "srt"
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = defaultName
        if let directory { panel.directoryURL = directory }
        panel.message = "The default folder is not writable. Choose where to save the subtitles."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try subtitleText.write(to: url, atomically: true, encoding: .utf8)
                statusMessage = "Saved: \(url.path)"
            } catch {
                statusMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }
}
