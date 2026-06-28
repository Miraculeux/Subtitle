import Foundation

/// A single subtitle entry: the lines that precede the text (index + timestamp)
/// are preserved verbatim so translation never disturbs the timeline.
struct SubtitleCue {
    var header: [String]   // index line and/or "00:00:01,000 --> 00:00:04,000"
    var text: String       // spoken text (may span multiple lines)
    let hasTiming: Bool     // false for blocks like the leading "WEBVTT"
}

/// Minimal SRT/WebVTT parser focused on preserving structure while allowing
/// the text portion of each cue to be replaced (e.g. with a translation).
enum SubtitleParser {
    static func parse(_ content: String) -> [SubtitleCue] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []

        for block in blocks {
            let trimmedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBlock.isEmpty { continue }

            let lines = block.components(separatedBy: "\n")
            if let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) {
                let header = Array(lines[0...timingIndex])
                let textLines = Array(lines[(timingIndex + 1)...])
                let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                cues.append(SubtitleCue(header: header, text: text, hasTiming: true))
            } else {
                // Non-timed block (e.g. "WEBVTT" header) — keep as-is.
                cues.append(SubtitleCue(header: lines, text: "", hasTiming: false))
            }
        }
        return cues
    }

    static func rebuild(_ cues: [SubtitleCue]) -> String {
        var blocks: [String] = []
        for cue in cues {
            if cue.hasTiming {
                var lines = cue.header
                if !cue.text.isEmpty {
                    lines.append(cue.text)
                }
                blocks.append(lines.joined(separator: "\n"))
            } else {
                blocks.append(cue.header.joined(separator: "\n"))
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }
}
