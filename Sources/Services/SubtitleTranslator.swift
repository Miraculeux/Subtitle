import Foundation

enum TranslatorError: LocalizedError {
    case invalidEndpoint
    case requestFailed(Int, String)
    case transportError(String)
    case malformedResponse
    case countMismatch(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The configured translation server address is not a valid URL."
        case .requestFailed(let code, let body):
            return "The translation server returned HTTP \(code). \(body)"
        case .transportError(let message):
            return "Could not reach the translation server. \(message)"
        case .malformedResponse:
            return "The translation server returned an unexpected response."
        case .countMismatch(let expected, let got):
            return "Translation alignment failed (expected \(expected) lines, got \(got))."
        }
    }
}

/// Translates the text portion of SRT/VTT subtitles via an OpenAI-compatible
/// chat-completions endpoint, preserving every timestamp and cue index.
struct SubtitleTranslator {
    let endpoint: URL
    let model: String
    let apiKey: String
    let targetLanguage: Language
    let sourceLanguage: Language?
    /// When true, each cue keeps the original text alongside the translation.
    let bilingual: Bool
    /// When `bilingual`, places the original line above the translation if true.
    let originalOnTop: Bool

    private let batchSize = 25

    /// - Parameter progress: reports a 0.0...1.0 fraction across batches.
    func translate(_ subtitle: String,
                   progress: @escaping (Double) -> Void) async throws -> String {
        var cues = SubtitleParser.parse(subtitle)

        // Indices of cues that actually carry translatable text.
        let textIndices = cues.indices.filter { cues[$0].hasTiming && !cues[$0].text.isEmpty }
        guard !textIndices.isEmpty else { return subtitle }

        let batches = stride(from: 0, to: textIndices.count, by: batchSize).map { start -> [Int] in
            Array(textIndices[start..<min(start + batchSize, textIndices.count)])
        }

        for (batchNumber, batch) in batches.enumerated() {
            let originals = batch.map { cues[$0].text }
            let translations = try await translateBatch(originals)
            for (offset, cueIndex) in batch.enumerated() {
                let original = originals[offset]
                let translated = translations[offset]
                if bilingual {
                    cues[cueIndex].text = originalOnTop
                        ? "\(original)\n\(translated)"
                        : "\(translated)\n\(original)"
                } else {
                    cues[cueIndex].text = translated
                }
            }
            progress(Double(batchNumber + 1) / Double(batches.count))
        }

        return SubtitleParser.rebuild(cues)
    }

    private func translateBatch(_ lines: [String]) async throws -> [String] {
        let inputJSON = try jsonString(from: lines)
        let sourceHint = sourceLanguage.map { $0.code.isEmpty ? "" : " from \($0.promptName)" } ?? ""

        let system = """
        You are a professional subtitle translator. Translate each string in the \
        provided JSON array\(sourceHint) into \(targetLanguage.promptName). Keep the \
        meaning natural and concise for on-screen subtitles. Respond with ONLY a JSON \
        array of strings containing exactly \(lines.count) elements, in the same order. \
        Do not merge, split, number, or add any commentary. Preserve line breaks within \
        an element using \\n.
        """

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": inputJSON]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranslatorError.transportError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslatorError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.prefix(500).description ?? ""
            throw TranslatorError.requestFailed(http.statusCode, body)
        }

        let content = try extractMessageContent(from: data)
        let translated = try parseJSONArray(from: content)
        guard translated.count == lines.count else {
            throw TranslatorError.countMismatch(expected: lines.count, got: translated.count)
        }
        return translated
    }

    private func jsonString(from array: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: array)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func extractMessageContent(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslatorError.malformedResponse
        }
        return content
    }

    /// Extracts the JSON array of strings from the model's reply, tolerating
    /// surrounding prose or Markdown code fences.
    private func parseJSONArray(from content: String) throws -> [String] {
        guard let start = content.firstIndex(of: "["),
              let end = content.lastIndex(of: "]"),
              start < end else {
            throw TranslatorError.malformedResponse
        }
        let slice = String(content[start...end])
        guard let data = slice.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw TranslatorError.malformedResponse
        }
        return array.map { "\($0)" }
    }
}
