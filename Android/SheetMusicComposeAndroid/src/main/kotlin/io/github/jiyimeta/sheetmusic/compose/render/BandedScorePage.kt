package io.github.jiyimeta.sheetmusic.compose.render

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage

/**
 * [ScorePage] for a CONTINUOUS layout — one page whose height is the whole document — hosted inside a
 * scroll container.
 *
 * [ScorePage] paints such a page as a single `Canvas`, which puts every command of the entire score into
 * one display list. Scrolling then costs the whole list on every frame even though a screenful is
 * visible: the display list is not re-recorded (a scroll container places its content with its own
 * layer), but every op still has to be walked and rejected against the clip. On a long score that is
 * tens of thousands of rejections per frame.
 *
 * This splits the page into bands (see [splitIntoBands]) and gives each its own layer, so an off-screen
 * band is rejected once by its bounds. Each band is sized to the true extent of what it paints and drawn
 * under a translate, leaving the commands in page coordinates.
 *
 * A second benefit falls out of the same structure: siblings the host stacks over the score (a playback
 * cursor, ink overlays) no longer share a layer with it, so their updates stop re-recording the score's
 * commands. Hosts should therefore NOT wrap this in a `graphicsLayer` of their own — that would collapse
 * the bands back into one layer and undo both effects.
 *
 * For a paginated layout, where a page is about a screenful already, [ScorePage] is the right call.
 *
 * @param page          the page to draw (document coordinates in mm)
 * @param fontProvider  supplies the SMuFL + text typefaces
 * @param pxPerMM       pixels per document-millimetre, already including zoom
 * @param minBandHeightMM  minimum painted height of a band, in document mm
 * @param modifier      should size the surface to the zoomed content extent
 */
@Composable
fun BandedScorePage(
    page: EncodablePage,
    fontProvider: FontProvider,
    pxPerMM: Float,
    minBandHeightMM: Double = DEFAULT_BAND_HEIGHT_MM,
    modifier: Modifier = Modifier,
) {
    val smufl = fontProvider.smuflTypeface()
    val text = fontProvider.textTypeface()
    val density = LocalDensity.current

    // Memoised on page IDENTITY, not equality: `EncodablePage` is a data class over a command list, so a
    // `remember(page)` key would run a full element-wise comparison of tens of thousands of commands on
    // every recomposition — which a pinch does per frame. A fresh page instance per layout is exactly
    // what identity tracks.
    val cache = remember { BandCache() }
    if (cache.page !== page || cache.minBandHeightMM != minBandHeightMM) {
        cache.page = page
        cache.minBandHeightMM = minBandHeightMM
        cache.bands = page.splitIntoBands(minBandHeightMM)
    }
    val bands = cache.bands

    Box(modifier) {
        bands.forEachIndexed { index, band ->
            key(index) {
                val topPx = (band.topMM * pxPerMM).toFloat()
                val heightPx = (band.heightMM * pxPerMM).toFloat()
                Canvas(
                    Modifier
                        .fillMaxWidth()
                        .height(with(density) { heightPx.toDp() })
                        .offset(y = with(density) { topPx.toDp() })
                        .graphicsLayer(),
                ) {
                    // Commands stay in page coordinates; the band's own origin is its top.
                    translate(top = -topPx) {
                        drawCommands(band.commands, pxPerMM, smufl, text)
                    }
                }
            }
        }
    }
}

/** Identity-keyed memo for [EncodablePage.splitIntoBands]; see the note at its use site. */
private class BandCache {
    var page: EncodablePage? = null
    var minBandHeightMM: Double = Double.NaN
    var bands: List<ScoreBand> = emptyList()
}
