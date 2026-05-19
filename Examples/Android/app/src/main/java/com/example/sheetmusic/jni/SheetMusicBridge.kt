package com.example.sheetmusic.jni

/**
 * Thin façade over the @_cdecl symbols exported by
 * Sources/SheetMusicAndroidJNI/JNISymbols.swift. All methods are JNI;
 * keep symbol names in lockstep (com.example.sheetmusic.jni.SheetMusicBridge
 * maps to Java_com_example_sheetmusic_jni_SheetMusicBridge_<name>).
 */
object SheetMusicBridge {

    init { System.loadLibrary("SheetMusicJNI") }

    /** Returns 0 on parse failure. */
    @JvmStatic external fun nativeLoadScore(bytes: ByteArray): Long

    @JvmStatic external fun nativeReleaseScore(handle: Long)

    /** Returns an empty array on failure (e.g. invalid handle). */
    @JvmStatic external fun nativeComputeLayout(
        scoreHandle: Long,
        pageWidthMM: Double,
        pageHeightMM: Double,
    ): ByteArray

    /**
     * Install a SMuFL glyph-metrics table on the Swift side. Returns
     * `true` on success, `false` if the byte format is invalid. Wire
     * format spec is on `Sources/SheetMusicAndroidJNI/SMuFLMetricsTable.swift`.
     */
    @JvmStatic external fun nativeInstallSMuFLMetrics(bytes: ByteArray): Boolean
}
