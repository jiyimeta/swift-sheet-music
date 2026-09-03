package io.github.jiyimeta.sheetmusic

import android.graphics.Paint
import android.graphics.Typeface
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * What [FontMetricsBuilder] actually measures on a device, checked against the table
 * `Tools/GenFontMetrics` writes from CoreText on the host
 * (`Web/sheet-music-web/assets/sheet-music.smft`).
 *
 * Nothing else covers this. The builder only runs on Android, the Swift unit tests read the
 * committed host table rather than building one, and a builder that measured the wrong thing would
 * not fail anything — it would engrave, slightly wrongly, on one platform. That is exactly the
 * failure SMFT v3 shipped for weeks.
 *
 * The constants below are CoreText's, at the shared 1000 pt reference size. Two independent font
 * stacks reading the same two OFL files should agree on them; where they do not, the browser and
 * Android put text at different Y, and this test is the only place that would say so.
 */
@RunWith(AndroidJUnit4::class)
class FontMetricsBuilderTest {

    companion object {
        private const val TAG = "FontMetricsBuilderTest"
        private const val REFERENCE_SIZE = 1000.0

        // Measured by Tools/GenFontMetrics from Sources/.../Bravura.otf and
        // Android/SheetMusicComposeAndroid/src/main/assets/fonts/Edwin-Roman.otf.
        private const val BRAVURA_GLYPHS = 3410

        /**
         * Four fewer than the 869 the host table carries, and every one of them accounted for.
         *
         * Edwin's `cmap` maps 866 codepoints at or above U+0020. CoreText reports 869 for the same
         * file because it resolves three compatibility codepoints the font does not contain —
         * U+2010 HYPHEN and U+2011 NON-BREAKING HYPHEN to the U+002D glyph, U+A789 MODIFIER LETTER
         * COLON to the U+003A one — and Skia does not. The 866th is U+00AD SOFT HYPHEN, which the
         * font does map: CoreText answers it with a zero advance and real ink, Skia with a zero
         * advance and an empty path, so the builder's blank filter keeps it there and drops it
         * here.
         *
         * All four are punctuation whose stub estimate (0.3 em) is within 0.04 em of Edwin's own
         * advance, so what a host loses by their absence is negligible — but the count is pinned
         * exactly, because a *different* four would mean the two font stacks had started
         * disagreeing about something that matters.
         */
        private const val EDWIN_GLYPHS = 865
        private const val BRAVURA_ASCENT = 2012.0f
        private const val EDWIN_ASCENT = 737.0f
        private const val EDWIN_DESCENT = 263.0f
        private const val EDWIN_LEADING = 200.0f
        private const val EDWIN_A_ADVANCE = 722.0f
        private const val EDWIN_SPACE_ADVANCE = 278.0f

        /** Half a point at the reference size — the `Float` rounding the format imposes. */
        private const val METRIC_TOLERANCE = 0.5f
    }

    private data class Entry(val advance: Float, val w: Float, val h: Float)

    private data class Face(
        val name: String,
        val ascent: Float,
        val descent: Float,
        val leading: Float,
        val entries: Map<Int, Entry>,
    )

    @Test
    fun builtTableAgreesWithTheHostTable() {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets

        val startNanos = System.nanoTime()
        val bytes = FontMetricsBuilder.buildTable(assets)
        val elapsedMillis = (System.nanoTime() - startNanos) / 1_000_000

        val faces = decodeFaces(bytes)
        val summary = faces.joinToString("; ") {
            "${it.name}: ${it.entries.size} glyphs ascent ${it.ascent} descent ${it.descent} " +
                "leading ${it.leading}"
        }
        // The walk probes `hasGlyph` across the BMP once per process; this is the only place that
        // number is ever observed, so log it whether or not the assertions hold.
        Log.i(TAG, "buildTable took $elapsedMillis ms, ${bytes.size} bytes — $summary")


        assertEquals("faces: $summary", 2, faces.size)
        val bravura = faces.single { it.name == "Bravura" }
        val edwin = faces.single { it.name == "Edwin" }

        // Bravura's walk is unchanged since SMFT v1; its glyph set must not have moved.
        assertEquals("Bravura glyphs ($summary)", BRAVURA_GLYPHS, bravura.entries.size)
        assertEquals("Bravura ascent", BRAVURA_ASCENT, bravura.ascent, METRIC_TOLERANCE)
        assertEquals("Bravura descent", BRAVURA_ASCENT, bravura.descent, METRIC_TOLERANCE)

        // The text face is new in v4 and this is the assertion it exists for: if Skia and CoreText
        // disagree here, Android and the browser put every lyric row, tempo mark and rehearsal
        // frame at a different Y, and nothing else notices.
        assertEquals("Edwin ascent ($summary)", EDWIN_ASCENT, edwin.ascent, METRIC_TOLERANCE)
        assertEquals("Edwin descent ($summary)", EDWIN_DESCENT, edwin.descent, METRIC_TOLERANCE)
        assertEquals("Edwin leading ($summary)", EDWIN_LEADING, edwin.leading, METRIC_TOLERANCE)

        // The BMP walk keeps what Edwin's cmap has and nothing else. A count in the tens of
        // thousands would mean the membership test had gone back to `Paint`, which answers about
        // the system fallback chain — see the test below — and the table is full of tofu.
        assertEquals("Edwin glyphs ($summary)", EDWIN_GLYPHS, edwin.entries.size)

        val a = requireNotNull(edwin.entries[0x41]) { "Edwin has no 'A'" }
        assertEquals("Edwin 'A' advance", EDWIN_A_ADVANCE, a.advance, METRIC_TOLERANCE)
        assertTrue("Edwin 'A' should be inked", a.w > 0 && a.h > 0)

        // A space is stored for its advance and must claim no ink, or every trailing space pads a
        // rehearsal-mark frame.
        val space = requireNotNull(edwin.entries[0x20]) { "Edwin has no space" }
        assertEquals("Edwin space advance", EDWIN_SPACE_ADVANCE, space.advance, METRIC_TOLERANCE)
        assertEquals("Edwin space ink width", 0.0f, space.w, 0.0f)

        // Edwin has no CJK; a Japanese lyric depends on those codepoints being ABSENT so the Swift
        // provider falls through per scalar to the stub's 1 em per ideograph.
        assertFalse("Edwin should carry no CJK", edwin.entries.containsKey(0x6B4C))
    }

    /**
     * Why [FontMetricsBuilder] parses each font's `cmap` by hand instead of asking `Paint`.
     *
     * `Paint.hasGlyph` reads as the obvious membership test and is wrong for this: on a
     * `Typeface.createFromAsset` paint it still answers about the SYSTEM FALLBACK CHAIN. Measured
     * on a Pixel 8a (API 36), a builder driven by it put 55,093 entries in the Edwin face instead
     * of 869 — every codepoint the device can render in any font, measured against whatever font
     * Android would have substituted — and one extra glyph in Bravura's PUA walk. `getTextWidths`
     * and `getTextPath` substitute the same way, which is why the walk has to be restricted up
     * front rather than filtered afterwards.
     *
     * Pinned as a test so the hand-rolled cmap reader is never "simplified" back into this.
     */
    @Test
    fun hasGlyphConsultsTheSystemFallbackAndCannotBeTheMembershipTest() {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val paint = Paint().apply {
            typeface = Typeface.createFromAsset(assets, "fonts/Edwin-Roman.otf")
            textSize = REFERENCE_SIZE.toFloat()
        }
        assertTrue("Edwin has 'A'", paint.hasGlyph("A"))
        // Edwin contains none of these. If any of them ever answers false, the platform stopped
        // falling back and `hasGlyph` became usable — a welcome simplification, not a failure.
        assertTrue(
            "hasGlyph is expected to fall back for CJK",
            paint.hasGlyph("歌"),
        )
        assertTrue(
            "hasGlyph is expected to fall back for kana",
            paint.hasGlyph("あ"),
        )
    }

    /** Mirrors `FontMetricsTable.decode`, hand-written field-for-field the same way. */
    private fun decodeFaces(bytes: ByteArray): List<Face> {
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals("magic", 0x53_4D_46_54, buf.int)
        assertEquals("version", 4, buf.int)
        assertEquals("referenceSize", REFERENCE_SIZE, buf.double, 0.0)
        val faceCount = buf.int
        val faces = ArrayList<Face>(faceCount)
        repeat(faceCount) {
            val nameBytes = ByteArray(buf.int)
            buf.get(nameBytes)
            val name = nameBytes.toString(Charsets.UTF_8)
            val ascent = buf.float
            val descent = buf.float
            val leading = buf.float
            val glyphCount = buf.int
            val entries = HashMap<Int, Entry>(glyphCount)
            repeat(glyphCount) {
                val cp = buf.int
                val advance = buf.float
                buf.float // bboxX
                buf.float // bboxY
                val w = buf.float
                val h = buf.float
                entries[cp] = Entry(advance, w, h)
            }
            faces.add(Face(name, ascent, descent, leading, entries))
        }
        return faces
    }
}
