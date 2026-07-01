import Foundation

enum WhisperClientError: LocalizedError {
    case invalidEndpoint
    case requestFailed(Int, String)
    case emptyResponse
    case transportError(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The configured server address is not a valid URL."
        case .requestFailed(let code, let body):
            return "The server returned HTTP \(code). \(body)"
        case .emptyResponse:
            return "The server returned an empty transcription."
        case .transportError(let message):
            return "Could not reach the Whisper server. \(message)"
        }
    }
}

/// Sends audio to an OpenAI-compatible `/v1/audio/transcriptions` endpoint.
/// Works with whisper.cpp server, faster-whisper-server, LocalAI, etc.
struct WhisperClient {
    let endpoint: URL
    let model: String
    let language: String
    let apiKey: String
    let responseFormat: ResponseFormat

    func transcribe(audioURL: URL) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 3_600
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let audioData = try Data(contentsOf: audioURL)
        var fields: [(String, String)] = [
            ("model", model),
            ("response_format", responseFormat.rawValue),
            // Start greedy at temperature 0, but allow Whisper's temperature
            // fallback to recover failed/garbled segments (fewer repetition
            // loops and giant-duration cues, at the cost of exact reproducibility).
            ("temperature", "0")
        ]
        let trimmedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLanguage.isEmpty {
            fields.append(("language", trimmedLanguage))
        }

        let body = makeMultipartBody(boundary: boundary,
                                     fields: fields,
                                     fileField: "file",
                                     fileName: audioURL.lastPathComponent,
                                     fileData: audioData,
                                     mimeType: "audio/wav")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw WhisperClientError.transportError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WhisperClientError.emptyResponse
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw WhisperClientError.requestFailed(http.statusCode, text.prefix(500).description)
        }

        let result = extractSubtitleText(from: text)
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WhisperClientError.emptyResponse
        }
        return result
    }

    /// Some servers wrap srt/vtt output inside a JSON `{ "text": "..." }`
    /// even when a text format is requested; handle both shapes gracefully.
    private func extractSubtitleText(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            return raw
        }
        return text
    }

    private func makeMultipartBody(boundary: String,
                                   fields: [(String, String)],
                                   fileField: String,
                                   fileName: String,
                                   fileData: Data,
                                   mimeType: String) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        for (name, value) in fields {
            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)")
            body.append("\(value)\(lineBreak)")
        }

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\(lineBreak)")
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(fileData)
        body.append(lineBreak)
        body.append("--\(boundary)--\(lineBreak)")

        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
