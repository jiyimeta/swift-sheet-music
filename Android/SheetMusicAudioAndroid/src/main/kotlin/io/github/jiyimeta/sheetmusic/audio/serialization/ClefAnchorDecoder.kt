package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.ClefAnchor

/**
 * Payload decoder for [ClefAnchor].
 *
 * Wire format (no version byte — nested inside a versioned [ScoreItemID] blob):
 *   kind  (u8)  0 = Explicit, 1 = StaffDefault
 *   payload:
 *     Explicit      → VoiceElementID payload (20 bytes)
 *     StaffDefault  → StaffAddress payload (8 bytes)
 */
object ClefAnchorDecoder {
    fun decodePayload(r: BinaryReader): ClefAnchor = when (val kind = r.readU8()) {
        0 -> ClefAnchor.Explicit(VoiceElementIDDecoder.decodePayload(r))
        1 -> ClefAnchor.StaffDefault(StaffAddressDecoder.decodePayload(r))
        else -> error("Unknown ClefAnchor kind: $kind")
    }
}
