package io.github.jiyimeta.sheetmusic

/** Auto-releasing wrapper around a native score handle. */
class ScoreHandle internal constructor(val raw: Long) : AutoCloseable {
    private var closed = false

    override fun close() {
        if (!closed) {
            SheetMusicJNI.nativeReleaseScore(raw)
            closed = true
        }
    }

    protected fun finalize() { close() }

    companion object {
        /** Returns null if Swift parsing failed. */
        fun load(bytes: ByteArray): ScoreHandle? {
            val raw = SheetMusicJNI.nativeLoadScore(bytes)
            return if (raw == 0L) null else ScoreHandle(raw)
        }
    }
}
