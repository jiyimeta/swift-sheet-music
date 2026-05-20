import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// MuseScore-style playback cursor: a tall translucent rectangle
/// positioned at the column for the current `cursor`, spanning the
/// full vertical extent of the system that contains it (top of the
/// topmost staff to bottom of the bottommost). The cursor jumps
/// column-by-column — discrete steps — as `cursor` changes during
/// playback.
///
/// The cursor's column is one of:
///
/// * `.item(id)` — sits exactly on the chord / rest's notehead
///   column (existing behavior).
/// * `.beat(measure, tick)` — sits at a metric beat in between
///   chord onsets, with X linearly interpolated between the
///   bracketing chord / rest columns. Lets the cursor advance on
///   beats 2 / 3 / 4 even when a held half note covers them.
///
/// The host typically owns `currentCursor` published by
/// `PlaybackEngine` and feeds it in here. Returns an empty view
/// when the column can't be resolved (e.g. mid-render layout swap),
/// so it's safe to render unconditionally inside `ScoreView`'s
/// overlay.
///
/// The geometry computation (`cursorFrame(for:in:)`) lives in
/// `SheetMusicLayout` so Android can reuse the same algorithm
/// without SwiftUI.
@available(macOS 15.0, *)
public struct PlaybackCursorView: View {
    private let cursor: ScoreCursor?
    private let document: LayoutDocument
    private let score: Score
    private let color: Color

    public init(
        cursor: ScoreCursor?,
        document: LayoutDocument,
        score: Score,
        color: Color = Color.blue.opacity(0.15),
    ) {
        self.cursor = cursor
        self.document = document
        self.score = score
        self.color = color
    }

    public var body: some View {
        if let cursor,
           let frame = document.cursorFrame(for: cursor, in: score)
        {
            Rectangle()
                .fill(color)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
        }
    }
}
