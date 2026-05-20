import Foundation
import SheetMusicCore

// Cursor-frame JNI bridge. The testable logic (`LayoutDocumentCache`,
// `CursorFrameCodec`) is outside `#if os(Android)` so host tests can
// exercise the codec path directly. The `@_cdecl` entry point is
// Android-only.

#if os(Android)
    import CJNI
    import SheetMusicLayout

    @_cdecl("Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeCursorFrame")
    // swiftlint:disable:next identifier_name
    public func Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeCursorFrame(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
        _ cursorBytes: jbyteArray,
    ) -> jbyteArray? {
        guard let env = envPtr.pointee else { return nil }
        guard scoreTable.value(for: scoreHandle) != nil,
              let document = LayoutDocumentCache.value(for: scoreHandle)
        else { return env.pointee.NewByteArray(envPtr, 0) }
        let data = readJByteArray(env: envPtr, array: cursorBytes)
        guard let cursor = try? ScoreCursorCodec.decode(data) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        guard let score = scoreTable.value(for: scoreHandle) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        guard let rect = document.cursorFrame(for: cursor, in: score) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        // SheetMusicLayout works in typographic points (pt); LayoutBridge
        // converts DrawCommands to mm before encoding. Apply the same
        // conversion here so the cursor frame is in mm — the unit the
        // Kotlin overlay multiplies by pxPerMM to reach screen pixels.
        // On Android SheetMusicLayout.CGRect is a stub type distinct from
        // any Foundation.CGRect shim. Pass component doubles directly so
        // CursorFrameCodec.encode receives its expected type.
        let ptToMM = 25.4 / 72.0
        let encoded = CursorFrameCodec.encodeComponents(
            x: Double(rect.origin.x) * ptToMM,
            y: Double(rect.origin.y) * ptToMM,
            width: Double(rect.size.width) * ptToMM,
            height: Double(rect.size.height) * ptToMM,
        )
        return makeJByteArray(env: envPtr, bytes: encoded)
    }
#endif
