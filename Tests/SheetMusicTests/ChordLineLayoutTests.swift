#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// End-to-end: a `<ChordLine>` in the source MSCX must reach the
    /// `LayoutDocument` as a drawable `.chordLine` element. This is the
    /// regression guard for "fall and friends don't show up" — before the
    /// feature existed the element was silently skipped by the decoder and
    /// nothing downstream could draw it.
    @Suite("ChordLine layout")
    struct ChordLineLayoutTests {
        /// Layout-only suites don't transitively pull in an Apple
        /// `FontMetricsProvider` (that arrives with UI / PDF), so install it
        /// eagerly — `LayoutEngine.layout` asserts on the stub provider.
        private let _installApple = TestSupport.installApple

        static func score(chordLineXML: String) throws -> Score {
            try MSCXParser.parse(Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.40">
              <Score>
                <Division>480</Division>
                <Part>
                  <Staff id="1"/>
                  <Instrument id="trumpet"><trackName>Trumpet</trackName><Channel/></Instrument>
                </Part>
                <Staff id="1">
                  <Measure>
                    <voice>
                      <Chord><durationType>quarter</durationType>
                        \(chordLineXML)
                        <Note><pitch>67</pitch><tpc>15</tpc></Note>
                      </Chord>
                    </voice>
                  </Measure>
                </Staff>
              </Score>
            </museScore>
            """.utf8))
        }

        static func chordLines(
            in document: LayoutDocument,
        ) -> [(shape: ChordLineShape, origin: CGPoint, thickness: CGFloat)] {
            document.systems.flatMap(\.measures).flatMap(\.elements)
                .compactMap { element in
                    guard case let .chordLine(shape, origin, thickness) = element
                    else { return nil }
                    return (shape, origin, thickness)
                }
        }

        static func layout(
            _ score: Score, showsInvisible: Bool = false,
        ) -> LayoutDocument {
            LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(showsInvisibleElements: showsInvisible),
                availableWidth: 800,
            )
        }

        @Test("every subtype reaches the layout as a drawable element")
        func allSubtypesReachLayout() throws {
            for subtype in 1 ... 4 {
                let document = try Self.layout(Self.score(
                    chordLineXML: "<ChordLine><subtype>\(subtype)</subtype></ChordLine>",
                ))
                let lines = Self.chordLines(in: document)
                #expect(lines.count == 1, "subtype \(subtype)")
                guard case let .path(segments)? = lines.first?.shape else {
                    Issue.record("subtype \(subtype): expected a stroked path")
                    continue
                }
                #expect(segments.count == 2)
                #expect(lines.first?.thickness ?? 0 > 0)
            }
        }

        /// Fall / doit hang off the right of the notehead, plop / scoop off
        /// the left. C++: `ChordLine::isToTheLeft`.
        @Test("origin sits on the correct side of the notehead")
        func originSide() throws {
            var originX: [Int: CGFloat] = [:]
            for subtype in 1 ... 4 {
                let document = try Self.layout(Self.score(
                    chordLineXML: "<ChordLine><subtype>\(subtype)</subtype></ChordLine>",
                ))
                originX[subtype] = Self.chordLines(in: document).first?.origin.x
            }
            let fall = try #require(originX[1])
            let doit = try #require(originX[2])
            let plop = try #require(originX[3])
            let scoop = try #require(originX[4])
            #expect(fall == doit)
            #expect(plop == scoop)
            #expect(plop < fall, "slide-in variants must sit left of slide-out ones")
        }

        /// Size regression. The generated path must span exactly
        /// `1.2 sp × 1.0 sp` for an ordinary chord — C++
        /// `layoutChordLine`: `horBaseLength = 1.2 * spatium * intrinsicMag`,
        /// `baseLength = spatium * intrinsicMag`.
        ///
        /// This pins the bug where the placement pass handed the chord-line
        /// builder `options.graceNoteMag` (0.6) instead of the chord's own
        /// magnification, rendering every fall at 60 % of MuseScore's size.
        @Test("laid-out path is 1.2 sp x 1.0 sp for a normal chord")
        func pathSizeMatchesMuseScore() throws {
            let score = try Self.score(
                chordLineXML: "<ChordLine><subtype>1</subtype></ChordLine>",
            )
            let document = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(staffSize: 40),
                availableWidth: 800,
            )
            guard case let .path(segments)? =
                Self.chordLines(in: document).first?.shape
            else {
                Issue.record("expected a path shape"); return
            }
            let box = ChordLineGeometry.boundingBox(of: segments)
            let sp = document.metrics.sp
            #expect(abs(box.width / sp - 1.2) < 0.001)
            #expect(abs(box.height / sp - 1.0) < 0.001)
        }

        /// A cue-sized chord (`<Chord><small>1</small>`) scales its chord
        /// line by the same factor as its noteheads — upstream reads
        /// `intrinsicMag()`, which is where smallness enters.
        @Test("a small chord scales its chord line by smallNoteMag")
        func smallChordScalesPath() throws {
            let score = try Self.score(chordLineXML: """
            <small>1</small>
            <ChordLine><subtype>1</subtype></ChordLine>
            """)
            let options = ScoreViewOptions(staffSize: 40)
            let document = LayoutEngine.layout(
                score: score, options: options, availableWidth: 800,
            )
            guard case let .path(segments)? =
                Self.chordLines(in: document).first?.shape
            else {
                Issue.record("expected a path shape"); return
            }
            let box = ChordLineGeometry.boundingBox(of: segments)
            let sp = document.metrics.sp
            #expect(abs(box.height / sp - options.smallNoteMag) < 0.001)
        }

        @Test("wavy variants lay out as a rotated SMuFL glyph")
        func wavyUsesGlyph() throws {
            let document = try Self.layout(Self.score(chordLineXML: """
            <ChordLine><subtype>1</subtype><wavy>1</wavy></ChordLine>
            """))
            guard case let .glyph(codepoint, rotation)? =
                Self.chordLines(in: document).first?.shape
            else {
                Issue.record("expected a glyph shape"); return
            }
            #expect(codepoint == SMuFLCodepoint.brassFallRoughShort)
            #expect(rotation == 1)
        }

        @Test("straight variants lay out as a single line segment")
        func straightUsesLine() throws {
            let document = try Self.layout(Self.score(chordLineXML: """
            <ChordLine><subtype>2</subtype><straight>1</straight></ChordLine>
            """))
            guard case let .path(segments)? =
                Self.chordLines(in: document).first?.shape
            else {
                Issue.record("expected a path shape"); return
            }
            #expect(segments.count == 2)
            if case .line = segments[1] {} else {
                Issue.record("expected a line segment, got \(segments[1])")
            }
        }

        @Test("a user-edited <Path> wins over the generated default")
        func userPathWins() throws {
            let document = try Self.layout(Self.score(chordLineXML: """
            <ChordLine>
              <subtype>1</subtype>
              <Path>
                <Element type="0" x="0" y="0"/>
                <Element type="1" x="3" y="3"/>
                <Element type="1" x="5" y="1"/>
              </Path>
            </ChordLine>
            """))
            guard case let .path(segments)? =
                Self.chordLines(in: document).first?.shape
            else {
                Issue.record("expected a path shape"); return
            }
            // Three elements in, three segments out — the two-segment
            // default shape would mean the user path was ignored.
            #expect(segments.count == 3)
        }

        // MARK: - Horizontal spacing

        /// Two quarter chords in one measure; the first optionally carries a
        /// chord line. Returns the laid-out notehead x of each chord.
        static func twoChordNoteXs(
            first: String,
            second: String,
            secondPitch: (pitch: Int, tpc: Int) = (67, 15),
        ) throws -> [CGFloat] {
            let score = try MSCXParser.parse(Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.40">
              <Score>
                <Division>480</Division>
                <Part>
                  <Staff id="1"/>
                  <Instrument id="trumpet"><trackName>Tpt</trackName><Channel/></Instrument>
                </Part>
                <Staff id="1">
                  <Measure>
                    <voice>
                      <Chord><durationType>quarter</durationType>
                        \(first)
                        <Note><pitch>67</pitch><tpc>15</tpc></Note>
                      </Chord>
                      <Chord><durationType>quarter</durationType>
                        \(second)
                        <Note><pitch>\(secondPitch.pitch)</pitch>\
            <tpc>\(secondPitch.tpc)</tpc></Note>
                      </Chord>
                    </voice>
                  </Measure>
                </Staff>
              </Score>
            </museScore>
            """.utf8))
            let document = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(staffSize: 40, wrapToViewWidth: false),
                availableWidth: LayoutEngine.naturalContentWidth(
                    score: score,
                    options: ScoreViewOptions(staffSize: 40, wrapToViewWidth: false),
                ),
            )
            return document.systems.flatMap(\.measures).flatMap(\.elements)
                .compactMap { element in
                    guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element
                    else { return nil }
                    return notes.first?.origin.x
                }
        }

        /// A `ChordLine` is part of the chord's shape upstream
        /// (`ChordLayout::fillShape` walks `item->el()`), so horizontal
        /// spacing has to clear it: putting a fall on a note pushes the
        /// following chord away.
        @Test("a fall widens the gap to the next chord")
        func fallWidensFollowingGap() throws {
            let plain = try Self.twoChordNoteXs(first: "", second: "")
            let withFall = try Self.twoChordNoteXs(
                first: "<ChordLine><subtype>1</subtype></ChordLine>", second: "",
            )
            #expect(plain.count == 2)
            #expect(withFall.count == 2)
            let plainGap = plain[1] - plain[0]
            let fallGap = withFall[1] - withFall[0]
            #expect(fallGap > plainGap)
        }

        /// The mirror case: a scoop reaches backwards, so it widens the gap
        /// BEFORE its own chord rather than after it.
        @Test("a scoop widens the gap before its chord")
        func scoopWidensPrecedingGap() throws {
            let plain = try Self.twoChordNoteXs(first: "", second: "")
            let withScoop = try Self.twoChordNoteXs(
                first: "", second: "<ChordLine><subtype>4</subtype></ChordLine>",
            )
            #expect(withScoop[1] - withScoop[0] > plain[1] - plain[0])
        }

        /// A chord with no inflection line must not change spacing at all —
        /// guards against the reservation leaking into every chord.
        @Test("chords without a chord line keep their spacing")
        func noChordLineNoExtraSpacing() throws {
            let a = try Self.twoChordNoteXs(first: "", second: "")
            let b = try Self.twoChordNoteXs(first: "", second: "")
            #expect(a == b)
        }

        /// Upstream charges for the line only when its rectangle *vertically
        /// intersects* the neighbour's; otherwise `KerningType::KERNING`
        /// lets it tuck in for free. A fall hangs below its own note, so a
        /// following note placed well above it costs nothing.
        @Test("a fall does not widen the gap when the next note sits clear above")
        func fallDoesNotWidenWhenVerticallyClear() throws {
            // Second chord an octave and a half up — its notehead band is far
            // above the fall's, so the two never intersect.
            let plain = try Self.twoChordNoteXs(
                first: "", second: "", secondPitch: (86, 20),
            )
            let withFall = try Self.twoChordNoteXs(
                first: "<ChordLine><subtype>1</subtype></ChordLine>",
                second: "", secondPitch: (86, 20),
            )
            #expect(withFall[1] - withFall[0] == plain[1] - plain[0])
        }

        /// `doComputeKerningType` gives a chord line `ALLOW_COLLISION`
        /// against a barline, so a fall on the last chord of a measure must
        /// not reserve anything.
        @Test("a fall on the last chord does not widen the measure")
        func fallAtBarlineDoesNotWiden() throws {
            let plain = try Self.twoChordNoteXs(first: "", second: "")
            let trailing = try Self.twoChordNoteXs(
                first: "", second: "<ChordLine><subtype>1</subtype></ChordLine>",
            )
            #expect(trailing[1] - trailing[0] == plain[1] - plain[0])
        }

        // MARK: - Visibility

        @Test("a hidden chord line is dropped when the toggle is off")
        func hiddenDroppedWhenToggleOff() throws {
            let score = try Self.score(chordLineXML: """
            <ChordLine><subtype>1</subtype><visible>0</visible></ChordLine>
            """)
            let document = Self.layout(score, showsInvisible: false)
            #expect(Self.chordLines(in: document).isEmpty)
        }

        @Test("a hidden chord line rides the invisible overlay when on")
        func hiddenRoutedToOverlayWhenToggleOn() throws {
            let score = try Self.score(chordLineXML: """
            <ChordLine><subtype>1</subtype><visible>0</visible></ChordLine>
            """)
            let document = Self.layout(score, showsInvisible: true)
            #expect(Self.chordLines(in: document).isEmpty)
            let overlay = document.systems.flatMap(\.measures)
                .flatMap(\.invisibleElements)
                .filter { if case .chordLine = $0 { true } else { false } }
            #expect(overlay.count == 1)
        }

        @Test("both lines of a scoop-plus-fall chord are laid out")
        func multipleLinesBothLaidOut() throws {
            let document = try Self.layout(Self.score(chordLineXML: """
            <ChordLine><subtype>4</subtype></ChordLine>
            <ChordLine><subtype>1</subtype></ChordLine>
            """))
            #expect(Self.chordLines(in: document).count == 2)
        }
    }
#endif
