#if os(macOS)
    import Foundation
    import SheetMusicUI
    import Testing

    /// Guards `Sources/SheetMusicUI/SelectionReexport.swift`: a consumer that imports only `SheetMusicUI` — never
    /// `SheetMusicLayout` directly, exactly Folino's shape until SP2's cutover — must still see `ScoreHitTester`,
    /// its `itemIDs(in:)` marquee extension member (declared in a *different* file, `ScoreHitTester+Marquee.swift`,
    /// than the `struct` itself), `ScoreHitTarget`, `ScoreSelection`, and `SelectionExpansion`. Compiling this file
    /// *is* the assertion: if any of those stopped resolving through the re-export, this suite would fail to
    /// build, not just fail an assertion. Deliberately does not `import SheetMusicLayout` anywhere in this file.
    @Suite("SheetMusicUI re-exports the relocated selection API")
    struct SelectionReexportTests {
        private let _installApple = TestSupport.installApple

        private func sample() -> Score {
            let measure = Measure(voices: [
                Voice(elements: [
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                ]),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [Staff(
                        staffType: "stdNormal",
                        group: "pitched",
                        defaultClefType: "G",
                        measures: [measure],
                    )],
                )],
            )
        }

        @Test("ScoreHitTester + its marquee extension + the selection types all resolve through SheetMusicUI alone")
        func reexportedSelectionAPIIsUsable() {
            guard #available(macOS 15.0, *) else { return }
            let score = sample()
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: 600,
            )
            let tester = ScoreHitTester(document: doc)

            let target: ScoreHitTarget? = tester.hitTest(at: CGPoint(x: -10000, y: -10000))
            #expect(target == nil)

            // `itemIDs(in:)` is declared in `ScoreHitTester+Marquee.swift`'s `extension ScoreHitTester` — a
            // separate file from the `struct` declaration — so resolving it here specifically exercises that a
            // same-module extension on a re-exported type comes along with the re-export.
            let ids = tester.itemIDs(in: CGRect(x: -10000, y: -10000, width: 1, height: 1))
            #expect(ids.isEmpty)

            let selection = ScoreSelection.none
            let selectedIDs = SelectionExpansion.selectedIDs(for: selection, in: score)
            #expect(selectedIDs.isEmpty)
        }
    }
#endif
