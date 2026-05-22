#if os(macOS)
    import SheetMusic
    import SheetMusicAudio
    import SheetMusicUI
    import SwiftUI

    /// macOS vertical-mode score viewport: a SwiftUI `ScrollView`
    /// with a `ScoreView`, system-anchor preference reporting, and
    /// the cursor-driven auto-scroll wired through `proxy.scrollTo`.
    ///
    /// `verticalDoc` is rebuilt by a `.task(id:)` that depends on the
    /// viewport width and the `scoreVersion` UUID — the parent owns
    /// that state so the layout is shared with hit-testing and
    /// survives mode switches.
    @available(macOS 15.0, *)
    struct VerticalScoreContainer: View {
        let score: Score
        @Binding var verticalDoc: LayoutDocument?
        let options: ScoreViewOptions
        let scoreVersion: UUID
        let selection: ScoreSelection
        let voiceColors: [Int: Color]
        let playbackCursor: ScoreCursor?
        let isPlaying: Bool
        let isMarqueeMode: Bool
        let onTap: (CGPoint, LayoutDocument) -> Void
        let onMarqueeEnd: (CGRect, LayoutDocument) -> Void

        @State private var systemFrames: [Int: CGRect] = [:]
        @State private var marqueeRect: CGRect?

        var body: some View {
            GeometryReader { geo in
                let width = geo.size.width - 32
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        if let doc = verticalDoc {
                            ZStack(alignment: .topLeading) {
                                ScoreView(
                                    document: doc, score: score,
                                    selection: selection,
                                    voiceColors: voiceColors,
                                    playbackCursor: playbackCursor,
                                )
                                .onTapGesture { loc in
                                    guard !isMarqueeMode else { return }
                                    onTap(loc, doc)
                                }
                                .gesture(
                                    isMarqueeMode
                                        ? marqueeDragGesture(document: doc)
                                        : nil,
                                )
                                .overlay(
                                    MarqueeOverlay(rect: marqueeRect),
                                )
                                VerticalSystemAnchors(document: doc)
                            }
                            .padding()
                        }
                    }
                    .coordinateSpace(name: "vScroll")
                    .onPreferenceChange(VerticalSystemFramesKey.self) { f in
                        systemFrames = f
                    }
                    .onChange(of: playbackCursor) { _, newCursor in
                        autoScrollVerticalMac(
                            cursor: newCursor,
                            doc: verticalDoc,
                            isPlaying: isPlaying,
                            viewportHeight: geo.size.height,
                            systemFrames: systemFrames,
                            proxy: proxy,
                        )
                    }
                }
                .task(
                    id: VerticalLayoutKey(
                        width: width, scoreVersion: scoreVersion,
                    ),
                ) {
                    verticalDoc = LayoutEngine.layout(
                        score: score,
                        options: options,
                        availableWidth: max(100, width),
                    )
                }
            }
        }

        /// Drag gesture used while marquee mode is on. `minimumDistance:
        /// 0` lets a click+release with no movement still fall through
        /// (clearing selection if the zero rect hits nothing); coords
        /// are reported in the gesture's local space which matches the
        /// `LayoutDocument`'s coord system because the surrounding
        /// `.padding` shifts the content but the gesture sits inside it.
        private func marqueeDragGesture(
            document: LayoutDocument,
        ) -> some Gesture {
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    marqueeRect = makeMarqueeRect(
                        from: value.startLocation,
                        to: value.location,
                    )
                }
                .onEnded { value in
                    let rect = makeMarqueeRect(
                        from: value.startLocation,
                        to: value.location,
                    )
                    marqueeRect = nil
                    onMarqueeEnd(rect, document)
                }
        }
    }

    /// Identity key for the `.task(id:)` that rebuilds the vertical
    /// layout. Width and `scoreVersion` together capture every input
    /// that should trigger a re-layout — staffSize / systemGap come
    /// from the static `ScoreViewOptions` so they don't vary at
    /// runtime.
    struct VerticalLayoutKey: Hashable {
        let width: CGFloat
        let scoreVersion: UUID
    }
#endif
