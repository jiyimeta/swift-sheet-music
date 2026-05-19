#if os(Android)
    import CJNI
    import Foundation
    import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicMIDI

    // Audio JNI bridge entry points. Each @_cdecl below is callable from
    // the Kotlin class `io.github.kiichiio.sheetmusic.audio.jni.SheetMusicAudioJNI`
    // after `System.loadLibrary("SheetMusicJNI")`.
    //
    // Score handles are resolved against the existing `scoreTable` in
    // `JNISymbols.swift`.

    enum AudioMidiBridge {
        // Helpers + @_cdecl entry points are appended by Phase 3 / Phase 4
        // tasks (codec implementation, render, timeline, etc.). This file
        // is a deliberate empty shell to anchor the imports and namespace.
    }
#endif
