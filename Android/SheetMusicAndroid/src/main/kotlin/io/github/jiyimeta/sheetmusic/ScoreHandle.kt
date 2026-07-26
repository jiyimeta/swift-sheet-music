package io.github.jiyimeta.sheetmusic

import io.github.jiyimeta.wirelet.WireFormatException

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
 * the cursor / hit-test lookups take.
 *
 * The caller must release this — call [close] (or use `.use { }`) once done with both handles. There is
 * no finalizer: a finalizer here would run on whichever thread the GC picks, and if the caller had
 * already dropped this wrapper while still holding onto [score] (e.g. `val s = PdfScoreHandle.load(bytes)!!.score`),
 * that finalizer would call `close()` and release a [score] the caller still considers live, turning
 * every later bridge call on it into a silent no-op. Dropping a [PdfScoreHandle] without closing it
 * leaks the geometry handle (and, if [score] is also unreferenced elsewhere, the score handle too) until
 * process exit — the same contract every other handle in this module follows.
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
            val wire = try {
                PdfParseResultWireCodec.decode(blob)
            } catch (e: WireFormatException) {
                // A malformed blob means version skew between this Kotlin codec and the Swift side that
                // produced it. Whatever handles Swift allocated before encoding are still live on the
                // native side, but their values never made it into `wire` — we cannot recover or release
                // them, so this leaks both the score and geometry handles until process exit. That is a
                // strictly better failure than trusting a partially-decoded value and releasing (or
                // operating on) a handle we only half-read.
                return null
            }
            if (wire.scoreHandle == 0L || wire.geometryHandle == 0L) {
                // Defensive: Swift only inserts both handles after a successful parse, so this pair is
                // never actually asymmetric today. Release whichever handle IS non-zero anyway, so a
                // future asymmetric result can't leak it.
                if (wire.scoreHandle != 0L) SheetMusicJNI.nativeReleaseScore(wire.scoreHandle)
                if (wire.geometryHandle != 0L) SheetMusicJNI.nativeReleasePdfGeometry(wire.geometryHandle)
                return null
            }
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
