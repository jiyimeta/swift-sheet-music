package io.github.jiyimeta.sheetmusic.compose.export

import android.graphics.pdf.PdfDocument
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawProgram
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage
import io.github.jiyimeta.sheetmusic.compose.render.FontProvider
import io.github.jiyimeta.sheetmusic.compose.render.drawCommands
import java.io.OutputStream
import kotlin.math.max

/**
 * PostScript points per document millimetre. `PdfDocument` measures pages in
 * points (1/72 inch), the draw program in millimetres.
 */
private const val POINTS_PER_MM: Float = 72f / 25.4f

/**
 * Writes an engraved score to a PDF.
 *
 * PDF export was Apple-only: `SheetMusicPDF`'s export half needs `ImageRenderer`
 * and `CGPDFContext`, so an Android host could lay a score out, draw it and play
 * it, and then had no way to hand the user a printable page. This closes that
 * without a second engraving pipeline — the same draw program the screen renders
 * is replayed into [PdfDocument]'s canvas.
 *
 * Glyphs stay vector. `Canvas.drawText` on a PDF canvas becomes a PDF text
 * operator with the typeface embedded, so a page zooms and prints at the
 * device's resolution rather than the screen's — the same property Apple's
 * `ImageRenderer` → `CGPDFContext` bridge gives, reached a different way.
 *
 * ### Choosing what to export
 *
 * Page size comes from the program, so it is the host's layout call that decides
 * the paper: compute the layout in `.page` mode with the page size you want to
 * print, and each [EncodablePage] becomes one PDF page at exactly that size. A
 * continuous (single tall page) program exports as one very long page, which is
 * legal PDF and almost never what a reader wants — paginate first.
 *
 * ### Break indicators
 *
 * Nothing to strip: the bridge never emits authoring badges into the draw
 * program (`LayoutOptionsWire.breakIndicatorVisibilityRaw` defaults to none),
 * so an exported page carries only what belongs on paper. Apple's exporter has
 * to pass `.none` explicitly for the same reason.
 */
object ScorePdfExporter {

    /**
     * Render [program] into [out] as a PDF, one PDF page per [EncodablePage].
     *
     * The stream is NOT closed — the caller owns it, which is what lets this be
     * pointed at a `ContentResolver.openOutputStream` the caller has to close
     * itself anyway.
     *
     * @throws IllegalArgumentException when the program has no pages, or a page
     *   has a non-positive dimension. Both mean the caller has not laid the
     *   score out yet, and writing a zero-size PDF page produces a file that
     *   opens to nothing rather than an error the caller can act on.
     */
    fun write(
        program: DrawProgram,
        out: OutputStream,
        fontProvider: FontProvider,
    ) {
        require(program.pages.isNotEmpty()) { "cannot export a draw program with no pages" }
        val document = PdfDocument()
        try {
            program.pages.forEachIndexed { index, page ->
                writePage(document, page, index + 1, fontProvider)
            }
            document.writeTo(out)
        } finally {
            // Always: `writeTo` can throw mid-write (a full disk, a closed
            // stream), and a PdfDocument that is never closed leaks every
            // page's native bitmap for the life of the process.
            document.close()
        }
    }

    private fun writePage(
        document: PdfDocument,
        page: EncodablePage,
        pageNumber: Int,
        fontProvider: FontProvider,
    ) {
        require(page.widthMM > 0.0 && page.heightMM > 0.0) {
            "page $pageNumber has a non-positive size (${page.widthMM} x ${page.heightMM} mm)"
        }
        // Rounded up, never down: a page rounded down by half a point clips the
        // right-hand or bottom edge of ink that the layout placed inside it.
        val widthPt = max(1, (page.widthMM * POINTS_PER_MM).roundUpToInt())
        val heightPt = max(1, (page.heightMM * POINTS_PER_MM).roundUpToInt())
        val info = PdfDocument.PageInfo.Builder(widthPt, heightPt, pageNumber).create()
        val pdfPage = document.startPage(info)
        try {
            // Reuse the screen renderer rather than a second interpretation of
            // the command list. `CanvasDrawScope` adapts the PDF page's
            // `android.graphics.Canvas` into the `DrawScope` the renderer takes,
            // so there is exactly one place that knows what each opcode means —
            // the failure ARCHITECTURE.md records for the Apple side, where two
            // back-ends over one layout meant a change to either could leave the
            // other drawing a missing glyph.
            CanvasDrawScope().draw(
                density = Density(density = 1f, fontScale = 1f),
                layoutDirection = LayoutDirection.Ltr,
                canvas = Canvas(pdfPage.canvas),
                size = Size(widthPt.toFloat(), heightPt.toFloat()),
            ) {
                drawCommands(
                    commands = page.commands,
                    pxPerMM = POINTS_PER_MM,
                    smufl = fontProvider.smuflTypeface(),
                    text = fontProvider.textTypeface(),
                )
            }
        } finally {
            // `finishPage` must run even if drawing throws, or the document is
            // left with an open page and `writeTo` fails with a state error
            // that says nothing about the real cause.
            document.finishPage(pdfPage)
        }
    }

    private fun Double.roundUpToInt(): Int {
        val truncated = toInt()
        return if (this > truncated) truncated + 1 else truncated
    }
}

/** Convenience: [ScorePdfExporter.write] as a method on the program. */
fun DrawProgram.writePdf(out: OutputStream, fontProvider: FontProvider) {
    ScorePdfExporter.write(this, out, fontProvider)
}
