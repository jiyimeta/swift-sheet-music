import SheetMusicCore
import SheetMusicEditWire
@testable import SheetMusicLayout
import Testing

/// A part's name at the left of its systems is a selectable element: `ScoreElementID.partName`, the address
/// `SetPartNames` takes, with the form the label shows.
@Suite("Part name — identity")
struct PartNameIdentityTests {
    @Test("A part name names its part's first staff and no anchor or bar")
    func position() {
        for form in [PartNameForm.long, .short] {
            let id = ScoreElementID.partName(partIndex: 2, form: form)
            let item = ScoreItemID.element(id)
            #expect(id.anchor == nil)
            #expect(id.measureIndexIfAddressedByBar == nil)
            #expect(item.staff == StaffAddress(partIndex: 2, staffIndexInPart: 0))
            #expect(item.measureIndex == 0)
            #expect(item.elementID == id)
            #expect(id.removalCommand == nil)
        }
    }

    @Test("A part-name hit round-trips through selection")
    func targetRoundTrip() {
        for form in [PartNameForm.long, .short] {
            let id = ScoreElementID.partName(partIndex: 1, form: form)
            let target = ScoreHitTarget(elementID: id)
            #expect(target == .partName(partIndex: 1, form: form))
            #expect(target.elementID == id)
            #expect(target.textID == nil)
            #expect(target.selectableItem == .element(id))
        }
        #expect(ScoreHitTarget(elementID: .partName(partIndex: 0, form: .long))
            != ScoreHitTarget(elementID: .partName(partIndex: 0, form: .short)))
    }

    @Test("A part name survives single and array wire encoding")
    func wireRoundTrip() throws {
        for form in [PartNameForm.long, .short] {
            let item = ScoreItemID.element(.partName(partIndex: 3, form: form))
            #expect(try ScoreItemIDCodec.decode(ScoreItemIDCodec.encode(item)) == item)
            let items: [ScoreItemID] = [.text(.rehearsalMark(measureIndex: 2)), item]
            #expect(try ScoreItemIDCodec.decodeArray(ScoreItemIDCodec.encodeArray(items)) == items)
        }
    }

    /// Hiding the first part renumbers the second to 0 in the filtered layout; a part name clicked there names
    /// part 1 of the score, and the playback-side translation maps it back.
    @Test("Filtered cursors re-address the part")
    func filteredCursor() {
        let measures = [Measure(voices: [Voice(elements: [.rest(duration: .measure)])])]
        let score = Score(division: 480, parts: [
            Part(id: "P1", instrument: Instrument(id: "flute", longName: "Flute"), staves: [Staff(measures: measures)]),
            Part(id: "P2", instrument: Instrument(id: "oboe", longName: "Oboe"), staves: [Staff(measures: measures)]),
        ])
        let hidden: Set<StaffAddress> = [StaffAddress(partIndex: 0, staffIndexInPart: 0)]
        let filtered = ScoreCursor.item(.element(.partName(partIndex: 0, form: .short)))
        let full = ScoreCursor.item(.element(.partName(partIndex: 1, form: .short)))
        #expect(score.engineCursorForFilteredTap(filtered, hiddenStaves: hidden) == full)
        #expect(score.translateCursorForHiddenStaves(full, hiddenStaves: hidden) == filtered)
    }
}

#if os(macOS)
    import CoreGraphics

    @Suite("Part name — layout and hit test")
    struct PartNameHitTests {
        private let _installApple = TestSupport.installApple

        /// A flute and a two-staff piano over enough bars to wrap, so there is a first system and continuations.
        /// The piano has no abbreviation, so its continuation labels are empty.
        private static func score(pianoShortName: String? = nil) -> Score {
            let bar = Measure(voices: [Voice(elements: [.chord(Chord(
                duration: .whole, notes: [Note(pitch: 72, tpc: 14)],
            ))])])
            let measures = Array(repeating: bar, count: 12)
            return Score(division: 480, parts: [
                Part(
                    id: "P1", trackName: "Flute",
                    instrument: Instrument(id: "flute", longName: "Flute", shortName: "Fl."),
                    staves: [Staff(measures: measures)],
                ),
                Part(
                    id: "P2", trackName: "Piano",
                    instrument: Instrument(id: "piano", longName: "Piano", shortName: pianoShortName),
                    staves: [Staff(measures: measures), Staff(measures: measures)],
                ),
            ])
        }

        @available(macOS 15.0, *)
        private func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 300)
        }

        /// Two points inside the label's right (trailing) edge, on its vertical center — the origin the LAYOUT
        /// reports, not the box the tester measures. A part label is set at 2.5 sp, so a name of two or more
        /// characters is several points wider and taller than that.
        private func probe(_ label: LayoutPartLabel, in system: LayoutSystem) -> CGPoint {
            CGPoint(x: system.origin.x + label.origin.x - 2, y: system.origin.y + label.origin.y)
        }

        @Test("Labels carry the part and the form: long on the first system, short after")
        func labelIdentity() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.score(pianoShortName: "Pno."))
            try #require(doc.systems.count >= 2)
            #expect(doc.systems[0].partLabels.map(\.elementID) == [
                .partName(partIndex: 0, form: .long), .partName(partIndex: 1, form: .long),
            ])
            for system in doc.systems.dropFirst() {
                #expect(system.partLabels.map(\.elementID) == [
                    .partName(partIndex: 0, form: .short), .partName(partIndex: 1, form: .short),
                ])
            }
        }

        @Test("A click on a part name selects it, on every system it is drawn on")
        func clickSelects() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.score(pianoShortName: "Pno."))
            let tester = ScoreHitTester(document: doc)
            try #require(doc.systems.count >= 2)
            for system in doc.systems {
                for label in system.partLabels {
                    let id = try #require(label.elementID)
                    let point = probe(label, in: system)
                    #expect(tester.hitTest(at: point) == ScoreHitTarget(elementID: id), "\(label.text)")
                    #expect(tester.itemID(at: point) == .element(id))
                }
            }
        }

        @Test("An abbreviation is one identity drawn once per continuation system")
        func shortNameRects() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.score(pianoShortName: "Pno."))
            let tester = ScoreHitTester(document: doc)
            let continuations = doc.systems.count - 1
            try #require(continuations >= 1)
            let long = tester.elementHitRects(for: .partName(partIndex: 0, form: .long))
            let short = tester.elementHitRects(for: .partName(partIndex: 0, form: .short))
            #expect(long.count == 1)
            #expect(short.count == continuations)
            // Each place contains the click that names it, so a host can pick the one the reader pointed at.
            for (rect, system) in zip(short, doc.systems.dropFirst()) {
                let label = try #require(system.partLabels.first)
                #expect(rect.contains(probe(label, in: system)))
            }
        }

        @Test("A part with no abbreviation has nothing to click after the first system")
        func emptyNameIsNotATarget() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(Self.score(pianoShortName: nil))
            let tester = ScoreHitTester(document: doc)
            try #require(doc.systems.count >= 2)
            #expect(tester.elementHitRects(for: .partName(partIndex: 1, form: .short)).isEmpty)
            for system in doc.systems.dropFirst() {
                let piano = try #require(system.partLabels.last)
                #expect(piano.text.isEmpty)
                #expect(tester.hitPartName(at: probe(piano, in: system)) == nil)
            }
        }
    }
#endif

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT && os(macOS)
    import QuartzCore
    @testable import SheetMusicUI
    import SwiftUI

    @Suite("Part name — tint")
    struct PartNameTintTests {
        private let _installApple = TestSupport.installApple

        @Test("A selected part name tints and restores")
        func tints() throws {
            guard #available(macOS 15.0, *) else { return }
            let bar = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
            let score = Score(division: 480, parts: [Part(
                id: "P1", instrument: Instrument(id: "flute", longName: "Flute"), staves: [Staff(measures: [bar])],
            )])
            let doc = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 600)
            let system = try #require(doc.systems.first)
            let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: doc.metrics)
            let item = ScoreItemID.element(.partName(partIndex: 0, form: .long))
            let layers = try #require(built.items[item])
            #expect(layers.count == 1)
            let before = layers.map(\.fillColor)
            let state = SelectionRenderState.make(selection: .single(item), voiceColors: [0: .red], score: score)
            let tint = try #require(state.voiceColors[0])
            ScoreLayerBuilder.applySelection(items: built.items, previousSelection: .empty, newSelection: state)
            #expect(layers.allSatisfy { $0.fillColor == tint })
            ScoreLayerBuilder.applySelection(items: built.items, previousSelection: state, newSelection: .empty)
            #expect(layers.map(\.fillColor) == before)
        }
    }
#endif
