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
    /// When true, prefills an empty think block to suppress reasoning models'
    /// chain-of-thought (huge speedup for models like qwen3.5).
    let disableThinking: Bool

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
            try Task.checkCancellation()
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

    /// Translates a batch and ALWAYS returns one translation per input line.
    /// Uses a keyed JSON protocol (robust to reordering) and repairs any
    /// missing/mismatched entries with per-line requests, so a single model
    /// hiccup never aborts the whole job.
    private func translateBatch(_ lines: [String]) async throws -> [String] {
        let dict = try await requestKeyedTranslation(lines)

        var out = lines
        var missing: [Int] = []
        for i in lines.indices {
            if let t = dict[i]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                out[i] = t
            } else {
                missing.append(i)
            }
        }

        // Repair gaps individually; keep the original text if even that fails.
        for i in missing {
            if let t = try? await translateSingle(lines[i]),
               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out[i] = t
            }
        }
        return out
    }

    /// Asks the model to translate an indexed object and returns index -> text.
    /// The result may be partial; callers fill any gaps.
    private func requestKeyedTranslation(_ lines: [String]) async throws -> [Int: String] {
        var inputObject: [String: String] = [:]
        for (i, line) in lines.enumerated() { inputObject[String(i)] = line }
        let inputJSON = jsonString(fromObject: inputObject)
        let sourceHint = sourceLanguage.map { $0.code.isEmpty ? "" : " from \($0.promptName)" } ?? ""

        let system = """
        You are a professional subtitle translator. The user message is a JSON object \
        mapping string indices to subtitle lines. Translate each value\(sourceHint) into \
        \(targetLanguage.promptName), keeping it natural and concise for on-screen subtitles. \
        Respond with ONLY a JSON object that has the EXACT same keys, where each value is the \
        translation of the matching input value. Do not add, remove, merge, or renumber keys, \
        and do not add commentary. Preserve line breaks within a value using \\n.
        """

        let content = try await chat(system: system, user: inputJSON)
        return parseKeyed(from: content, count: lines.count)
    }

    /// Translates a single line to plain text (used to repair batch gaps).
    private func translateSingle(_ line: String) async throws -> String {
        let sourceHint = sourceLanguage.map { $0.code.isEmpty ? "" : " from \($0.promptName)" } ?? ""
        let system = """
        You are a professional subtitle translator. Translate the user's text\(sourceHint) into \
        \(targetLanguage.promptName). Reply with ONLY the translation, no quotes or commentary.
        """
        let content = try await chat(system: system, user: line)
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Performs a chat-completions request and returns the assistant content.
    private func chat(system: String, user: String) async throws -> String {
        var messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user]
        ]
        if disableThinking {
            // A pre-closed think block makes reasoning models skip thinking.
            messages.append(["role": "assistant", "content": "<think>\n\n</think>\n\n"])
        }

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": messages
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
        return try extractMessageContent(from: data)
    }

    private func jsonString(fromObject object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
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

    /// Parses the model reply (a JSON object keyed by index, or a positional
    /// JSON array as a fallback) into an index -> translation map.
    private func parseKeyed(from content: String, count: Int) -> [Int: String] {
        var result: [Int: String] = [:]

        // Preferred: a JSON object { "0": "...", "1": "..." }.
        if let start = content.firstIndex(of: "{"),
           let end = content.lastIndex(of: "}"),
           start < end,
           let data = String(content[start...end]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                if let index = Int(key), index >= 0, index < count {
                    result[index] = "\(value)"
                }
            }
            if !result.isEmpty { return result }
        }

        // Fallback: a positional JSON array [ "...", "..." ].
        if let start = content.firstIndex(of: "["),
           let end = content.lastIndex(of: "]"),
           start < end,
           let data = String(content[start...end]).data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            for (i, value) in array.enumerated() where i < count {
                result[i] = "\(value)"
            }
        }
        return result
    }
}
