import Foundation
import SheetMusicCore

/// Singleton tables — one per Swift type. Lifetimes are explicit; Kotlin
/// must release every handle it gets, or the score will leak until process
/// exit. Declared outside `#if os(Android)` so host-platform swift-java
/// entry points (e.g. `nativeRenderMidi`) can resolve handles without
/// duplicating the table.
let scoreTable = HandleTable<Score>()

// MARK: - Score lifecycle (swift-java entry points)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeLoadScore(...)` call site. Returns 0 on parse
/// failure or empty input.
public func nativeLoadScore(bytes: Data) -> Int64 {
    guard !bytes.isEmpty else { return 0 }
    do {
        let score = try ScoreBridge.loadScore(bytes: bytes)
        return scoreTable.insert(score)
    } catch {
        return 0
    }
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeReleaseScore(...)` call site. Releases the score
/// handle and its associated layout document cache entry.
public func nativeReleaseScore(handle: Int64) {
    scoreTable.release(handle)
    LayoutDocumentCache.release(handle)
}

#if os(Android)
    import CJNI
    import SheetMusicLayout
    import SheetMusicWireFormat

    /// Reads `workTitle` + `composer` from the score's `metaTags`
    /// dictionary and returns them as a `ScoreMetadataWire` blob
    /// (wire layout: `i32 titleByteLen + UTF-8 + i32 composerByteLen + UTF-8`).
    /// Missing tags return as zero-length strings; an unknown handle
    /// returns an empty byte array.
    @_cdecl("Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeScoreMetadata")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeScoreMetadata(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
    ) -> jbyteArray? {
        guard let env = envPtr.pointee else { return nil }
        guard let score = scoreTable.value(for: scoreHandle) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        let encoded = ScoreMetadataWire(
            title: score.metaTags["workTitle"] ?? "",
            composer: score.metaTags["composer"] ?? "",
        ).encodeToData()
        let array = env.pointee.NewByteArray(envPtr, jsize(encoded.count))
        encoded.withUnsafeBytes { rawBuf in
            let typed = rawBuf.bindMemory(to: jbyte.self)
            env.pointee.SetByteArrayRegion(
                envPtr,
                array,
                0,
                jsize(encoded.count),
                typed.baseAddress,
            )
        }
        return array
    }

    @WireFormat
    struct ScoreMetadataWire {
        var title: String
        var composer: String
    }

    // MARK: - SMuFL font metrics

    @_cdecl("Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeInstallSMuFLMetrics")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeInstallSMuFLMetrics(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ byteArray: jbyteArray,
    ) -> jboolean {
        guard let env = envPtr.pointee else { return 0 }
        let len = env.pointee.GetArrayLength(envPtr, byteArray)
        guard len > 0 else { return 0 }
        var bytes = [UInt8](repeating: 0, count: Int(len))
        bytes.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            base.withMemoryRebound(to: jbyte.self, capacity: Int(len)) { jbytes in
                env.pointee.GetByteArrayRegion(envPtr, byteArray, 0, len, jbytes)
            }
        }
        do {
            let table = try SMuFLMetricsTable.decode(Data(bytes))
            FontMetrics.provider = makeSMuFLMetricsTableProvider(table: table)
            return 1
        } catch {
            return 0
        }
    }

    // MARK: - Layout

    @_cdecl("Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeComputeLayout")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeComputeLayout(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
        _ pageWidthMM: jdouble,
        _ pageHeightMM: jdouble,
    ) -> jbyteArray? {
        guard let env = envPtr.pointee else { return nil }
        guard let score = scoreTable.value(for: scoreHandle) else {
            return env.pointee.NewByteArray(envPtr, 0)
        }
        let result = LayoutBridge.computeWithDocument(
            score: score,
            pageWidthMM: pageWidthMM,
            pageHeightMM: pageHeightMM,
        )
        LayoutDocumentCache.store(handle: scoreHandle, document: result.document)
        let encoded = result.encoded
        let array = env.pointee.NewByteArray(envPtr, jsize(encoded.count))
        encoded.withUnsafeBytes { rawBuf in
            let typed = rawBuf.bindMemory(to: jbyte.self)
            env.pointee.SetByteArrayRegion(
                envPtr,
                array,
                0,
                jsize(encoded.count),
                typed.baseAddress,
            )
        }
        return array
    }
#endif
