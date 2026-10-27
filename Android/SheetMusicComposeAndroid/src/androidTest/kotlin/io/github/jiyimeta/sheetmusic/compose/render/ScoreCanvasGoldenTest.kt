package io.github.jiyimeta.sheetmusic.compose.render

import android.graphics.Bitmap
import android.graphics.Canvas as AndroidCanvas
import android.graphics.Color
import android.graphics.Rect
import android.graphics.RectF
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.jiyimeta.sheetmusic.FontMetricsBuilder
import io.github.jiyimeta.sheetmusic.LayoutOptionsWire
import io.github.jiyimeta.sheetmusic.LayoutOptionsWireCodec
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.compose.draw.DrawProgramReader
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs

/**
 * Draws a real score and looks at the result.
 *
 * Nothing else here does. The Swift suite asserts on the draw *program* — the command list — and
 * the Kotlin unit tests assert on band arithmetic; neither can see whether the commands land as ink
 * in the right places, or whether a `Paint` state leaks from one command into the next. The browser
 * side has had Playwright rendering tests since it existed, so of the two renderers over one draw
 * program only this one had no picture verified anywhere.
 *
 * The golden is a PNG committed beside this file, produced by running with
 * `-Psheetmusic.recordGolden=true` (see [recordGolden]) and pulling the file off the device. It is
 * pinned to ONE configuration — API 35, arm64, the bundled Bravura and Edwin — because a bitmap
 * comparison across text-rasterizer versions is a test that fails for reasons no one can act on.
 *
 * The comparison is per-pixel with a tolerance, not exact: anti-aliasing differs by a level or two
 * between emulator builds, and a strict compare would make this a tripwire for the wrong thing. What
 * it catches is what it is for — a glyph that stopped drawing, a run that moved, a weight that
 * changed, a colour that leaked past its `setColor`.
 */
@RunWith(AndroidJUnit4::class)
class ScoreCanvasGoldenTest {

    private companion object {
        /** Rendered at a fixed size so the golden does not depend on the device's screen. */
        private const val WIDTH_PX = 1240
        private const val PAGE_WIDTH_MM = 210.0
        private const val PAGE_HEIGHT_MM = 297.0

        /**
         * Per-channel difference a pixel may show before it counts as different, and the share of
         * differing pixels the whole image may show.
         *
         * Two numbers rather than one: a soft threshold alone would pass an image where every pixel
         * drifted slightly *and* one where a glyph vanished into a few hundred hard-wrong pixels.
         * The pair only passes when the differences are both small and rare.
         */
        private const val CHANNEL_TOLERANCE = 12
        private const val MAX_DIFFERING_FRACTION = 0.002

        private const val GOLDEN_ASSET = "golden/score-page-0.png"

        /**
         * A two-staff score carrying notes, rests, a tie, part labels — and a bold tempo mark and a
         * framed bold rehearsal mark.
         *
         * The styled text is why this is its own fixture rather than the edit chain's
         * `fixture.mscx`, which is otherwise ideal and already committed: that one has no text in a
         * bold or italic role at all, so a golden taken from it would be a picture of a score with
         * no styling in it, matching another picture of a score with no styling in it, while the
         * `setTextStyle` path silently stopped working. The frozen chain fixture is also exactly
         * that — frozen — so it cannot be extended.
         */
        private const val FIXTURE_ASSET = "golden/styled-text.mscx"

        /** The origin [anOriginMovesTheInkByTheOrigin] draws at: odd, and different from each other. */
        private const val ORIGIN_X_PX = 37
        private const val ORIGIN_Y_PX = 53
    }

    private lateinit var fixture: ByteArray

    @Before
    fun installMetricsAndReadFixture() {
        val testAssets = InstrumentationRegistry.getInstrumentation().context.assets
        // The table has to be installed before anything is laid out, or the engine falls back to
        // rectangle approximations and the golden records those instead of the real engraving.
        assertTrue(
            "metrics table refused",
            SheetMusicJNI.nativeInstallFontMetrics(FontMetricsBuilder.buildTable(testAssets)),
        )
        fixture = testAssets.open(FIXTURE_ASSET).use { it.readBytes() }
    }

    @Test
    fun theRenderedPageMatchesTheGolden() {
        val actual = renderFirstPage()

        if (recordGolden()) {
            // Written to the app's own files dir, which `adb pull` can reach. Deliberately a
            // separate opt-in run rather than "write it when missing": a golden that appears
            // silently on a first run records whatever the code did that day, including a bug.
            val out = File(
                InstrumentationRegistry.getInstrumentation().targetContext.filesDir,
                "score-page-0.png",
            )
            out.outputStream().use { actual.compress(Bitmap.CompressFormat.PNG, 100, it) }
            throw AssertionError("recorded golden to ${out.absolutePath}; re-run without the flag")
        }

        val expected = InstrumentationRegistry.getInstrumentation().context.assets
            .open(GOLDEN_ASSET)
            .use { android.graphics.BitmapFactory.decodeStream(it) }

        assertEquals("golden width", expected.width, actual.width)
        assertEquals("golden height", expected.height, actual.height)

        var differing = 0
        for (y in 0 until expected.height) {
            for (x in 0 until expected.width) {
                if (!pixelsMatch(expected.getPixel(x, y), actual.getPixel(x, y))) differing++
            }
        }
        val fraction = differing.toDouble() / (expected.width * expected.height)
        assertTrue(
            "%.4f%% of pixels differ (%d of %d); tolerance %.4f%%".format(
                fraction * 100, differing, expected.width * expected.height,
                MAX_DIFFERING_FRACTION * 100,
            ),
            fraction <= MAX_DIFFERING_FRACTION,
        )
    }

    /**
     * The page carries bold text, so the golden is actually looking at it.
     *
     * Without this the image could match while the bold run had silently stopped being emitted —
     * the golden would just be a picture of a score with no bold in it, matching another picture of
     * a score with no bold in it. The fixture's tempo mark and rehearsal mark are both bold by
     * MuseScore's own role defaults, so a program with no `setTextStyle` in it means the style path
     * broke somewhere between the layout and here.
     */
    @Test
    fun theRenderedPageCarriesStyledText() {
        val page = firstPage()
        val styles = page.commands.filterIsInstance<DrawCommand.SetTextStyle>()
        assertTrue("no setTextStyle in the program — is the fixture textless?", styles.isNotEmpty())
        assertTrue(
            "no bold run — the tempo mark and rehearsal mark should both be bold",
            styles.any { it.flags and DrawCommand.TextStyleFlag.BOLD != 0u.toUByte() },
        )
        assertTrue(
            "every style run must be closed by a return to neutral",
            styles.last().flags == DrawCommand.TextStyleFlag.NONE,
        )
    }

    /**
     * An origin moves the ink and nothing else: drawn at ([ORIGIN_X_PX], [ORIGIN_Y_PX]) on a bitmap that much larger,
     * every pixel of the origin-(0, 0) render reappears that far right and down. Two different odd offsets, so an
     * origin with x and y swapped, or one scaled by `pxPerMM` as if it were millimetres, cannot pass.
     */
    @Test
    fun anOriginMovesTheInkByTheOrigin() {
        val page = firstPage()
        val pxPerMM = pxPerMM(page)
        val heightPx = heightPx(page)
        val fonts = fonts()
        val atZero = whiteBitmap(WIDTH_PX, heightPx) { it.drawScoreCommands(page.commands, pxPerMM, fonts) }
        val moved = whiteBitmap(WIDTH_PX + ORIGIN_X_PX, heightPx + ORIGIN_Y_PX) {
            it.drawScoreCommands(
                page.commands, pxPerMM, fonts,
                originXPx = ORIGIN_X_PX.toFloat(), originYPx = ORIGIN_Y_PX.toFloat(),
            )
        }
        assertTrue("the page drew no ink, so nothing below is compared", inkedPixels(atZero, 0 until WIDTH_PX) > 0)

        val expected = pixels(atZero)
        val actual = pixels(moved)
        val movedWidth = WIDTH_PX + ORIGIN_X_PX
        var differing = 0
        for (y in 0 until heightPx) {
            for (x in 0 until WIDTH_PX) {
                val shifted = actual[(y + ORIGIN_Y_PX) * movedWidth + x + ORIGIN_X_PX]
                if (!pixelsMatch(expected[y * WIDTH_PX + x], shifted)) differing++
            }
        }
        assertEquals("pixels that did not move with the origin", 0, differing)
    }

    /**
     * A clip bounds the ink: clipped to the left half, the right half stays white. The unclipped render is the
     * control — it has ink in the right half, so a white right half is the clip's doing and not an empty page's.
     */
    @Test
    fun nothingIsDrawnOutsideTheClip() {
        val page = firstPage()
        val pxPerMM = pxPerMM(page)
        val heightPx = heightPx(page)
        val fonts = fonts()
        val half = WIDTH_PX / 2
        val unclipped = whiteBitmap(WIDTH_PX, heightPx) { it.drawScoreCommands(page.commands, pxPerMM, fonts) }
        val clipped = whiteBitmap(WIDTH_PX, heightPx) {
            it.drawScoreCommands(
                page.commands, pxPerMM, fonts,
                clipPx = RectF(0f, 0f, half.toFloat(), heightPx.toFloat()),
            )
        }
        assertTrue("the page has no ink in its right half to clip", inkedPixels(unclipped, half until WIDTH_PX) > 0)
        assertTrue("the clip hid the left half too", inkedPixels(clipped, 0 until half) > 0)
        assertEquals("pixels inked outside the clip", 0, inkedPixels(clipped, half until WIDTH_PX))
    }

    /**
     * The replay leaves the caller's canvas as it found it: the same save count, and a clip that is the whole bitmap
     * again in unshifted coordinates — so neither the clip nor the origin's translate leaked.
     */
    @Test
    fun theSaveStackIsRestored() {
        val page = firstPage()
        val heightPx = heightPx(page)
        val canvas = AndroidCanvas(Bitmap.createBitmap(WIDTH_PX, heightPx, Bitmap.Config.ARGB_8888))
        val saveCount = canvas.saveCount
        canvas.drawScoreCommands(
            page.commands, pxPerMM(page), fonts(),
            originXPx = ORIGIN_X_PX.toFloat(), originYPx = ORIGIN_Y_PX.toFloat(),
            clipPx = RectF(0f, 0f, WIDTH_PX / 2f, heightPx / 2f),
        )
        assertEquals("save count", saveCount, canvas.saveCount)
        assertEquals("clip bounds", Rect(0, 0, WIDTH_PX, heightPx), canvas.clipBounds)
    }

    /**
     * Real styled faces reach the text runs: the fixture's bold tempo and rehearsal marks drawn in Edwin-Bold paint
     * other ink than synthesized bold. The JVM suite covers only which face a style picks; this is what notices a
     * replay that dropped `styledText` on its way to the renderer.
     */
    @Test
    fun styledFacesDrawTheStyledRuns() {
        val page = firstPage()
        val pxPerMM = pxPerMM(page)
        val heightPx = heightPx(page)
        val fonts = fonts()
        val styled = bundledStyledTextTypefaces(InstrumentationRegistry.getInstrumentation().targetContext)
        val synthesized = pixels(
            whiteBitmap(WIDTH_PX, heightPx) { it.drawScoreCommands(page.commands, pxPerMM, fonts) },
        )
        val real = pixels(
            whiteBitmap(WIDTH_PX, heightPx) {
                it.drawScoreCommands(page.commands, pxPerMM, fonts, styledText = styled)
            },
        )
        val differing = synthesized.indices.count { !pixelsMatch(synthesized[it], real[it]) }
        assertTrue("the styled faces changed no pixel — did styledText reach the text runs?", differing > 0)
    }

    private fun pixelsMatch(a: Int, b: Int): Boolean =
        abs(Color.red(a) - Color.red(b)) <= CHANNEL_TOLERANCE &&
            abs(Color.green(a) - Color.green(b)) <= CHANNEL_TOLERANCE &&
            abs(Color.blue(a) - Color.blue(b)) <= CHANNEL_TOLERANCE &&
            abs(Color.alpha(a) - Color.alpha(b)) <= CHANNEL_TOLERANCE

    private fun recordGolden(): Boolean =
        InstrumentationRegistry.getArguments().getString("recordGolden") == "true"

    private fun firstPage(): EncodablePage {
        val handle = requireNotNull(ScoreHandle.load(fixture)) { "fixture.mscx did not parse" }
        try {
            val options = LayoutOptionsWireCodec.encode(
                LayoutOptionsWire(
                    layoutMode = 2u, // page
                    staffSize = 28.0,
                    collapseMultiMeasureRests = 0u,
                    showsInvisibleElements = 0u,
                    hiddenStaves = emptyList(),
                    clefOverrides = emptyList(),
                    transposeSemitones = 0,
                )
            )
            val bytes = SheetMusicJNI.nativeComputeLayout(
                scoreHandle = handle.raw,
                pageWidthMM = PAGE_WIDTH_MM,
                pageHeightMM = PAGE_HEIGHT_MM,
                optionsBlob = options,
            )
            assertTrue("nativeComputeLayout returned nothing", bytes.isNotEmpty())
            return DrawProgramReader.decode(bytes).pages.first()
        } finally {
            handle.close()
        }
    }

    /**
     * The first page through [drawScoreCommands], the public replay a video frame or a PDF page draws with. It is
     * the same renderer the Compose canvases call, so the golden pins both.
     */
    private fun renderFirstPage(): Bitmap {
        val page = firstPage()
        val pxPerMM = pxPerMM(page)
        val fonts = fonts()
        return whiteBitmap(WIDTH_PX, heightPx(page)) { it.drawScoreCommands(page.commands, pxPerMM, fonts) }
    }

    private fun fonts(): FontProvider =
        bundledFontProvider(InstrumentationRegistry.getInstrumentation().targetContext)

    private fun pxPerMM(page: EncodablePage): Float = WIDTH_PX / page.widthMM.toFloat()

    private fun heightPx(page: EncodablePage): Int = (page.heightMM * pxPerMM(page)).toInt().coerceAtLeast(1)

    /** A [widthPx] × [heightPx] bitmap filled white, after [draw] has painted onto a canvas over it. */
    private fun whiteBitmap(widthPx: Int, heightPx: Int, draw: (AndroidCanvas) -> Unit): Bitmap {
        val bitmap = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
        // White, not transparent: the renderer only ever paints ink, and comparing two images that
        // are mostly undefined-alpha zero would pass whatever happened in between.
        bitmap.eraseColor(Color.WHITE)
        draw(AndroidCanvas(bitmap))
        return bitmap
    }

    /** Every pixel of [bitmap], row by row. */
    private fun pixels(bitmap: Bitmap): IntArray {
        val out = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(out, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return out
    }

    /** How many pixels in [columns] of [bitmap] are not exactly white. */
    private fun inkedPixels(bitmap: Bitmap, columns: IntRange): Int {
        val all = pixels(bitmap)
        var inked = 0
        for (y in 0 until bitmap.height) {
            for (x in columns) {
                if (all[y * bitmap.width + x] != Color.WHITE) inked++
            }
        }
        return inked
    }
}
