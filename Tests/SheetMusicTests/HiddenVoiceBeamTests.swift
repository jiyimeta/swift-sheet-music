#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import SheetMusicXMLTools
    import Testing

    /// A voice that starts part-way through its measure
    /// (`<location><fractions>3/4</fractions>`) plus an explicitly
    /// hidden `<Beam>` — the pair that produced a full-width black bar
    /// under the Bass staff of `Problem.mscz` m16.
    ///
    /// Two independent defects were involved:
    ///
    /// 1. `aggregatedTickWeights` / `beamGroups` / `collectSpanners`
    ///    dropped `.locationShift` into `default: break` while
    ///    `placeMeasureElements` advanced its cursor by the delta, so
    ///    `tickColumns` was keyed by ticks nothing ever looked up and
    ///    the shifted chords fell back to the header X.
    /// 2. `<Beam>` was not decoded at all, so a beam MuseScore hides was
    ///    drawn anyway.
    @Suite("Shifted voices and hidden beams")
    struct HiddenVoiceBeamTests {
        private let _installApple = TestSupport.installApple

        private static let division = 480

        /// 4/4 measure. Voice 0 is one whole note. Voice 1 opens with a
        /// 3/4 location shift and then four 16ths, i.e. it occupies the
        /// last quarter only.
        private static func shiftedVoiceScore(
            beamVisible: Bool,
        ) -> Score {
            let note = Note(pitch: 60, tpc: 14)
            let lead = Chord(
                duration: .sixteenth, notes: [note], beamVisible: beamVisible,
            )
            var voice1: [VoiceElement] = [
                .locationShift(delta: Fraction(numerator: 3, denominator: 4)),
                .chord(lead),
            ]
            for _ in 0 ..< 3 {
                voice1.append(.chord(Chord(duration: .sixteenth, notes: [note])))
            }
            let measure = Measure(voices: [
                Voice(elements: [
                    .chord(Chord(duration: .whole, notes: [note])),
                ]),
                Voice(elements: voice1),
            ])
            return Score(division: division, parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [measure])],
            )])
        }

        private static func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
        }

        @Test("A 3/4-shifted voice gets tick columns at its real ticks")
        func shiftedVoiceHasColumnsAtShiftedTicks() {
            guard #available(macOS 15.0, *) else { return }
            guard let measure = Self.layout(
                Self.shiftedVoiceScore(beamVisible: true),
            ).systems.first?.measures.first else {
                Issue.record("expected one system with one measure")
                return
            }
            // The voice starts at 3/4 = 1440 and runs 1440 / 1560 /
            // 1680 / 1800. Before the fix the walker counted from 0,
            // producing 0 / 120 / 240 / 360 instead.
            for tick in [1440, 1560, 1680, 1800] {
                #expect(measure.tickColumns[tick] != nil)
            }
            for tick in [120, 240, 360] {
                #expect(measure.tickColumns[tick] == nil)
            }
        }

        @Test("A 3/4-shifted voice is not stacked at the measure's left edge")
        func shiftedVoiceIsNotStackedAtLeftEdge() {
            guard #available(macOS 15.0, *) else { return }
            guard let measure = Self.layout(
                Self.shiftedVoiceScore(beamVisible: true),
            ).systems.first?.measures.first else {
                Issue.record("expected one system with one measure")
                return
            }
            var stemXs: [CGFloat] = []
            for element in measure.elements {
                if case let .chord(_, _, _, stemOrigin, _, _, _, _, _, _, _)
                    = element
                {
                    stemXs.append(stemOrigin.x)
                }
            }
            // 1 whole note + 4 sixteenths, each at its own column.
            #expect(stemXs.count == 5)
            #expect(Set(stemXs).count == 5)
            // Every sixteenth sits in the last quarter of the measure.
            guard let firstColumn = measure.tickColumns[1440] else {
                Issue.record("expected a column at tick 1440")
                return
            }
            #expect(stemXs.count(where: { $0 >= firstColumn }) == 4)
        }

        @Test("A visible beam over the shifted voice stays inside its own span")
        func visibleBeamSpansOnlyTheShiftedVoice() {
            guard #available(macOS 15.0, *) else { return }
            guard let measure = Self.layout(
                Self.shiftedVoiceScore(beamVisible: true),
            ).systems.first?.measures.first else {
                Issue.record("expected one system with one measure")
                return
            }
            var beams: [(CGFloat, CGFloat)] = []
            for element in measure.elements {
                if case let .beam(from, to, _, _, _) = element {
                    beams.append((from.x, to.x))
                }
            }
            #expect(!beams.isEmpty)
            guard let firstColumn = measure.tickColumns[1440] else {
                Issue.record("expected a column at tick 1440")
                return
            }
            for (fromX, toX) in beams {
                // Never reversed, and never reaching back to the header.
                #expect(fromX < toX)
                #expect(fromX >= firstColumn - measure.origin.x)
            }
        }

        @Test("A hidden beam emits no beam bars but keeps the chords")
        func hiddenBeamEmitsNoBars() {
            guard #available(macOS 15.0, *) else { return }
            guard let measure = Self.layout(
                Self.shiftedVoiceScore(beamVisible: false),
            ).systems.first?.measures.first else {
                Issue.record("expected one system with one measure")
                return
            }
            var beamCount = 0
            var chordCount = 0
            for element in measure.elements {
                if case .beam = element { beamCount += 1 }
                if case .chord = element { chordCount += 1 }
            }
            #expect(beamCount == 0)
            #expect(chordCount == 5)
        }

        @Test("<Beam><visible>0 lands on the next chord only")
        func beamVisibleIsConsumedByOneChord() throws {
            let node = try XMLTreeParser.parse(Data(#"""
            <voice>
              <Beam><visible>0</visible></Beam>
              <Chord><durationType>16th</durationType>
                <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
              <Chord><durationType>16th</durationType>
                <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
            </voice>
            """#.utf8))
            let voice = try Voice.decode(node)
            var flags: [Bool] = []
            for element in voice.elements {
                if case let .chord(c) = element {
                    flags.append(c.beamVisible)
                }
            }
            // MuseScore attaches the beam it read to the FIRST following
            // ChordRest and clears the pending reference, so only the
            // group's leading chord carries the flag.
            #expect(flags == [false, true])
        }

        @Test("A <Beam> without <visible> leaves the default alone")
        func beamWithoutVisibleKeepsDefault() throws {
            let node = try XMLTreeParser.parse(Data(#"""
            <voice>
              <Beam><StemDirection>down</StemDirection></Beam>
              <Chord><durationType>16th</durationType>
                <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
            </voice>
            """#.utf8))
            let voice = try Voice.decode(node)
            guard case let .chord(c) = voice.elements.first else {
                Issue.record("expected a chord")
                return
            }
            #expect(c.beamVisible)
        }
    }
#endif
