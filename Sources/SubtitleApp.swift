import SwiftUI

@main
struct SubtitleApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .frame(minWidth: 760, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .frame(width: 460)
        }
    }
}
