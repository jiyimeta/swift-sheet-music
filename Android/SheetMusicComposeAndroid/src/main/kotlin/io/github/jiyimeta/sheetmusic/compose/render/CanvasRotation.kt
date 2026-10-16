package io.github.jiyimeta.sheetmusic.compose.render

/**
 * The draw program's rotation, held on a canvas whose transforms only stack.
 *
 * `SetRotation` SETS the rotation the way `SetColor` sets the color: the next one replaces it and a zero clears it.
 * A canvas `rotate` composes onto whatever transform is already there, so applying each command as it arrives stacks
 * them instead. The wavy glissando is the producer that tells the two apart — it sends one rotation per wiggle and a
 * single reset after the run — and stacking left every wiggle's rotation but the last on the canvas, so everything
 * drawn after the glissando came out tilted.
 */
internal class CanvasRotation {
    /** The canvas calls a rotation needs: `android.graphics.Canvas`'s, narrowed so a JVM test can record them. */
    interface Target {
        fun save(): Int
        fun rotate(degrees: Float, pivotX: Float, pivotY: Float)
        fun restoreToCount(saveCount: Int)
    }

    private var saveCount = CLOSED

    /** Apply one `SetRotation`: close the open rotation, then open this one unless it is zero. Pivot in canvas px. */
    fun set(target: Target, radians: Double, pivotXPx: Float, pivotYPx: Float) {
        close(target)
        if (radians == 0.0) return
        saveCount = target.save()
        target.rotate(Math.toDegrees(radians).toFloat(), pivotXPx, pivotYPx)
    }

    /** Close the open rotation, if any — at a reset, and at the end of a command run so none outlives it. */
    fun close(target: Target) {
        if (saveCount == CLOSED) return
        target.restoreToCount(saveCount)
        saveCount = CLOSED
    }

    private companion object {
        const val CLOSED = -1
    }
}
