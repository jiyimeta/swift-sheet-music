#if os(macOS)
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// Regression suite for the "decoder parsed the payload but layout
    /// never read it" bug class — the same seam that made every
    /// decrescendo render as a crescendo.
    @Suite("Spanner payload fidelity")
    struct SpannerPayloadFidelityTests {
        private let _installApple = TestSupport.installApple

        // MARK: - Fixtures

        private static func mscx(_ spannerXML: String) -> String {
            """
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
                      \(spannerXML)
                      <Chord><durationType>whole</durationType>
                        <Note><pitch>60</pitch><tpc>14</tpc></Note>
                      </Chord>
                    </voice>
                  </Measure>
                  <Measure>
                    <voice>
                      <Chord><durationType>whole</durationType>
                        <Note><pitch>60</pitch><tpc>14</tpc></Note>
                      </Chord>
                    </voice>
                  </Measure>
                </Staff>
              </Score>
            </museScore>
            """
        }

        private static func spanner(_ type: String, _ payload: String) -> String {
            """
            <Spanner type="\(type)">\(payload)
            <next><location><measures>1</measures></location></next></Spanner>
            """
        }

        private struct Segment {
            let kind: LayoutElement.SpannerKind
            let from: CGPoint
            let text: String
        }

        private static func segments(
            _ spannerXML: String,
        ) throws -> (segments: [Segment], doc: LayoutDocument) {
            let score = try MSCXParser.parse(Data(mscx(spannerXML).utf8))
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            var out: [Segment] = []
            for system in doc.systems {
                for el in system.spanners {
                    guard case let .spannerSegment(kind, from, _, _, _, text) = el
                    else { continue }
                    out.append(Segment(kind: kind, from: from, text: text))
                }
            }
            return (out, doc)
        }

        // MARK: - Hairpin line types (MuseScore HairpinType 2 / 3)

        @Test("subtype 2 lays out as a cresc. line, not a wedge")
        func crescLine() throws {
            guard #available(macOS 15.0, *) else { return }
            let (segs, _) = try Self.segments(Self.spanner(
                "HairPin", "<HairPin><subtype>2</subtype></HairPin>",
            ))
            #expect(segs.first?.kind == .hairpinLine(crescendo: true))
        }

        @Test("subtype 3 lays out as a dim. line, not a crescendo wedge")
        func dimLine() throws {
            guard #available(macOS 15.0, *) else { return }
            let (segs, _) = try Self.segments(Self.spanner(
                "HairPin", "<HairPin><subtype>3</subtype></HairPin>",
            ))
            #expect(segs.first?.kind == .hairpinLine(crescendo: false))
        }

        @Test("hairpin line types keep their MuseScore begin text")
        func hairpinLineLabels() {
            guard #available(macOS 15.0, *) else { return }
            // `Sid::hairpinCrescText` / `Sid::hairpinDecrescText`
            // (styledef.cpp:304-305).
            #expect(SpannerGeometry.hairpinLine(
                from: .zero, to: CGPoint(x: 100, y: 0),
                crescendo: true, sp: 7,
            ).label == "cresc.")
            #expect(SpannerGeometry.hairpinLine(
                from: .zero, to: CGPoint(x: 100, y: 0),
                crescendo: false, sp: 7,
            ).label == "dim.")
        }

        // MARK: - Ottava subtype

        @Test("ottava subtype reaches layout instead of the raw type string")
        func ottavaSubtypeReachesLayout() throws {
            guard #available(macOS 15.0, *) else { return }
            for (raw, expected) in [
                ("8va", Spanner.OttavaPayload.Subtype.eightVA),
                ("8vb", .eightVB),
                ("15ma", .fifteenMA),
                ("22mb", .twentyTwoMB),
            ] {
                let (segs, _) = try Self.segments(Self.spanner(
                    "Ottava", "<Ottava><subtype>\(raw)</subtype></Ottava>",
                ))
                #expect(
                    segs.first?.kind
                        == .ottava(subtype: expected, numbersOnly: true),
                )
            }
        }

        @Test("ottava label matches its subtype")
        func ottavaLabel() {
            guard #available(macOS 15.0, *) else { return }
            // `Sid::ottava*Text` (`styledef.cpp:645-655`).
            for (subtype, expected) in [
                (Spanner.OttavaPayload.Subtype.eightVA, SMuFLCodepoint.ottavaAlta),
                (.eightVB, SMuFLCodepoint.ottavaBassa),
                (.fifteenMA, SMuFLCodepoint.quindicesimaAlta),
                (.fifteenMB, SMuFLCodepoint.quindicesimaBassa),
                (.twentyTwoMA, SMuFLCodepoint.ventiduesimaAlta),
                (.twentyTwoMB, SMuFLCodepoint.ventiduesimaBassa),
            ] {
                #expect(SpannerGeometry.ottava(
                    from: .zero, to: CGPoint(x: 100, y: 0),
                    sp: 7, subtype: subtype,
                ).labelCodepoint == expected)
            }
        }

        @Test("numbersOnly collapses the label to the bare number glyph")
        func ottavaNumbersOnly() {
            guard #available(macOS 15.0, *) else { return }
            // `Sid::ottava*noText` (`styledef.cpp:658-668`) — the alta
            // / bassa distinction moves to the line's placement.
            for (subtype, expected) in [
                (Spanner.OttavaPayload.Subtype.eightVA, SMuFLCodepoint.ottava),
                (.eightVB, SMuFLCodepoint.ottava),
                (.fifteenMA, SMuFLCodepoint.quindicesima),
                (.fifteenMB, SMuFLCodepoint.quindicesima),
                (.twentyTwoMA, SMuFLCodepoint.ventiduesima),
                (.twentyTwoMB, SMuFLCodepoint.ventiduesima),
            ] {
                let parts = SpannerGeometry.ottava(
                    from: .zero, to: CGPoint(x: 100, y: 0),
                    sp: 7, subtype: subtype, numbersOnly: true,
                )
                #expect(parts.labelCodepoint == expected)
            }
        }

        @Test("a score that turns ottavaNumbersOnly off gets the full label")
        func ottavaNumbersOnlyStyleIsHonored() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = try MSCXParser.parse(Data(Self.mscx(Self.spanner(
                "Ottava", "<Ottava><subtype>8vb</subtype></Ottava>",
            )).utf8))
            score.style.ottavaNumbersOnly = false
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            let kinds = doc.systems.flatMap(\.spanners).compactMap { el in
                if case let .spannerSegment(kind, _, _, _, _, _) = el {
                    return kind
                }
                return LayoutElement.SpannerKind?.none
            }
            #expect(
                kinds.first
                    == .ottava(subtype: .eightVB, numbersOnly: false),
            )
        }

        @Test("bassa ottavas sit below the staff, alta ottavas above")
        func ottavaPlacement() throws {
            guard #available(macOS 15.0, *) else { return }
            /// MuseScore `styledef.cpp:638-643`: ottava8VAPlacement =
            /// ABOVE, ottava8VBPlacement / 15MB / 22MB = BELOW.
            func firstY(_ raw: String) throws -> (y: CGFloat, staffTop: CGFloat, height: CGFloat) {
                let (segs, doc) = try Self.segments(Self.spanner(
                    "Ottava", "<Ottava><subtype>\(raw)</subtype></Ottava>",
                ))
                let staffTop = doc.systems.first?.staffOrigins.first?.y ?? 0
                return (segs.first?.from.y ?? 0, staffTop, doc.metrics.staffHeight)
            }
            let alta = try firstY("8va")
            #expect(alta.y < alta.staffTop)
            for raw in ["8vb", "15mb", "22mb"] {
                let bassa = try firstY(raw)
                #expect(bassa.y > bassa.staffTop + bassa.height)
            }
        }

        // MARK: - Unsupported spanner types

        @Test("an unmapped spanner type never prints its internal type name")
        func unmappedSpannerHasNoLabel() throws {
            guard #available(macOS 15.0, *) else { return }
            for (type, payload) in [
                ("Rasgueado", "<Rasgueado/>"),
                ("HarmonicMark", "<HarmonicMark/>"),
            ] {
                let (segs, _) = try Self.segments(
                    Self.spanner(type, payload),
                )
                #expect(segs.first?.text.isEmpty == true)
            }
        }

        // MARK: - Trill / palm mute / let ring

        @Test("trill subtypes reach layout")
        func trillSubtypes() throws {
            guard #available(macOS 15.0, *) else { return }
            for (raw, expected) in [
                ("trill", TrillType.trill),
                ("upprall", .upprall),
                ("downprall", .downprall),
                ("prallprall", .prallprall),
            ] {
                let (segs, _) = try Self.segments(Self.spanner(
                    "Trill", "<Trill><subtype>\(raw)</subtype></Trill>",
                ))
                #expect(segs.first?.kind == .trill(expected))
                // The sigil is a glyph, never a text label.
                #expect(segs.first?.text.isEmpty == true)
            }
        }

        @Test("a trill line is built from MuseScore's own glyph pair")
        func trillGlyphs() {
            guard #available(macOS 15.0, *) else { return }
            // C++ `tlayout.cpp:6313-6328`.
            let trill = SpannerGeometry.trillSymbols(type: .trill)
            #expect(trill.start == SMuFLCodepoint.ornamentTrill)
            #expect(trill.fill == SMuFLCodepoint.wiggleTrill)
            #expect(trill.end == nil)
            // A continuation segment drops the sigil.
            #expect(SpannerGeometry.trillSymbols(
                type: .trill, continuesLeft: true,
            ).start == SMuFLCodepoint.wiggleTrill)
            let upprall = SpannerGeometry.trillSymbols(type: .upprall)
            #expect(
                upprall.start
                    == SMuFLCodepoint.ornamentBottomLeftConcaveStroke,
            )
            #expect(
                upprall.end
                    == SMuFLCodepoint.ornamentZigZagLineWithRightEnd,
            )
        }

        @Test("the trill glyph run keeps the sigil, fills, and end cap")
        func trillGlyphRunShape() {
            guard #available(macOS 15.0, *) else { return }
            let symbols = SpannerGeometry.trillSymbols(type: .upprall)
            let run = SpannerGeometry.trillGlyphRun(
                from: .zero, to: CGPoint(x: 100, y: 0),
                symbols: symbols,
                startAdvance: 10, fillAdvance: 10, endAdvance: 10,
            )
            // lrint((100 − 10 − 10) / 10) = 8 fills, plus sigil and cap.
            #expect(run.count == 10)
            #expect(run.first?.codepoint == symbols.start)
            #expect(run.last?.codepoint == symbols.end)
            #expect(run[1].origin.x == 10)
        }

        @Test("palm mute and let ring get MuseScore's default text")
        func palmMuteAndLetRingText() throws {
            guard #available(macOS 15.0, *) else { return }
            // `Sid::palmMuteText` / `Sid::letRingText`.
            let pm = try Self.segments(Self.spanner("PalmMute", "<PalmMute/>"))
            #expect(pm.segments.first?.kind == .palmMute)
            #expect(pm.segments.first?.text == "P.M.")
            let lr = try Self.segments(Self.spanner("LetRing", "<LetRing/>"))
            #expect(lr.segments.first?.kind == .letRing)
            #expect(lr.segments.first?.text == "let ring")
        }

        @Test("an authored beginText overrides the style default")
        func beginTextOverridesDefault() throws {
            guard #available(macOS 15.0, *) else { return }
            let (segs, _) = try Self.segments(Self.spanner(
                "PalmMute", "<PalmMute><beginText>p.m.</beginText></PalmMute>",
            ))
            #expect(segs.first?.text == "p.m.")
        }

        @Test("a TextLine prints its authored beginText")
        func textLineUsesBeginText() throws {
            guard #available(macOS 15.0, *) else { return }
            let (segs, _) = try Self.segments(Self.spanner(
                "TextLine", "<TextLine><beginText>rit.</beginText></TextLine>",
            ))
            #expect(segs.first?.kind == .textLine)
            #expect(segs.first?.text == "rit.")
        }

        @Test("palm mute and let ring sit below the staff, trill above")
        func linePlacement() throws {
            guard #available(macOS 15.0, *) else { return }
            func firstY(_ type: String, _ payload: String) throws
                -> (y: CGFloat, staffTop: CGFloat, height: CGFloat)
            {
                let (segs, doc) = try Self.segments(
                    Self.spanner(type, payload),
                )
                let staffTop = doc.systems.first?.staffOrigins.first?.y ?? 0
                return (
                    segs.first?.from.y ?? 0, staffTop, doc.metrics.staffHeight,
                )
            }
            for (type, payload) in [
                ("PalmMute", "<PalmMute/>"), ("LetRing", "<LetRing/>"),
            ] {
                let below = try firstY(type, payload)
                #expect(below.y > below.staffTop + below.height)
            }
            let trill = try firstY("Trill", "<Trill/>")
            #expect(trill.y < trill.staffTop)
        }
    }
#endif
