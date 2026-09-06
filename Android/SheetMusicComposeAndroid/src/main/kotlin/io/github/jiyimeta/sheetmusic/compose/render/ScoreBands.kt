package io.github.jiyimeta.sheetmusic.compose.render

import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * One horizontal slice of a page's draw program.
 *
 * A continuous (non-paginated) layout is a single [EncodablePage] whose command list covers the whole
 * document — tens of thousands of commands for a long score. Handing that to one [ScorePage] puts every
 * command in one display list, and a scrolling host then pays for the entire list on every frame: the
 * renderer walks each op and rejects it against the clip even though only a screenful is visible.
 *
 * Splitting the page into bands lets the host give each band its own layer, so an off-screen band is
 * rejected once, by its bounds, instead of op by op. [topMM] / [heightMM] are the band's TRUE painted
 * extent (not a grid cell): they already cover everything the band's commands reach, so a host can size
 * the band's layer to them without clipping ink that spills past a nominal boundary. Consecutive bands
 * may therefore overlap slightly.
 *
 * [commands] is self-contained: it opens with the paint state (colour, dash) in force where the band
 * starts, so a band draws correctly without replaying what came before it. Coordinates stay in PAGE
 * space — a host draws a band by translating by `-topMM`, not by rebasing the commands.
 */
class ScoreBand internal constructor(
    val topMM: Double,
    val heightMM: Double,
    internal val commands: List<DrawCommand>,
)

/** Default band height (document mm). Roughly a phone viewport, so a screenful spans 1–2 bands. */
const val DEFAULT_BAND_HEIGHT_MM: Double = 80.0

/** Paint colour a draw program starts from, matching the renderer's initial `Paint`. */
private val INITIAL_ARGB: UInt = 0xFF00_0000u

/**
 * Split this page's command stream into bands of at least [minBandHeightMM] painted height.
 *
 * A band closes at the first command boundary past that height where closing is SAFE, meaning no path is
 * mid-construction (a `MoveTo`/`LineTo`/`CubicTo` run that has not reached its `Stroke`) and no rotation
 * is open. Both are stateful across commands, so cutting inside one would strand geometry in the wrong
 * band. Colour and dash are state a band can simply restate at its start, which is what the prefix does.
 */
fun EncodablePage.splitIntoBands(minBandHeightMM: Double = DEFAULT_BAND_HEIGHT_MM): List<ScoreBand> {
    if (commands.isEmpty()) return emptyList()

    val bands = ArrayList<ScoreBand>()
    var buffer = ArrayList<DrawCommand>()
    var minY = Double.POSITIVE_INFINITY
    var maxY = Double.NEGATIVE_INFINITY

    // Paint state carried across bands, restated as each band's prefix.
    var argb: UInt = INITIAL_ARGB
    var dashOnMM = 0.0
    var dashOffMM = 0.0
    var textStyleFlags: UByte = DrawCommand.TextStyleFlag.NONE
    // Structural state: cutting inside either would split geometry across two bands.
    var pathOpen = false
    var rotation: DrawCommand.SetRotation? = null

    fun startBuffer() {
        buffer = ArrayList()
        buffer.add(DrawCommand.SetColor(argb))
        if (dashOnMM != 0.0 || dashOffMM != 0.0) buffer.add(DrawCommand.SetDash(dashOnMM, dashOffMM))
        // Restated for the same reason colour and dash are: the band cut happens BEFORE a command is
        // appended, so it can fall between a `SetTextStyle(bold)` and the text it styles. Without
        // this the second band would draw that text at regular weight.
        if (textStyleFlags != DrawCommand.TextStyleFlag.NONE) {
            buffer.add(DrawCommand.SetTextStyle(textStyleFlags))
        }
        minY = Double.POSITIVE_INFINITY
        maxY = Double.NEGATIVE_INFINITY
    }

    fun flush() {
        if (minY <= maxY) bands.add(ScoreBand(minY, maxY - minY, buffer))
        startBuffer()
    }

    startBuffer()

    for (cmd in commands) {
        // Close the previous band BEFORE appending, so a command that would overflow it opens the next
        // band instead of straddling the boundary.
        if (!pathOpen && rotation == null && minY <= maxY && maxY - minY >= minBandHeightMM) flush()

        when (cmd) {
            is DrawCommand.SetColor -> argb = cmd.argb
            is DrawCommand.SetDash -> {
                dashOnMM = cmd.onMM
                dashOffMM = cmd.offMM
            }
            is DrawCommand.SetTextStyle -> textStyleFlags = cmd.flags
            is DrawCommand.SetRotation -> rotation = if (cmd.radians != 0.0) cmd else null
            is DrawCommand.MoveTo -> pathOpen = true
            is DrawCommand.Stroke -> pathOpen = false
            else -> Unit
        }

        buffer.add(cmd)

        if (cmd is DrawCommand.Stroke) {
            // The path's own points are already in the band's extent; a stroke only widens them. Widening
            // the whole band rather than just this path is a slight over-approximation, and intentional.
            if (minY <= maxY) {
                minY -= cmd.width
                maxY += cmd.width
            }
            continue
        }
        val box = cmd.boxMM() ?: continue
        val extent = box.verticalExtent(rotation)
        minY = min(minY, extent.first)
        maxY = max(maxY, extent.second)
    }
    flush()
    // `flush` leaves a fresh (prefix-only) buffer behind; it is never emitted.
    return bands
}

/** Axis-aligned bounds of one command in document mm, before any rotation is applied. */
private class Box(val minX: Double, val minY: Double, val maxX: Double, val maxY: Double) {
    /**
     * Vertical extent once [rotation] is applied. A rotated point stays within its distance from the
     * pivot, so the extent collapses to that radius about the pivot's Y — correct for any angle without
     * having to rotate the corners.
     */
    fun verticalExtent(rotation: DrawCommand.SetRotation?): Pair<Double, Double> {
        if (rotation == null) return minY to maxY
        val px = rotation.pivotX
        val py = rotation.pivotY
        val radius = maxOf(
            hypot(minX - px, minY - py),
            hypot(maxX - px, minY - py),
            hypot(minX - px, maxY - py),
            hypot(maxX - px, maxY - py),
        )
        return (py - radius) to (py + radius)
    }
}

/**
 * Bounds this command paints, or null for a state-only command (`Stroke` is handled by the caller, which
 * widens the band it has already accumulated).
 *
 * Deliberately generous: these bounds size the band's layer, so under-reporting would let a host cull a
 * band whose ink actually reaches into the viewport — a visible clip — while over-reporting only costs a
 * little culling efficiency. Glyph extents in particular are approximated from the font size rather than
 * measured, since measuring would need a typeface and a band split has to stay a pure function.
 */
private fun DrawCommand.boxMM(): Box? = when (this) {
    is DrawCommand.MoveTo -> Box(x, y, x, y)
    is DrawCommand.LineTo -> Box(x, y, x, y)
    is DrawCommand.CubicTo -> Box(
        min(min(cx1, cx2), x), min(min(cy1, cy2), y),
        max(max(cx1, cx2), x), max(max(cy1, cy2), y),
    )
    is DrawCommand.FillRect -> Box(x, y, x + w, y + h)
    // (x, y) is the text BASELINE. SMuFL glyphs reach well above it and some below it; the em-size
    // multiples here are the generous approximation described above.
    is DrawCommand.Glyph -> Box(x, y - 2.0 * size, x + 2.0 * size, y + size)
    is DrawCommand.Text -> Box(x, y - 2.0 * size, x + 2.0 * size, y + size)
    is DrawCommand.ItalicText -> Box(x, y - 2.0 * size, x + 2.0 * size, y + size)
    is DrawCommand.StretchedGlyph -> Box(rightEdgeX - fontSize, topY, rightEdgeX, bottomY)
    // State commands paint nothing themselves, so they contribute no box.
    is DrawCommand.Stroke, is DrawCommand.SetColor, is DrawCommand.SetDash,
    is DrawCommand.SetRotation, is DrawCommand.SetTextStyle,
    -> null
}
