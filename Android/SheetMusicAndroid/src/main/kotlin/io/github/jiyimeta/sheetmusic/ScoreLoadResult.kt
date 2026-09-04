package io.github.jiyimeta.sheetmusic

/**
 * One non-fatal finding from the parser.
 *
 * The parsers in this library are permissive by design: an unknown tremolo
 * subtype or an unrepresentable ornament is *dropped* so the rest of the score
 * still loads. That is almost always the right trade, but it means a file can
 * come back subtly poorer than it went in, and this is the only way a host
 * finds out.
 *
 * @property code stable dotted identifier, e.g. `mscx.tremolo.unknownSubtype`.
 *   This is the localization key. [message] is not — it is English log text.
 * @property location best-effort, e.g. `measure 12, voice 1, Tremolo`. Empty
 *   when the parser could not derive one cheaply.
 */
data class ScoreDiagnostic(
    val isWarning: Boolean,
    val code: String,
    val message: String,
    val location: String,
) {
    /** Notable but expected, rather than something the user lost. */
    val isInfo: Boolean get() = !isWarning
}

/**
 * What [ScoreHandle.loadWithDiagnostics] found: the score if it parsed, why it
 * did not if it did not, and anything the parser dropped along the way.
 *
 * [ScoreHandle.load] collapses all of this into `null`, which tells a host that
 * something went wrong and nothing about what — a corrupt ZIP, an unrecognized
 * format and a structurally invalid measure are one answer.
 */
data class ScoreLoadResult(
    /** The parsed score, or `null` on failure. The caller owns it and must [ScoreHandle.close] it. */
    val handle: ScoreHandle?,
    /**
     * Stable dotted identifier for the failure, or `null` on success — e.g.
     * `bridge.scoreFormat.unrecognized`, `zip.corrupted`, `mscx.timeSig.missingSigN`.
     * Switch on this; it is the localization key.
     */
    val faultCode: String?,
    /** English text for logs. Never UI copy. `null` on success. */
    val faultMessage: String?,
    /**
     * Non-fatal findings. Only MuseScore payloads produce these — MusicXML has
     * no equivalent channel and the MIDI importer none either, so an empty list
     * from those formats means "not reported", not "nothing happened".
     */
    val diagnostics: List<ScoreDiagnostic>,
) {
    val isSuccess: Boolean get() = handle != null

    companion object {
        /**
         * Parse [bytes] into a score, reporting why it failed and what the
         * parser dropped.
         *
         * Accepts every format [ScoreHandle.load] does — `.mscx`, `.mscz`,
         * `.musicxml`, `.mxl`, `.mid` — chosen by sniffing the leading bytes
         * rather than by any file extension the caller supplies.
         */
        fun load(bytes: ByteArray): ScoreLoadResult {
            val blob = SheetMusicJNI.nativeLoadScoreWithDiagnostics(bytes)
            if (blob.isEmpty()) {
                // Unreachable: the Swift side always encodes a decodable result, using
                // `scoreHandle == 0` plus a fault code for failure rather than an empty blob.
                // Reported as a fault of its own rather than silently as "unrecognized", so a
                // version skew between this codec and the .so does not masquerade as a bad file.
                return ScoreLoadResult(null, "bridge.scoreLoad.emptyResult", "empty result blob", emptyList())
            }
            val wire = try {
                ScoreLoadResultWireCodec.decode(blob)
            } catch (e: Exception) {
                // Caught as `Exception`, not `WireFormatException`: a truncated blob bottoms out in
                // `BinaryReader.readU8`, which throws `BinaryReader.UnderflowException` — a SIBLING
                // of `WireFormatException`, not a subtype — so the narrower catch would let exactly
                // the skew case this guard exists for escape uncaught. Same reasoning as
                // `PdfScoreHandle.load`.
                //
                // A handle Swift may have inserted before encoding is unreachable now and leaks
                // until process exit. That is strictly better than trusting a half-read value and
                // releasing a handle we did not actually read.
                return ScoreLoadResult(null, "bridge.scoreLoad.undecodable", e.toString(), emptyList())
            }
            return ScoreLoadResult(
                handle = if (wire.scoreHandle == 0L) null else ScoreHandle(wire.scoreHandle),
                faultCode = wire.faultCode.ifEmpty { null },
                faultMessage = wire.faultMessage.ifEmpty { null },
                diagnostics = wire.diagnostics.map {
                    ScoreDiagnostic(
                        isWarning = it.severity == 1,
                        code = it.code,
                        message = it.message,
                        location = it.location,
                    )
                },
            )
        }
    }
}
