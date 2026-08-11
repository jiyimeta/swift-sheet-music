#if os(macOS)
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import SheetMusicXMLTools
    import Testing

    @Suite("LocationShift")
    struct LocationShiftTests {
        private let _installApple = TestSupport.installApple

        /// A SystemText placed AFTER a `locationShift(-1/2)` at the
        /// end of a 4-quarter voice should land at the X column of
        /// the third chord (tick = 2 quarters), not at the trailing
        /// end of the bar.
        @Test("SystemText at MeasurePosition 1/2 snaps to chord 3")
        func locationShiftPlacesTextAtChord3() {
            guard #available(macOS 15.0, *) else { return }
            let c5 = Note(pitch: 72, tpc: 14)
            let m1 = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [c5])),
                .chord(Chord(duration: .quarter, notes: [c5])),
                .chord(Chord(duration: .quarter, notes: [c5])),
                .chord(Chord(duration: .quarter, notes: [c5])),
            ])])
            let part = Part(
                id: "P1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [m1])],
            )
            // The text sits at half-bar (after two quarters) in
            // `systemMeasures` — the position previously emerged
            // from a `<location>` shift in voice followed by the
            // staff text; with the refactor it's stored explicitly.
            let systemMeasures: [SystemMeasure] = [
                SystemMeasure(elements: [
                    PositionedSystemElement(
                        position: MeasurePosition(numerator: 1, denominator: 2),
                        element: .staffText(StaffText(
                            text: "tag", isSystemText: true,
                        )),
                    ),
                ]),
            ]
            let score = Score(
                division: 480, parts: [part],
                systemMeasures: systemMeasures,
            )
            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: false,
            )
            let nat = LayoutEngine.naturalContentWidth(
                score: score, options: opts,
            )
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: nat,
            )
            // Collect chord stem Xs and the SystemText X.
            var chordXs: [CGFloat] = []
            var textX: CGFloat?
            for sys in doc.systems {
                for measure in sys.measures {
                    for el in measure.elements {
                        switch el {
                        case let .chord(_, _, _, so, _, _, _, _, _, _, _):
                            chordXs.append(measure.origin.x + so.x)
                        case let .staffText(_, p, _, style) where style == .systemText:
                            textX = measure.origin.x + p.x
                        default:
                            break
                        }
                    }
                }
            }
            #expect(chordXs.count == 4)
            guard let tx = textX, chordXs.count == 4 else { return }
            // After locationShift(-1/2) the text should sit on
            // chord 3, not chord 4 (the natural cursor would have
            // been past chord 4 / at the bar line).
            let distToChord3 = abs(tx - chordXs[2])
            let distToChord4 = abs(tx - chordXs[3])
            #expect(distToChord3 < distToChord4)
        }

        @Test("MSCXDecoder lifts <location>-shifted text to systemElements")
        func decodeLocationFraction() throws {
            let xml = """
            <Voice>
                <location>
                    <fractions>-1/2</fractions>
                </location>
                <StaffText>
                    <text>tag</text>
                </StaffText>
            </Voice>
            """
            let node = try XMLTreeParser.parse(Data(xml.utf8))
            let result = try Voice.decodeWithSystemElements(node)
            // StaffText was lifted out of the voice; the
            // location shift was consumed by its MeasurePosition
            // rather than emitted as a `.locationShift` voice element.
            #expect(result.voice.elements.isEmpty)
            guard result.systemElements.count == 1 else {
                Issue.record(Comment(
                    rawValue:
                    "expected 1 lifted element, got "
                        + "\(result.systemElements.count)",
                ))
                return
            }
            let positioned = result.systemElements[0]
            #expect(positioned.position.offset.numerator == -1)
            #expect(positioned.position.offset.denominator == 2)
            if case let .staffText(st) = positioned.element {
                #expect(st.text == "tag")
            } else {
                Issue.record("expected staffText, got \(positioned.element)")
            }
        }
    }
#endif
