#if !os(macOS)
    import SwiftUI

    @main
    struct SheetMusicExampleApp: App {
        init() {
            EdwinFontLoader.registerOnce()
        }

        var body: some Scene {
            WindowGroup {
                ContentView()
            }
        }
    }
#endif
