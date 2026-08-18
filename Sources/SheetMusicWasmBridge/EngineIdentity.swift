import JavaScriptKit
import SheetMusicCore

/// This image's build identity. A host compares it with its own before it
/// trusts a cached layout or opens an edit session.
///
/// Android: `nativeEngineVersionStamp`.
///
/// The stamp is an `Int64` on the Android side. BridgeJS lowers `Int64` to a
/// JavaScript `bigint`, which is awkward for a value the host only ever
/// compares for equality, so the wasm surface narrows it to `Int` (i32). The
/// stamp is a small monotonic build counter, not a hash, so the narrowing
/// cannot lose information.
@JS public func engineVersionStamp() -> Int {
    Int(SheetMusicEngine.versionStamp)
}
