package io.github.jiyimeta.sheetmusic

/**
 * Thin façade over the @_cdecl symbols exported by
 * Sources/SheetMusicAndroidJNI/JNISymbols.swift +
 * Sources/SheetMusicAndroidJNI/CursorBridge.swift.
 *
 * Symbol names map to the JNI convention:
 *   io.github.jiyimeta.sheetmusic.SheetMusicJNI.<name>
 *       → Java_io_github_jiyimeta_sheetmusic_SheetMusicJNI_<name>
 *
 * The companion's init also loads libSheetMusicJNI; consumers that
 * link this module transitively (e.g. SheetMusicAudioAndroid) inherit
 * the loaded native library.
 */
object SheetMusicJNI {

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

    /**
     * Resolve the bounding rectangle (document/mm coordinates) of the cursor
     * identified by [cursorBytes] within the laid-out score [scoreHandle].
     *
     * Returns a 34-byte payload in the CursorFrame wire format on success, or
     * an empty array if the cursor did not resolve (e.g. stale ID after
     * re-layout). Wire format: u16 version (=1), then 4 × i64 micros
     * (x, y, width, height), little-endian.
     */
    @JvmStatic external fun nativeCursorFrame(
        scoreHandle: Long,
        cursorBytes: ByteArray,
    ): ByteArray
}
