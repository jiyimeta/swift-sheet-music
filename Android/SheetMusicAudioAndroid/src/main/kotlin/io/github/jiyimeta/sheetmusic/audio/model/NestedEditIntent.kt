package io.github.jiyimeta.sheetmusic.audio.model

/**
 * A forwarding wrapper around [EditIntent] whose only job is to bound the parse
 * depth of nested composites.
 *
 * Hand-written rather than generated, mirroring `NestedEditIntentWire` on the
 * Swift side, which is hand-written for the same reason: it is not a
 * `@WireFormat` type at all, just a conformance that counts. The generated
 * `CompositeIntent` / `CompositeIntentCodec` reference it by name, which is why
 * this file exists at all.
 *
 * The encoding is [EditIntent]'s, unchanged in both directions — see
 * `NestedEditIntentCodec`, which forwards every method. What the wrapper adds is
 * a counter, and the counter has to sit in the *parse* rather than in a
 * post-parse conversion: only refusing before recursing prevents the overflow.
 * Swift's own doc records what happened when the bound lived only in the
 * conversion — on WebAssembly the overflow did not trap, it overwrote the
 * allocator's state and surfaced later inside an unrelated `malloc`.
 */
@JvmInline
value class NestedEditIntent(val intent: EditIntent)
