#if os(macOS)
    import SwiftUI

    @main
    struct SheetMusicExampleMacApp: App {
        init() {
            EdwinFontLoader.registerOnce()
        }

        var body: some Scene {
            WindowGroup {
                ContentViewMac()
            }
            .defaultSize(width: 1200, height: 720)
        }
    }
#endif
