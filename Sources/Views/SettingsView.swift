import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Whisper Server") {
                TextField("Server address", text: $settings.serverURL,
                          prompt: Text("http://127.0.0.1:8080"))
                    .textFieldStyle(.roundedBorder)
                Text("Base URL of your local Whisper server. The app posts to its OpenAI-compatible `/v1/audio/transcriptions` endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Model", text: $settings.modelName,
                          prompt: Text("whisper-1"))
                    .textFieldStyle(.roundedBorder)

                TextField("API key (optional)", text: $settings.apiKey,
                          prompt: Text("Leave empty for local servers"))
                    .textFieldStyle(.roundedBorder)
            }

            Section("Languages") {
                Picker("Source language", selection: $settings.sourceLanguage) {
                    ForEach(Language.sourceOptions) { lang in
                        Text(lang.displayName).tag(lang.code)
                    }
                }

                Picker("Target language", selection: $settings.targetLanguage) {
                    ForEach(Language.targetOptions) { lang in
                        Text(lang.displayName).tag(lang.code)
                    }
                }
                Text("Choose a target language to translate the subtitles after transcription. Select \u{201C}不翻译\u{201D} to keep the original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Subtitle format", selection: $settings.responseFormat) {
                    ForEach(ResponseFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
            }

            if settings.translationEnabled {
                Section("Translation Server") {
                    TextField("Server address", text: $settings.translationServerURL,
                              prompt: Text("http://127.0.0.1:1234"))
                        .textFieldStyle(.roundedBorder)
                    Text("Base URL of an OpenAI-compatible chat server (LM Studio, Ollama, llama.cpp, LocalAI). Posts to `/v1/chat/completions`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Model", text: $settings.translationModel,
                              prompt: Text("Qwen3.5-9B-MLX-8bit"))
                        .textFieldStyle(.roundedBorder)

                    TextField("API key (optional)", text: $settings.translationApiKey,
                              prompt: Text("Leave empty for local servers"))
                        .textFieldStyle(.roundedBorder)

                    Toggle("Bilingual subtitles (original + translation)", isOn: $settings.bilingualOutput)

                    if settings.bilingualOutput {
                        Picker("Line order", selection: $settings.originalOnTop) {
                            Text("Original on top").tag(true)
                            Text("Translation on top").tag(false)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
