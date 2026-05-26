package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.GMInstrument
import io.github.jiyimeta.wirelet.BinaryReader
import io.github.jiyimeta.wirelet.WireType

/**
 * Decodes the `[GMInstrument]` blob produced by Swift's
 * `GMInstrumentCodec.encodeAll()` (i.e. `GMInstrument.all.encodeToData()`).
 *
 * Swift's `@WireFormat` on `GMInstrument` and `@WireFormatEnum` on
 * `GMInstrument.Family` produce wirelet TLV bytes with the following layout:
 *
 * ```
 * varint arrayPayloadLen          ← outer Array<T> length prefix
 * arrayPayloadLen bytes {
 *   N × {
 *     varint itemPayloadLen       ← per-item struct length prefix
 *     itemPayloadLen bytes {
 *       tag(1, VARINT)  varint program      0..127 (UInt8)
 *       tag(2, LEN)     varint nameLen  + nameLen UTF-8 bytes
 *       tag(3, LEN)     varint rawLen   + rawLen  UTF-8 bytes  ← Family rawValue
 *                                                               e.g. "Piano"
 *     }
 *   }
 * }
 * ```
 *
 * `GMInstrument.Family` is a `String`-raw enum, so `@WireFormatEnum` encodes
 * its `rawValue` as a length-delimited string (not a numeric ordinal). The
 * ordinal stored in [GMInstrument.familyIndex] is derived here by looking up
 * the rawValue string in the canonical family order.
 *
 * No version envelope — the `.so` and `.aar` ship together from the same
 * git commit, so a wire mismatch would already manifest as a structural
 * decode failure, not a missed version assertion.
 */
internal object GMInstrumentDecoder {

    /**
     * Canonical order mirrors Swift's `GMInstrument.Family.allCases`
     * (declaration order, which `CaseIterable` preserves).
     */
    private val familyRawValues = listOf(
        "Piano",
        "Chromatic Percussion",
        "Organ",
        "Guitar",
        "Bass",
        "Strings",
        "Ensemble",
        "Brass",
        "Reed",
        "Pipe",
        "Synth Lead",
        "Synth Pad",
        "Synth Effects",
        "Ethnic",
        "Percussive",
        "Sound Effects",
    )

    fun decodeArray(bytes: ByteArray): List<GMInstrument> {
        val outerReader = BinaryReader(bytes)
        val out = mutableListOf<GMInstrument>()
        outerReader.readLengthPrefixed { arrayReader ->
            while (arrayReader.remaining > 0) {
                arrayReader.readLengthPrefixed { itemReader ->
                    var program = 0
                    var name = ""
                    var familyRaw = ""
                    while (itemReader.remaining > 0) {
                        val (tag, wt) = itemReader.readTag()
                        when (tag) {
                            1 -> program = itemReader.readVarint().toInt()
                            2 -> name = itemReader.readLengthPrefixed { r ->
                                r.readBytes(r.remaining).toString(Charsets.UTF_8)
                            }
                            3 -> familyRaw = itemReader.readLengthPrefixed { r ->
                                r.readBytes(r.remaining).toString(Charsets.UTF_8)
                            }
                            else -> itemReader.skipUnknownField(wt)
                        }
                    }
                    val familyIndex = familyRawValues.indexOf(familyRaw).takeIf { it >= 0 } ?: 0
                    out.add(
                        GMInstrument(
                            program = program,
                            displayName = name,
                            familyIndex = familyIndex,
                        ),
                    )
                }
            }
        }
        return out
    }
}
