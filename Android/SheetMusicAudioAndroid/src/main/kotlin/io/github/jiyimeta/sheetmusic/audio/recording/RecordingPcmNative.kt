package io.github.jiyimeta.sheetmusic.audio.recording

import io.github.jiyimeta.sheetmusic.swiftjava.SheetMusicAndroidJNI as SwiftJavaJNI

/**
 * The Swift writer of the PCM cache file a recording plays from (`RecordingPCMCacheWriter`, the one definition of
 * `RecordingPCMCacheFormat` — the file Apple's `RecordingPCMCache` writes). [RecordingPcmDecoder] decodes with
 * MediaCodec and hands the samples here, so the format is written in one place.
 */
internal interface RecordingPcmWriterCalls {
    /** The path of a valid cache file for [cacheKey] at [sampleRate] in [directory], or "" when there is none. */
    fun existing(directory: String, cacheKey: String, sampleRate: Double): String

    /** A writer for [cacheKey] at [sampleRate] in [directory]; 0 when the rate is refused or the file cannot be made. */
    fun open(directory: String, cacheKey: String, sampleRate: Double): Long

    /** Appends [frameCount] frames of [channels] (1 or 2) interleaved samples; 0, or -1 when the write failed. */
    fun append(writer: Long, samples: ShortArray, frameCount: Int, channels: Int): Int

    /** Writes the header and moves the file into place: its path, or "" on failure. Releases the writer. */
    fun finish(writer: Long): String

    /** Abandons the file and releases the writer. */
    fun cancel(writer: Long)
}

internal object RecordingPcmNative : RecordingPcmWriterCalls {
    init { System.loadLibrary("SheetMusicAndroidJNI") }

    /**
     * Hand-written JNI (`RecordingRenderJNI.swift`), so a decoded buffer crosses without being copied into a Swift
     * array first.
     */
    external fun nativeAppend(writer: Long, samples: ShortArray, frameCount: Int, channels: Int): Int

    override fun existing(directory: String, cacheKey: String, sampleRate: Double): String =
        SwiftJavaJNI.nativeRecordingCacheExisting(directory, cacheKey, sampleRate)

    override fun open(directory: String, cacheKey: String, sampleRate: Double): Long =
        SwiftJavaJNI.nativeRecordingCacheWriterOpen(directory, cacheKey, sampleRate)

    override fun append(writer: Long, samples: ShortArray, frameCount: Int, channels: Int): Int =
        nativeAppend(writer, samples, frameCount, channels)

    override fun finish(writer: Long): String = SwiftJavaJNI.nativeRecordingCacheWriterFinish(writer)

    override fun cancel(writer: Long) = SwiftJavaJNI.nativeRecordingCacheWriterCancel(writer)
}
