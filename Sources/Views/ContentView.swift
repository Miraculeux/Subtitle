import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = TranscriptionViewModel()
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .onAppear { model.attach(settings: settings) }
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

            ScrollView {
                TextEditor(text: $model.subtitleText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
            }
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

            Text(model.videoURL?.lastPathComponent ?? "No file selected")
                .font(.callout)
                .foregroundStyle(model.videoURL == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

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
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
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
            Spacer()
            Button {
                model.saveSubtitle()
            } label: {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .disabled(model.subtitleText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
