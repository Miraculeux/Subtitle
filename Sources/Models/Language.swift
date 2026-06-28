import Foundation

/// A spoken language option used for transcription (source) and translation (target).
struct Language: Identifiable, Hashable {
    let code: String       // ISO-639-1 code; "" means auto/none
    let name: String       // English display name
    let nativeName: String // localized label shown in pickers

    var id: String { code }

    var displayName: String {
        if code.isEmpty { return nativeName }
        return "\(nativeName) (\(name))"
    }

    /// Used in the translation prompt to name the target language clearly.
    var promptName: String { name }

    /// Sentinel meaning "let Whisper auto-detect the source language".
    static let auto = Language(code: "", name: "Auto", nativeName: "自动检测")

    /// Sentinel meaning "do not translate".
    static let none = Language(code: "", name: "None", nativeName: "不翻译")

    /// Common languages supported by Whisper.
    static let all: [Language] = [
        Language(code: "zh", name: "Chinese", nativeName: "中文"),
        Language(code: "en", name: "English", nativeName: "English"),
        Language(code: "ja", name: "Japanese", nativeName: "日本語"),
        Language(code: "ko", name: "Korean", nativeName: "한국어"),
        Language(code: "es", name: "Spanish", nativeName: "Español"),
        Language(code: "fr", name: "French", nativeName: "Français"),
        Language(code: "de", name: "German", nativeName: "Deutsch"),
        Language(code: "ru", name: "Russian", nativeName: "Русский"),
        Language(code: "pt", name: "Portuguese", nativeName: "Português"),
        Language(code: "it", name: "Italian", nativeName: "Italiano"),
        Language(code: "ar", name: "Arabic", nativeName: "العربية"),
        Language(code: "hi", name: "Hindi", nativeName: "हिन्दी"),
        Language(code: "tr", name: "Turkish", nativeName: "Türkçe"),
        Language(code: "nl", name: "Dutch", nativeName: "Nederlands"),
        Language(code: "pl", name: "Polish", nativeName: "Polski"),
        Language(code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt"),
        Language(code: "th", name: "Thai", nativeName: "ไทย"),
        Language(code: "id", name: "Indonesian", nativeName: "Indonesia"),
        Language(code: "uk", name: "Ukrainian", nativeName: "Українська")
    ]

    /// Options for the source picker: auto-detect followed by all languages.
    static var sourceOptions: [Language] { [auto] + all }

    /// Options for the target picker: "no translation" followed by all languages.
    static var targetOptions: [Language] { [none] + all }

    static func named(forCode code: String) -> String {
        all.first(where: { $0.code == code })?.name ?? code
    }
}
