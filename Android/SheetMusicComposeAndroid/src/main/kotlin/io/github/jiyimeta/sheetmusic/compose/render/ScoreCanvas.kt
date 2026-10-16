package io.github.jiyimeta.sheetmusic.compose.render

import android.graphics.Paint
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import kotlin.math.roundToInt
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage
import io.github.jiyimeta.sheetmusic.compose.draw.model.FontID

/** Pan/zoom transform shared between [ScoreCanvas] and the cursor overlays. */
data class ScoreTransform(
    val scale: Float = 1f,
    val panOffset: Offset = Offset.Zero,
)

/**
 * Renders a single [EncodablePage] of a draw program onto a Compose
 * [Canvas], with pinch-zoom + pan gesture handling.
 *
 * @param page          the page to draw (document coordinates in mm)
 * @param fontProvider  supplies the SMuFL + text typefaces
 * @param transform     current pan/zoom (hoisted so overlays can share it)
 * @param onTransformChange invoked on gesture
 * @param onPxPerMMChange reports pixels-per-mm so overlays can map mm -> px
 */
@Composable
fun ScoreCanvas(
    page: EncodablePage,
    fontProvider: FontProvider,
    transform: ScoreTransform,
    onTransformChange: (ScoreTransform) -> Unit,
    onPxPerMMChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    val currentTransform by rememberUpdatedState(transform)
    val currentOnTransformChange by rememberUpdatedState(onTransformChange)
    val smufl = fontProvider.smuflTypeface()
    val text = fontProvider.textTypeface()
    Canvas(
        modifier = modifier
            .fillMaxSize()
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ ->
                    val t = currentTransform
                    currentOnTransformChange(
                        t.copy(
                            scale = (t.scale * zoom).coerceIn(0.25f, 8f),
                            panOffset = t.panOffset + pan,
                        )
                    )
                }
            }
    ) {
        val pxPerMM = (size.width / page.widthMM).toFloat()
        onPxPerMMChange(pxPerMM)
        withTransform({
            translate(transform.panOffset.x, transform.panOffset.y)
            scale(transform.scale, transform.scale, pivot = Offset.Zero)
        }) {
            drawPage(page, pxPerMM, smufl, text)
        }
    }
}

/**
 * Gesture-free renderer for a single [EncodablePage]. Unlike [ScoreCanvas],
 * this installs no pan/zoom pointer input and applies no translate — the
 * caller is expected to host it inside a native scroll container (which owns
 * scroll bounds, fling, and overscroll) and to bake zoom into [pxPerMM]
 * (`fitPxPerMM * scale`). Drawing at the zoomed [pxPerMM] re-rasterizes glyphs
 * at the target resolution, so the score stays sharp at every zoom level.
 *
 * @param page          the page to draw (document coordinates in mm)
 * @param fontProvider  supplies the SMuFL + text typefaces
 * @param pxPerMM       pixels per document-millimetre, already including zoom
 * @param modifier      should size the canvas to the zoomed content extent
 */
@Composable
fun ScorePage(
    page: EncodablePage,
    fontProvider: FontProvider,
    pxPerMM: Float,
    modifier: Modifier = Modifier,
) {
    val smufl = fontProvider.smuflTypeface()
    val text = fontProvider.textTypeface()
    Canvas(modifier = modifier) {
        drawPage(page, pxPerMM, smufl, text)
    }
}

private fun DrawScope.drawPage(
    page: EncodablePage,
    pxPerMM: Float,
    smufl: android.graphics.Typeface,
    text: android.graphics.Typeface,
) = drawCommands(page.commands, pxPerMM, smufl, text)

/**
 * Paint one command run. Split out of [drawPage] so a band ([ScoreBand]) — a self-contained slice of a
 * page's commands, still in page coordinates — can be drawn by the same renderer under a translate.
 */
internal fun DrawScope.drawCommands(
    commands: List<DrawCommand>,
    pxPerMM: Float,
    smufl: android.graphics.Typeface,
    text: android.graphics.Typeface,
) {
    val path = Path()
    var strokeStarted = false
    var currentArgb: Int = android.graphics.Color.BLACK
    // State commands accumulate here. `dash*` gates the stroke path effect;
    // `rotation` holds the one SetRotation in force on the native canvas.
    var dashOnPx = 0f
    var dashOffPx = 0f
    val rotation = CanvasRotation()
    // `SetTextStyle`'s bitmask, applied to every subsequent Text / Glyph. Each page starts neutral,
    // which is why this is a local rather than anything the caller carries between pages.
    var textStyleFlags: UByte = DrawCommand.TextStyleFlag.NONE
    val glyphPaint = Paint().apply {
        isAntiAlias = true
        color = currentArgb
    }

    /**
     * The face a [FontID] draws in. [FontID.SYSTEM] — the platform UI family — has no face of its
     * own here and draws the text face, which is what the portable metrics provider measured it in.
     * Exhaustive on purpose, so a new id has to be mapped here before this compiles.
     */
    fun typefaceFor(fontId: FontID): android.graphics.Typeface = when (fontId) {
        FontID.SMUFL -> smufl
        FontID.TEXT_ROMAN, FontID.SYSTEM -> text
    }

    /**
     * Apply the active style to [glyphPaint] before a text draw.
     *
     * `isFakeBoldText` rather than a bold typeface: this library ships Edwin as a single Roman face,
     * and `FontMetricsBuilder` measures its `Edwin-Bold` record with the same synthesis — so what
     * the metrics table reports is what lands on the canvas. A rehearsal mark's frame is sized from
     * that measurement, so the two have to agree.
     *
     * The `SEMIBOLD` bit is ignored and draws regular: no semibold face ships here, and the
     * portable metrics provider measured the text in regular.
     */
    fun applyTextStyle() {
        glyphPaint.isFakeBoldText = (textStyleFlags and DrawCommand.TextStyleFlag.BOLD) != 0u.toUByte()
        glyphPaint.textSkewX =
            if ((textStyleFlags and DrawCommand.TextStyleFlag.ITALIC) != 0u.toUByte()) ITALIC_SKEW else 0f
    }
    for (cmd in commands) {
        when (cmd) {
            is DrawCommand.MoveTo -> {
                val x = cmd.x.toFloat() * pxPerMM
                val y = cmd.y.toFloat() * pxPerMM
                if (strokeStarted) path.reset()
                path.moveTo(x, y)
                strokeStarted = true
            }
            is DrawCommand.LineTo -> {
                path.lineTo(cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM)
            }
            is DrawCommand.CubicTo -> {
                path.cubicTo(
                    cmd.cx1.toFloat() * pxPerMM,
                    cmd.cy1.toFloat() * pxPerMM,
                    cmd.cx2.toFloat() * pxPerMM,
                    cmd.cy2.toFloat() * pxPerMM,
                    cmd.x.toFloat() * pxPerMM,
                    cmd.y.toFloat() * pxPerMM,
                )
            }
            is DrawCommand.Stroke -> {
                val widthPx = (cmd.width.toFloat() * pxPerMM).coerceAtLeast(1.5f)
                val effect = if (dashOnPx > 0f && dashOffPx > 0f) {
                    PathEffect.dashPathEffect(floatArrayOf(dashOnPx, dashOffPx), 0f)
                } else {
                    null
                }
                drawPath(
                    path = path,
                    color = Color(currentArgb),
                    style = Stroke(width = widthPx, pathEffect = effect),
                )
                path.reset()
                strokeStarted = false
            }
            is DrawCommand.FillPath -> {
                // `Fill` closes each contour implicitly, and a fresh Compose `Path` fills with
                // `PathFillType.NonZero` (`reset` keeps the fill type) — the wire's nonzero rule. No
                // path effect, so an active `SetDash` does not apply. Ends the path as `Stroke` does.
                drawPath(path = path, color = Color(currentArgb), style = Fill)
                path.reset()
                strokeStarted = false
            }
            is DrawCommand.FillRect -> {
                drawRect(
                    color = Color(currentArgb),
                    topLeft = Offset(cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM),
                    size = Size(cmd.w.toFloat() * pxPerMM, cmd.h.toFloat() * pxPerMM),
                )
            }
            is DrawCommand.Glyph -> {
                glyphPaint.typeface = typefaceFor(cmd.fontId)
                glyphPaint.textSize = cmd.size.toFloat() * pxPerMM
                glyphPaint.color = currentArgb
                val s = String(intArrayOf(cmd.codepoint.toInt()), 0, 1)
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(
                        s, cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM, glyphPaint,
                    )
                }
            }
            is DrawCommand.Text -> {
                glyphPaint.typeface = typefaceFor(cmd.fontId)
                glyphPaint.textSize = cmd.size.toFloat() * pxPerMM
                glyphPaint.color = currentArgb
                applyTextStyle()
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(
                        cmd.text, cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM, glyphPaint,
                    )
                }
                glyphPaint.isFakeBoldText = false
                glyphPaint.textSkewX = 0f
            }
            is DrawCommand.StretchedGlyph -> {
                glyphPaint.typeface = typefaceFor(cmd.fontId)
                glyphPaint.textSize = cmd.fontSize.toFloat() * pxPerMM
                glyphPaint.color = currentArgb
                val s = String(intArrayOf(cmd.codepoint.toInt()), 0, 1)
                val bounds = android.graphics.Rect()
                glyphPaint.getTextBounds(s, 0, s.length, bounds)
                if (bounds.width() > 0 && bounds.height() > 0) {
                    val rightEdgePx = cmd.rightEdgeX.toFloat() * pxPerMM
                    val topPx = cmd.topY.toFloat() * pxPerMM
                    val bottomPx = cmd.bottomY.toFloat() * pxPerMM
                    val xScale = cmd.xScale.toFloat()
                    val scaleY = (bottomPx - topPx) / bounds.height()
                    drawIntoCanvas { canvas ->
                        val native = canvas.nativeCanvas
                        val save = native.save()
                        // Place the scaled glyph bbox: right edge at rightEdgePx,
                        // top at topPx — mirrors iOS smuflGlyphPathStretched.
                        // translate-then-scale maps a glyph point p to
                        // (tx + sx*px, ty + sy*py).
                        native.translate(
                            rightEdgePx - xScale * bounds.right,
                            topPx - scaleY * bounds.top,
                        )
                        native.scale(xScale, scaleY)
                        native.drawText(s, 0f, 0f, glyphPaint)
                        native.restoreToCount(save)
                    }
                }
            }
            is DrawCommand.SetColor -> {
                currentArgb = cmd.argb.toInt()
            }
            is DrawCommand.SetRotation -> {
                drawIntoCanvas { canvas ->
                    rotation.set(
                        NativeRotationTarget(canvas.nativeCanvas),
                        cmd.radians,
                        cmd.pivotX.toFloat() * pxPerMM,
                        cmd.pivotY.toFloat() * pxPerMM,
                    )
                }
            }
            is DrawCommand.SetDash -> {
                dashOnPx = cmd.onMM.toFloat() * pxPerMM
                dashOffPx = cmd.offMM.toFloat() * pxPerMM
            }
            is DrawCommand.SetTextStyle -> {
                textStyleFlags = cmd.flags
            }
            is DrawCommand.DrawImage -> {
                // The wire rect is document mm, top-left origin. A picture BitmapFactory cannot decode
                // draws nothing, as on the other platforms.
                val dstSize = IntSize(
                    (cmd.w.toFloat() * pxPerMM).roundToInt(),
                    (cmd.h.toFloat() * pxPerMM).roundToInt(),
                )
                val image = decodedImage(cmd, dstSize)
                if (image != null) {
                    drawImage(
                        image = image,
                        dstOffset = IntOffset(
                            (cmd.x.toFloat() * pxPerMM).roundToInt(),
                            (cmd.y.toFloat() * pxPerMM).roundToInt(),
                        ),
                        dstSize = dstSize,
                        // The bitmap is decoded near, not at, the destination size; filter the resample.
                        filterQuality = FilterQuality.High,
                    )
                }
            }
        }
    }
    // A run may end with a rotation still open. The native canvas belongs to the host, which may draw more into it
    // after this run, so close the rotation here rather than let it tilt that drawing.
    drawIntoCanvas { canvas -> rotation.close(NativeRotationTarget(canvas.nativeCanvas)) }
}

/** [CanvasRotation.Target] over the native canvas a draw scope paints into. */
private class NativeRotationTarget(private val canvas: android.graphics.Canvas) : CanvasRotation.Target {
    override fun save(): Int = canvas.save()

    override fun rotate(degrees: Float, pivotX: Float, pivotY: Float) = canvas.rotate(degrees, pivotX, pivotY)

    override fun restoreToCount(saveCount: Int) = canvas.restoreToCount(saveCount)
}

/**
 * Synthetic-italic slant, in x-per-y, for the `ITALIC` bit of `SetTextStyle`. `-0.25` is Android's
 * own conventional value for oblique text, and the slant this renderer has always given a tuplet
 * digit or a glissando label.
 */
private const val ITALIC_SKEW = -0.25f

/**
 * One decoded picture. [bytes] are the encoded bytes it came from (a cache hit compares them, so two pictures
 * whose hashes collide never share a bitmap); [sourceWidth] × [sourceHeight] the picture's own pixel size and
 * [sampleSize] the `inSampleSize` it was decoded at. [bitmap] is null when the bytes are not an image Android
 * can decode.
 */
private class DecodedImage(
    val bytes: ByteArray,
    val bitmap: ImageBitmap?,
    val sourceWidth: Int,
    val sourceHeight: Int,
    val sampleSize: Int,
    val byteCount: Int,
)

/** The longest side a picture is decoded at, in pixels: 2048 × 2048 ARGB is 16 MiB, half the cache. */
private const val MAX_DECODED_SIDE = 2048

/**
 * Decoded `drawImage` pictures, keyed by their command's content hash and byte count, so a score repainted on
 * every scroll frame decodes each picture once. Size-bounded by decoded bytes (32 MiB); since no picture decodes
 * larger than [MAX_DECODED_SIDE], every one fits, and none is decoded again on each frame for being too big to
 * keep. A failed decode is cached too (as a null bitmap), so an undecodable picture is not retried every frame.
 */
private val decodedImages = object : LruCache<Long, DecodedImage>(32 * 1024 * 1024) {
    override fun sizeOf(key: Long, value: DecodedImage): Int = maxOf(value.byteCount, 1)
}

/**
 * The bitmap for [cmd]'s picture, detailed enough for [dst] pixels; null draws nothing. Decoded on first use,
 * and again only when a zoom asks for more detail than the cached bitmap has. A hit costs no walk over the bytes
 * when it is the same array the entry was decoded from (a page's commands are decoded once); a repeated picture
 * carried in another array is compared byte for byte.
 */
private fun decodedImage(cmd: DrawCommand.DrawImage, dst: IntSize): ImageBitmap? {
    val bytes = cmd.data
    val key = (cmd.contentHash.toLong() shl 32) or (bytes.size.toLong() and 0xFFFF_FFFFL)
    val cached = synchronized(decodedImages) { decodedImages.get(key) }
    if (cached != null && (cached.bytes === bytes || cached.bytes.contentEquals(bytes))) {
        val bitmap = cached.bitmap ?: return null
        if (cached.sampleSize <= sampleSizeFor(cached.sourceWidth, cached.sourceHeight, dst)) return bitmap
    }
    val entry = decodePicture(bytes, dst)
    synchronized(decodedImages) { decodedImages.put(key, entry) }
    return entry.bitmap
}

/** Decodes [bytes] in two passes: the header for the pixel size, then the pixels at [sampleSizeFor]'s reduction. */
private fun decodePicture(bytes: ByteArray, dst: IntSize): DecodedImage {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    val width = bounds.outWidth
    val height = bounds.outHeight
    if (width <= 0 || height <= 0) {
        return DecodedImage(bytes, null, 0, 0, 1, 0)
    }
    val sampleSize = sampleSizeFor(width, height, dst)
    val options = BitmapFactory.Options().apply { inSampleSize = sampleSize }
    val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    return DecodedImage(bytes, decoded?.asImageBitmap(), width, height, sampleSize, decoded?.byteCount ?: 0)
}

/**
 * The `inSampleSize` for a [width] × [height] picture drawn into [dst] pixels: the smallest power of two that
 * brings its long side down to twice the destination's long side (room for a later zoom before a redecode), and
 * never above [MAX_DECODED_SIDE].
 */
private fun sampleSizeFor(width: Int, height: Int, dst: IntSize): Int {
    val target = minOf(MAX_DECODED_SIDE, 2 * maxOf(dst.width, dst.height, 1))
    val longSide = maxOf(width, height)
    var sample = 1
    while (longSide / sample > target) sample *= 2
    return sample
}
