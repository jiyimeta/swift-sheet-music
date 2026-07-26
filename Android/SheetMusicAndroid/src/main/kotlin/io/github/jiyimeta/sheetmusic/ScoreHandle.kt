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

        /** Parse a MuseScore-exported PDF. Returns null if parsing failed. */
        fun loadFromPDF(bytes: ByteArray): ScoreHandle? {
            val raw = SheetMusicJNI.nativeLoadScoreFromPDF(bytes)
            return if (raw == 0L) null else ScoreHandle(raw)
        }
    }
}

/** One best-effort diagnostic from the PDF importer. */
data class PdfDiagnostic(val isWarning: Boolean, val location: String, val message: String)

/**
 * A PDF parsed for playback: the score handle every playback bridge accepts, plus the geometry handle
 * the cursor / hit-test lookups take. Closing releases both.
 */
class PdfScoreHandle internal constructor(
    val score: ScoreHandle,
    val geometryHandle: Long,
    val diagnostics: List<PdfDiagnostic>,
) : AutoCloseable {
    private var closed = false

    override fun close() {
        if (!closed) {
            SheetMusicJNI.nativeReleasePdfGeometry(geometryHandle)
            score.close()
            closed = true
        }
    }

    companion object {
        /** Returns null when the bytes are not a parseable PDF or nothing decoded. */
        fun load(bytes: ByteArray): PdfScoreHandle? {
            val blob = SheetMusicJNI.nativeLoadScoreWithGeometryFromPDF(bytes)
            if (blob.isEmpty()) return null
            val wire = PdfParseResultWireCodec.decode(blob)
            if (wire.scoreHandle == 0L || wire.geometryHandle == 0L) return null
            return PdfScoreHandle(
                score = ScoreHandle(wire.scoreHandle),
                geometryHandle = wire.geometryHandle,
                diagnostics = wire.diagnostics.map {
                    PdfDiagnostic(isWarning = it.severity == 1, location = it.location, message = it.message)
                },
            )
        }
    }
}
