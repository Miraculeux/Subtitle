# Subtitle

A native macOS (SwiftUI) app that lets you pick a video file, extracts its audio
track, and generates subtitles using a **local, open-source Whisper** model.
The Whisper service address is fully configurable.

## How it works

1. **Pick a video** (or audio) file via the system file panel.
2. The app extracts the audio track with **AVFoundation** and re-encodes it to
   16 kHz mono 16-bit WAV — the format Whisper models expect.
3. The WAV is sent to your local Whisper server's OpenAI-compatible
   `POST /v1/audio/transcriptions` endpoint.
4. The returned subtitles (SRT or VTT) are shown and can be saved to disk.

After transcription and optional translation finish successfully, the extracted
WAV is deleted unless **Keep extracted audio after finishing** is enabled in
Settings. Retained audio also survives switching files or clearing the queue.
Original input files are never deleted. Failed or cancelled jobs retain their
working audio for retry. The transcript remains available for re-translation;
re-running transcription extracts audio again if it has been cleaned up.

## Configuring the Whisper server

Open **Settings** (⌘,) and set:

- **Server address** — base URL of your local server, e.g. `http://127.0.0.1:8080`.
  (You may also paste the full `/v1/audio/transcriptions` URL.)
- **Model** — e.g. `whisper-1`, `base`, `large-v3` (depends on your server).
- **API key** — optional; leave empty for most local servers.
- **Language** — optional ISO code (`zh`, `en`, `ja`); empty = auto-detect.
- **Subtitle format** — SubRip (`.srt`) or WebVTT (`.vtt`).

### Compatible local servers

Any server exposing the OpenAI audio transcription API works, for example:

- [`whisper.cpp`](https://github.com/ggerganov/whisper.cpp) server build
  (`./server --host 127.0.0.1 --port 8080 -m models/ggml-base.bin`)
- [`faster-whisper-server`](https://github.com/fedirz/faster-whisper-server)
- [LocalAI](https://github.com/mudler/LocalAI)

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

Debug and Release builds treat Swift and C/Objective-C compiler warnings as errors.

```bash
xcodegen generate
open Subtitle.xcodeproj   # then Run in Xcode
```

Or build from the command line:

```bash
xcodegen generate
xcodebuild -project Subtitle.xcodeproj -scheme Subtitle \
  -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/Subtitle.app
```

## Audio cleanup regression tests

The standalone tests exercise the real pipeline with mocked transcription and
translation responses; no running model servers are required.

```bash
swiftc -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
  -parse-as-library Sources/Models/*.swift Sources/Services/*.swift \
  Tests/AudioCleanupTests.swift -o build/audio-cleanup-tests
build/audio-cleanup-tests
```

## Project layout

```
project.yml                     XcodeGen project definition
Sources/
  SubtitleApp.swift             App entry point + Settings scene
  Info.plist                    Bundle config (allows local HTTP networking)
  Models/
    AppSettings.swift           Persisted server/model configuration
    TranscriptionViewModel.swift  Pipeline orchestration & state
  Services/
    AudioExtractor.swift        Video → 16 kHz mono WAV (AVFoundation)
    WhisperClient.swift         Multipart upload to Whisper endpoint
  Views/
    ContentView.swift           Main window UI
    SettingsView.swift          Configuration UI
```
