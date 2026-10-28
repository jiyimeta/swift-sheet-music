package io.github.jiyimeta.sheetmusic.compose.render

import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand

/** The face a text run draws in, and the synthesis applied on top of it. */
internal data class TextFaceChoice<T : Any>(val face: T, val fakeBold: Boolean, val skewItalic: Boolean)

/**
 * The face a text run with `SetTextStyle` [flags] draws in.
 *
 * With a real face for the run's style ([bold], [italic] or [boldItalic]), that face, with no synthesis: the layout
 * was measured with a table whose styled records measure those faces (`sheet-music-styled.smft`), so synthesizing on
 * top of them would draw wider and slanted ink than the table placed. Without one, [regular] with bold synthesized
 * (`isFakeBoldText`) and italic skewed — what `FontMetricsBuilder` measures its styled records with on the device, so
 * the table it builds and the canvas agree.
 *
 * The `SEMIBOLD` bit draws regular either way: no semibold face ships, and every metrics table measures it regular.
 */
internal fun <T : Any> chooseTextFace(
    flags: UByte,
    regular: T,
    bold: T?,
    italic: T?,
    boldItalic: T?,
): TextFaceChoice<T> {
    val isBold = (flags and DrawCommand.TextStyleFlag.BOLD) != DrawCommand.TextStyleFlag.NONE
    val isItalic = (flags and DrawCommand.TextStyleFlag.ITALIC) != DrawCommand.TextStyleFlag.NONE
    val real = when {
        isBold && isItalic -> boldItalic
        isBold -> bold
        isItalic -> italic
        else -> regular
    }
    return if (real != null) {
        TextFaceChoice(real, fakeBold = false, skewItalic = false)
    } else {
        TextFaceChoice(regular, fakeBold = isBold, skewItalic = isItalic)
    }
}
