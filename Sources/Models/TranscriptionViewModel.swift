import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

    func attach(settings: AppSettings) {
        self.settings = settings
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
            videoURL = url
            subtitleText = ""
            stage = .idle
            statusMessage = "Ready: \(url.lastPathComponent)"
        }
    }

    func start() {
        guard let videoURL, let settings else { return }
        guard let endpoint = settings.transcriptionEndpoint else {
            stage = .failed("Invalid server address. Check Settings.")
            statusMessage = "Invalid server address."
            return
        }

        let client = WhisperClient(endpoint: endpoint,
                                   model: settings.modelName,
                                   language: settings.sourceLanguage,
                                   apiKey: settings.apiKey,
                                   responseFormat: settings.responseFormat)

        subtitleText = ""
        extractionProgress = 0
        translationProgress = 0
        stage = .extractingAudio
        statusMessage = "Extracting audio…"

        Task {
            let tempWAV = FileManager.default.temporaryDirectory
                .appendingPathComponent("subtitle-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tempWAV) }

            do {
                try await AudioExtractor.extractWAV(from: videoURL, to: tempWAV) { [weak self] value in
                    Task { @MainActor in self?.extractionProgress = value }
                }

                stage = .transcribing
                statusMessage = "Transcribing with Whisper…"

                var result = try await client.transcribe(audioURL: tempWAV)

                if settings.translationEnabled {
                    result = try await self.translate(result, settings: settings)
                }

                subtitleText = result
                stage = .finished
                statusMessage = "Done. \(result.count) characters generated."
            } catch {
                let message = error.localizedDescription
                stage = .failed(message)
                statusMessage = "Failed: \(message)"
            }
        }
    }

    /// Runs the optional translation pass over the generated subtitles.
    private func translate(_ subtitle: String, settings: AppSettings) async throws -> String {
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
                                            originalOnTop: settings.originalOnTop)

        stage = .translating
        translationProgress = 0
        statusMessage = "Translating to \(target.promptName)…"

        return try await translator.translate(subtitle) { [weak self] value in
            Task { @MainActor in self?.translationProgress = value }
        }
    }

    func saveSubtitle() {
        guard !subtitleText.isEmpty else { return }
        let ext = settings?.responseFormat.fileExtension ?? "srt"
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        let baseName = videoURL?.deletingPathExtension().lastPathComponent ?? "subtitle"
        panel.nameFieldStringValue = "\(baseName).\(ext)"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try subtitleText.write(to: url, atomically: true, encoding: .utf8)
                statusMessage = "Saved to \(url.lastPathComponent)"
            } catch {
                statusMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }
}
