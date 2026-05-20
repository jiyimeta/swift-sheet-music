#if os(Android)
    import CJNI
    import Foundation
    import SheetMusicCore
    import SheetMusicLayout

    /// Singleton tables — one per Swift type. Lifetimes are explicit; Kotlin
    /// must release every handle it gets, or the score will leak until process
    /// exit.
    let scoreTable = HandleTable<Score>()

    // MARK: - Score lifecycle

    @_cdecl("Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeLoadScore")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeLoadScore(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ byteArray: jbyteArray,
    ) -> jlong {
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
        let data = Data(bytes)
        do {
            let score = try ScoreBridge.loadScore(bytes: data)
            return scoreTable.insert(score)
        } catch {
            return 0
        }
    }

    @_cdecl("Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeReleaseScore")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_nativeReleaseScore(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ handle: jlong,
    ) {
        scoreTable.release(handle)
        LayoutDocumentCache.release(handle)
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
            FontMetrics.provider = SMuFLMetricsTableProvider(table: table)
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
