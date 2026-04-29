import SheetMusic
import SheetMusicUI
import SwiftUI

/// Page-flip score viewer: tap the left half for the previous
/// page, the right half for the next, and a small page-counter
/// chip floats at the bottom. Used by both iOS and macOS hosts.
@available(macOS 15.0, iOS 16.0, *)
struct PagedScoreContainer: View {
    let score: Score
    let options: ScoreViewOptions
    @Binding var pageIndex: Int
    @Binding var totalPages: Int

    var body: some View {
        ZStack {
            PagedScoreView(
                score: score, options: options,
                pageIndex: $pageIndex,
                totalPages: $totalPages)
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if pageIndex > 0 { pageIndex -= 1 }
                    }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if pageIndex < totalPages - 1 {
                            pageIndex += 1
                        }
                    }
            }
        }
        .overlay(alignment: .bottom) {
            Text("\(min(pageIndex, totalPages - 1) + 1) / \(totalPages)")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 8)
        }
    }
}
