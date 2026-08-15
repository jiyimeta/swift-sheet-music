#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// A below-staff spanner used to sit at a constant
    /// `staffHeight + 3 sp` regardless of what was engraved under the
    /// staff, so low ledger-line notes ran straight through it. It is
    /// now synthesized into the pass-1 buffer and placed by
    /// `SkylineAutoplacePass`, the way MuseScore's `processLines` +
    /// `autoplaceSpannerSegment` do it.
    @Suite("Below-staff spanner autoplace")
    struct BelowStaffSpannerAutoplaceTests {
        private let _installApple = TestSupport.installApple

        /// Two whole notes at `pitch`, spanned by `spannerXML`.
        private static func mscx(
            _ spannerXML: String, pitch: Int, tpc: Int,
        ) -> String {
            let chord = """
            <Chord><durationType>whole</durationType>
              <Note><pitch>\(pitch)</pitch><tpc>\(tpc)</tpc></Note>
            </Chord>
            """
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.20">
              <Score>
                <Division>480</Division>
                <Part>
                  <Staff id="1"><StaffType group="pitched"/></Staff>
                  <trackName>P</trackName>
                  <Instrument id="piano">
                    <instrumentId>keyboard.piano</instrumentId>
                  </Instrument>
                </Part>
                <Staff id="1">
                  <Measure>
                    <voice>
                      <Spanner type="\(spannerXML)
                      <next><location><measures>1</measures></location></next>
                      </Spanner>
                      \(chord)
                    </voice>
                  </Measure>
                  <Measure><voice>\(chord)</voice></Measure>
                </Staff>
              </Score>
            </museScore>
            """
        }

        private struct Placed {
            let segmentY: CGFloat
            /// Lowest point any chord in the system paints.
            let chordSouthY: CGFloat
            let sp: CGFloat
        }

        private static func layout(
            _ spannerXML: String, pitch: Int, tpc: Int,
        ) throws -> Placed {
            let score = try MSCXParser.parse(Data(
                mscx(spannerXML, pitch: pitch, tpc: tpc).utf8,
            ))
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            let system = try #require(doc.systems.first)
            let segment = try #require(
                system.spanners.compactMap { el -> CGFloat? in
                    guard case let .spannerSegment(_, from, _, _, _, _)
                        = el else { return nil }
                    return from.y
                }.first,
            )
            var south = -CGFloat.greatestFiniteMagnitude
            for measure in system.measures {
                for el in measure.elements {
                    guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _)
                        = el else { continue }
                    for note in notes {
                        south = max(south, note.origin.y)
                    }
                }
            }
            return Placed(
                segmentY: segment,
                chordSouthY: south,
                sp: doc.metrics.sp,
            )
        }

        @Test("a hairpin clears notes hanging below the staff")
        func hairpinClearsLowNotes() throws {
            guard #available(macOS 15.0, *) else { return }
            let hairpin = """
            HairPin"><HairPin><subtype>0</subtype></HairPin>
            """
            // B4 sits inside the staff; C2 is five ledger lines below
            // it in treble clef and used to be drawn straight through
            // the wedge.
            let high = try Self.layout(hairpin, pitch: 71, tpc: 19)
            let low = try Self.layout(hairpin, pitch: 36, tpc: 14)

            // The low chord really does hang below where the hairpin
            // used to sit — otherwise this test proves nothing.
            #expect(low.chordSouthY > high.segmentY)
            // ...and the hairpin has moved down to clear it.
            #expect(low.segmentY > high.segmentY)
            #expect(low.segmentY > low.chordSouthY)
        }

        @Test("nothing under the staff leaves the band where it was")
        func highNotesLeaveTheBandAlone() throws {
            guard #available(macOS 15.0, *) else { return }
            let placed = try Self.layout(
                "HairPin\"><HairPin><subtype>0</subtype></HairPin>",
                pitch: 71, tpc: 19,
            )
            // `SkylineAutoplacePass` never moves an item toward the
            // staff, so with nothing engraved below it the segment
            // stays at the styled default. Pinning this is what keeps
            // the fix from costing vertical space on every system.
            let staffTop = try #require(
                try LayoutEngine.layout(
                    score: MSCXParser.parse(Data(Self.mscx(
                        "HairPin\"><HairPin><subtype>0</subtype></HairPin>",
                        pitch: 71, tpc: 19,
                    ).utf8)),
                    options: .init(), availableWidth: 800,
                ).systems.first?.staffOrigins.first?.y,
            )
            let expected = staffTop + LayoutEngine.defaultBandOffsetY(
                belowStaff: true,
                lineGeometry: .standard,
                metrics: StaffMetrics(staffSize: placed.sp * 4),
            )
            #expect(abs(placed.segmentY - expected) < 0.001)
        }

        @Test("an 8vb clears low notes the same way")
        func ottavaBassaClearsLowNotes() throws {
            guard #available(macOS 15.0, *) else { return }
            let ottava = """
            Ottava"><Ottava><subtype>8vb</subtype></Ottava>
            """
            let high = try Self.layout(ottava, pitch: 71, tpc: 19)
            let low = try Self.layout(ottava, pitch: 36, tpc: 14)
            #expect(low.segmentY > high.segmentY)
            #expect(low.segmentY > low.chordSouthY)
        }
    }
#endif
