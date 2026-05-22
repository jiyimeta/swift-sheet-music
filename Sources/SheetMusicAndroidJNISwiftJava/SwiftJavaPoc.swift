import Foundation
import SheetMusicAndroidJNI

public func sheetMusicSwiftJavaPing() -> Int64 {
    42
}

public func sheetMusicSwiftJavaEcho(value: Int64) -> Int64 {
    value
}

/// Mirror of `SheetMusicAudioJNI.nativeGMInstrumentList()` reached via the
/// swift-java jextract bridge instead of hand-written `@_cdecl`.
/// Returns the same bytes — Kotlin can decode either with the existing
/// `GMInstrumentCodec`.
public func swiftJavaGMInstrumentList() -> Data {
    GMInstrumentCodec.encodeAll()
}
