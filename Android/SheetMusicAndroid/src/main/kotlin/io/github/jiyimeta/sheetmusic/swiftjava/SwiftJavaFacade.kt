package io.github.jiyimeta.sheetmusic.swiftjava

import org.swift.swiftkit.core.SwiftMemoryManagement

/**
 * Kotlin façade over the swift-java-generated [SheetMusicAndroidJNISwiftJava]
 * class. PoC adoption — see `project_swift_java_strategy.md`.
 *
 * The hand-written JNI bridge in
 * [io.github.jiyimeta.sheetmusic.SheetMusicJNI] remains the production path
 * for now. New JNI entries should prefer this route once the strategy is
 * fully validated.
 */
object SwiftJavaFacade {
    /** Smoke test: returns 42. */
    fun ping(): Long = SheetMusicAndroidJNISwiftJava.sheetMusicSwiftJavaPing()

    /** Smoke test: returns the input unchanged. */
    fun echo(value: Long): Long = SheetMusicAndroidJNISwiftJava.sheetMusicSwiftJavaEcho(value)

    /**
     * Bytes are identical to the hand-written
     * `SheetMusicAudioJNI.nativeGMInstrumentList()` in the
     * `SheetMusicAudioAndroid` module — both call the same
     * `GMInstrumentCodec.encodeAll()` in Swift. Decode via the existing
     * codec on the Kotlin side.
     */
    fun gmInstrumentList(): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SheetMusicAndroidJNISwiftJava.swiftJavaGMInstrumentList(arena).toByteArray()
    }
}
