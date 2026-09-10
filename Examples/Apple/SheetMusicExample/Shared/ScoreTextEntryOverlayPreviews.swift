#if DEBUG && os(macOS)
    import SheetMusic
    import SheetMusicLayoutApple
    import SheetMusicUI
    import SwiftUI

    @available(macOS 15.0, *)
    private struct FilteredTextEntryPreview: View {
        @State private var controller: NoteInputController
        @State private var lyricSession: LyricInputSession
        @State private var textSession: TextInputSession
        @FocusState private var focused: Bool

        private let hidden: Set<StaffAddress> = [
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
        ]

        init(kind: TextInputPlanner.Kind? = nil) {
            _ = SheetMusicLayoutApple.install
            let staff = Staff(measures: [Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])),
                .chord(Chord(duration: .half, notes: [Note(pitch: 64, tpc: 18)])),
            ])])])
            let controller = NoteInputController(score: Score(division: 480, parts: [
                Part(id: "hidden", instrument: Instrument(id: "a"), staves: [staff]),
                Part(id: "visible", instrument: Instrument(id: "b"), staves: [staff, staff]),
            ]))
            let lyric = LyricInputSession()
            let text = TextInputSession()
            let anchor = VoiceElementID(
                staff: StaffAddress(partIndex: 1, staffIndexInPart: 1),
                measureIndex: 0, voiceIndex: 0, elementIndex: 0,
            )
            if let kind {
                text.begin(kind: kind, at: anchor, controller: controller)
                text.text = kind == .chordSymbol ? "Am7" : "Visible staff"
            } else {
                lyric.begin(at: anchor, verse: 0, controller: controller)
                lyric.text = "Visible"
            }
            _controller = State(initialValue: controller)
            _lyricSession = State(initialValue: lyric)
            _textSession = State(initialValue: text)
        }

        var body: some View {
            let preview = ScoreTextEntryPreview.compose(
                committed: controller.score, lyricSession: lyricSession, textSession: textSession,
            )
            let score = preview.filtered(hidingStaves: hidden)
            let document = LayoutEngine.layout(score: score, options: .init(), availableWidth: 640)
            ZStack(alignment: .topLeading) {
                ScoreView(document: document, score: score)
                ScoreTextEntryOverlayHost(
                    document: document, lyricSession: lyricSession, textSession: textSession,
                    controller: controller, undoManager: nil, focus: $focused,
                    onApplied: { _, _ in }, onError: { _ in },
                    displayedAnchor: { anchor in
                        ScoreEditingAddressMap(score: controller.score, hiddenStaves: hidden)
                            .displayedItem(forFull: .text(.harmony(anchor: anchor)))?.textID?.anchor
                    },
                )
            }
            .padding(24)
            .frame(width: 700, height: 260)
            .background(.white)
        }
    }

    #Preview("Hidden staff lyric caret") {
        FilteredTextEntryPreview()
    }

    #Preview("Hidden staff text caret") {
        FilteredTextEntryPreview(kind: .staffText)
    }

    #Preview("Hidden staff new harmony caret") {
        FilteredTextEntryPreview(kind: .chordSymbol)
    }
#endif
