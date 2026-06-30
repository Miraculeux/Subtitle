import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = TranscriptionViewModel()
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .onAppear { model.attach(settings: settings) }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted && !model.isRunning {
                dropOverlay
            }
        }
    }

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                .padding(8)
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 38))
                Text("Drop video or audio file to transcribe")
                    .font(.headline)
            }
            .foregroundStyle(.tint)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isRunning,
              let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) })
        else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL else { return }
            DispatchQueue.main.async { model.setVideo(url: url) }
        }
        return true
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Subtitle")
                    .font(.headline)
                Text("Extract audio and generate subtitles with local Whisper")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            filePicker
            languageBar
            progressSection

            Text("Subtitles")
                .font(.subheadline.weight(.semibold))

            TextEditor(text: $model.subtitleText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filePicker: some View {
        HStack(spacing: 12) {
            Button {
                model.selectVideo()
            } label: {
                Label("Choose Video…", systemImage: "film")
            }
            .disabled(model.isRunning)

            Text(model.videoURL?.lastPathComponent ?? "No file selected — or drag a file here")
                .font(.callout)
                .foregroundStyle(model.videoURL == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if model.canCancel {
                Button(role: .cancel) {
                    model.cancel()
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
            }

            Button {
                model.start()
            } label: {
                Label("Generate", systemImage: "waveform")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStart)
        }
    }

    private var languageBar: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $settings.sourceLanguage) {
                ForEach(Language.sourceOptions) { lang in
                    Text(lang.displayName).tag(lang.code)
                }
            }
            .frame(maxWidth: 220)

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Target", selection: $settings.targetLanguage) {
                ForEach(Language.targetOptions) { lang in
                    Text(lang.displayName).tag(lang.code)
                }
            }
            .frame(maxWidth: 220)

            if settings.translationEnabled {
                Toggle("Bilingual", isOn: $settings.bilingualOutput)
                    .toggleStyle(.checkbox)
            }

            Spacer()
        }
        .disabled(model.isRunning)
    }

    @ViewBuilder
    private var progressSection: some View {
        switch model.stage {
        case .extractingAudio:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: model.extractionProgress) {
                    Text("Extracting audio…")
                        .font(.caption)
                }
            }
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing with Whisper…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .translating:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: model.translationProgress) {
                    Text("Translating…")
                        .font(.caption)
                }
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if model.canRetry {
                    Button {
                        model.retry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            }
        default:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
