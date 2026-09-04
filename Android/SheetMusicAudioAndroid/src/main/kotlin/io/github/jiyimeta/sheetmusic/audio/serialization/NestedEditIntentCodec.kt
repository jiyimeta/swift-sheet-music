package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.EditIntent
import io.github.jiyimeta.sheetmusic.audio.model.NestedEditIntent
import io.github.jiyimeta.wirelet.BinaryReader
import io.github.jiyimeta.wirelet.BinaryWriter
import io.github.jiyimeta.wirelet.WireFormatException
import io.github.jiyimeta.wirelet.WireType

/**
 * Real composites bundle at most two atomic edits (a range op wrapping two
 * sub-commands). Anything nesting deeper than this is either a bug on the
 * writing side or a malformed payload, and refusing it is far cheaper than
 * discovering the hard way — via a stack overflow — that
 * `CompositeIntent.members` has no built-in bound.
 *
 * Kept equal to Swift's `maxCompositeIntentDepth`. The two sides parse the same
 * bytes, so a payload one accepts and the other refuses is a divergence.
 */
private const val MAX_COMPOSITE_INTENT_DEPTH = 8

/**
 * Codec for [NestedEditIntent]. Forwards to [EditIntentCodec] under a depth
 * bound; hand-written because its Swift counterpart is, and the generated
 * `CompositeIntentCodec` calls it by name.
 */
object NestedEditIntentCodec {
    val WIRE_TYPE: WireType = EditIntentCodec.WIRE_TYPE

    /**
     * How many `composite` levels enclose the value currently being parsed.
     *
     * A `ThreadLocal` rather than a plain field, matching the Swift side's
     * `@TaskLocal`: two concurrent decodes must not see each other's count, and
     * a shared counter would let a deep parse on one thread refuse a shallow one
     * on another.
     */
    private val parseDepth = ThreadLocal.withInitial { 0 }

    fun encode(value: NestedEditIntent): ByteArray = EditIntentCodec.encode(value.intent)

    fun encodePayload(value: NestedEditIntent, w: BinaryWriter) {
        EditIntentCodec.encodePayload(value.intent, w)
    }

    fun decode(data: ByteArray): NestedEditIntent =
        NestedEditIntent(descending { EditIntentCodec.decode(data) })

    fun decodePayload(r: BinaryReader): NestedEditIntent =
        NestedEditIntent(descending { EditIntentCodec.decodePayload(r) })

    /** Runs [parse] one level deeper, refusing BEFORE it recurses rather than after. */
    private inline fun descending(parse: () -> EditIntent): EditIntent {
        val depth = parseDepth.get() + 1
        if (depth > MAX_COMPOSITE_INTENT_DEPTH) {
            throw WireFormatException.UnknownTag(depth, WireType.LENGTH_DELIMITED)
        }
        parseDepth.set(depth)
        try {
            return parse()
        } finally {
            // Restored in `finally`, not after the call: a refusal deeper in the
            // tree unwinds through here, and a counter left high would make the
            // NEXT parse on this thread refuse a payload it should accept.
            parseDepth.set(depth - 1)
        }
    }
}
