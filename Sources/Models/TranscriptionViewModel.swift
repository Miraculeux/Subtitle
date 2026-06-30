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
    @Published var translationProgress: Double = 0
    @Published var subtitleText: String = ""
    @Published var statusMessage: String = "Select a video file to begin."

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

    /// Requests cancellation of the in-progress pipeline.
    func cancel() {
        guard isRunning else { return }
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
        switch stage {
        case .extractingAudio, .transcribing, .translating: return true
        default: return false
        }
    }

    var canStart: Bool {
        videoURL != nil && !isRunning
    }

    func selectVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
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
        panel.message = "Choose a video or audio file to transcribe"
        if panel.runModal() == .OK, let url = panel.url {
            setVideo(url: url)
        }
    }

    /// Accepts a file from the open panel or a drag-and-drop operation.
    func setVideo(url: URL) {
        cleanupWorkingWAV()
        rawTranscript = nil
        resumeStep = nil
        videoURL = url
        subtitleText = ""
        stage = .idle
        statusMessage = "Ready: \(url.lastPathComponent)"
    }

    private func cleanupWorkingWAV() {
        if let wav = workingWAV, !workingWAVIsExternal {
            try? FileManager.default.removeItem(at: wav)
        }
        workingWAV = nil
        workingWAVIsExternal = false
    }

    func start() {
        run(from: .extract)
    }

    /// Retries from the step that failed, reusing already-completed work.
    func retry() {
        run(from: resumeStep ?? .extract)
    }

    private func run(from requestedStep: Step) {
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
            defer { endPreventSleep() }
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
                if settings.keepExtractedAudio, !workingWAVIsExternal, let wav = workingWAV {
                    workingWAV = nil // detach so it is not auto-deleted later
                    autoSaveSubtitle(extraNote: "Audio kept: \(wav.path)")
                } else {
                    cleanupWorkingWAV()
                    autoSaveSubtitle(extraNote: nil)
                }
                rawTranscript = nil
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
        let result = try await client.transcribe(audioURL: wav)
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
