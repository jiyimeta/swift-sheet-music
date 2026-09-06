package io.github.jiyimeta.sheetmusic.compose.render

import android.graphics.Bitmap
import android.graphics.Canvas as AndroidCanvas
import android.graphics.Color
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
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
    }

    private lateinit var fixture: ByteArray

    @Before
    fun installMetricsAndReadFixture() {
        val testAssets = InstrumentationRegistry.getInstrumentation().context.assets
        // The table has to be installed before anything is laid out, or the engine falls back to
        // rectangle approximations and the golden records those instead of the real engraving.
        assertTrue(
            "metrics table refused",
            SheetMusicJNI.nativeInstallSMuFLMetrics(FontMetricsBuilder.buildTable(testAssets)),
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
                    honorLayoutBreaks = 1u,
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

    private fun renderFirstPage(): Bitmap {
        val page = firstPage()
        val pxPerMM = WIDTH_PX / page.widthMM.toFloat()
        val heightPx = (page.heightMM * pxPerMM).toInt().coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(WIDTH_PX, heightPx, Bitmap.Config.ARGB_8888)
        // White, not transparent: the renderer only ever paints ink, and comparing two images that
        // are mostly undefined-alpha zero would pass whatever happened in between.
        bitmap.eraseColor(Color.WHITE)
        val fonts = bundledFontProvider(
            InstrumentationRegistry.getInstrumentation().targetContext,
        )
        CanvasDrawScope().draw(
            density = Density(density = 1f, fontScale = 1f),
            layoutDirection = LayoutDirection.Ltr,
            canvas = Canvas(AndroidCanvas(bitmap)),
            size = Size(WIDTH_PX.toFloat(), heightPx.toFloat()),
        ) {
            drawCommands(
                commands = page.commands,
                pxPerMM = pxPerMM,
                smufl = fonts.smuflTypeface(),
                text = fonts.textTypeface(),
            )
        }
        return bitmap
    }
}
