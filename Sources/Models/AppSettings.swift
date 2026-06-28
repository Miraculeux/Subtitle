import Foundation
import Combine

/// Persisted user configuration for the local Whisper and translation services.
final class AppSettings: ObservableObject {
    // Whisper transcription
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: Keys.serverURL) } }
    @Published var modelName: String { didSet { defaults.set(modelName, forKey: Keys.modelName) } }
    @Published var apiKey: String { didSet { defaults.set(apiKey, forKey: Keys.apiKey) } }
    @Published var sourceLanguage: String { didSet { defaults.set(sourceLanguage, forKey: Keys.sourceLanguage) } }
    @Published var responseFormat: ResponseFormat {
        didSet { defaults.set(responseFormat.rawValue, forKey: Keys.responseFormat) }
    }

    // Translation (optional, OpenAI-compatible chat completions)
    @Published var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: Keys.targetLanguage) } }
    @Published var translationServerURL: String { didSet { defaults.set(translationServerURL, forKey: Keys.translationServerURL) } }
    @Published var translationModel: String { didSet { defaults.set(translationModel, forKey: Keys.translationModel) } }
    @Published var translationApiKey: String { didSet { defaults.set(translationApiKey, forKey: Keys.translationApiKey) } }
    @Published var bilingualOutput: Bool { didSet { defaults.set(bilingualOutput, forKey: Keys.bilingualOutput) } }
    @Published var originalOnTop: Bool { didSet { defaults.set(originalOnTop, forKey: Keys.originalOnTop) } }

    // Files
    @Published var workingDirectory: String { didSet { defaults.set(workingDirectory, forKey: Keys.workingDirectory) } }
    @Published var keepExtractedAudio: Bool { didSet { defaults.set(keepExtractedAudio, forKey: Keys.keepExtractedAudio) } }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let serverURL = "serverURL"
        static let modelName = "modelName"
        static let apiKey = "apiKey"
        static let sourceLanguage = "sourceLanguage"
        static let responseFormat = "responseFormat"
        static let targetLanguage = "targetLanguage"
        static let translationServerURL = "translationServerURL"
        static let translationModel = "translationModel"
        static let translationApiKey = "translationApiKey"
        static let bilingualOutput = "bilingualOutput"
        static let originalOnTop = "originalOnTop"
        static let workingDirectory = "workingDirectory"
        static let keepExtractedAudio = "keepExtractedAudio"
    }

    init() {
        serverURL = defaults.string(forKey: Keys.serverURL) ?? "http://127.0.0.1:8080"
        modelName = defaults.string(forKey: Keys.modelName) ?? "whisper-1"
        apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        // Migrate the old "language" key to "sourceLanguage" if present.
        sourceLanguage = defaults.string(forKey: Keys.sourceLanguage)
            ?? defaults.string(forKey: "language") ?? ""
        let storedFormat = defaults.string(forKey: Keys.responseFormat) ?? ResponseFormat.srt.rawValue
        responseFormat = ResponseFormat(rawValue: storedFormat) ?? .srt

        targetLanguage = defaults.string(forKey: Keys.targetLanguage) ?? ""
        translationServerURL = defaults.string(forKey: Keys.translationServerURL) ?? "http://127.0.0.1:1234"
        translationModel = defaults.string(forKey: Keys.translationModel) ?? "qwen2.5-vl-32b-instruct"
        translationApiKey = defaults.string(forKey: Keys.translationApiKey) ?? ""
        bilingualOutput = defaults.object(forKey: Keys.bilingualOutput) as? Bool ?? false
        originalOnTop = defaults.object(forKey: Keys.originalOnTop) as? Bool ?? true
        workingDirectory = defaults.string(forKey: Keys.workingDirectory) ?? ""
        keepExtractedAudio = defaults.object(forKey: Keys.keepExtractedAudio) as? Bool ?? false
    }

    var translationEnabled: Bool {
        !targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Directory where the extracted audio WAV is written. Falls back to the
    /// system temporary directory when unset or invalid.
    var workingDirectoryURL: URL {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let url = URL(fileURLWithPath: trimmed, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return FileManager.default.temporaryDirectory
    }

    /// Builds the full transcription endpoint from the configured base URL.
    var transcriptionEndpoint: URL? {
        endpoint(from: serverURL, defaultPath: "v1/audio/transcriptions", marker: "audio/transcriptions")
    }

    /// Builds the chat-completions endpoint used for translation.
    var translationEndpoint: URL? {
        endpoint(from: translationServerURL, defaultPath: "v1/chat/completions", marker: "chat/completions")
    }

    private func endpoint(from raw: String, defaultPath: String, marker: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var base = URL(string: trimmed) else { return nil }
        if base.path.contains(marker) { return base }
        base.appendPathComponent(defaultPath)
        return base
    }
}

enum ResponseFormat: String, CaseIterable, Identifiable {
    case srt
    case vtt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .srt: return "SubRip (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        }
    }

    var fileExtension: String { rawValue }
}
