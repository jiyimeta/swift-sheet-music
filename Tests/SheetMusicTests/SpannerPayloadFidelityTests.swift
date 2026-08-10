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
                #expect(segs.first?.kind == .ottava(subtype: expected))
            }
        }

        @Test("ottava label matches its subtype")
        func ottavaLabel() {
            guard #available(macOS 15.0, *) else { return }
            for (subtype, expected) in [
                (Spanner.OttavaPayload.Subtype.eightVA, "8va"),
                (.eightVB, "8vb"),
                (.fifteenMA, "15ma"),
                (.fifteenMB, "15mb"),
                (.twentyTwoMA, "22ma"),
                (.twentyTwoMB, "22mb"),
            ] {
                #expect(SpannerGeometry.ottava(
                    from: .zero, to: CGPoint(x: 100, y: 0),
                    sp: 7, subtype: subtype,
                ).label == expected)
            }
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
                ("Trill", "<Trill><subtype>trill</subtype></Trill>"),
                ("PalmMute", "<PalmMute/>"),
                ("LetRing", "<LetRing/>"),
            ] {
                let (segs, _) = try Self.segments(
                    Self.spanner(type, payload),
                )
                #expect(segs.first?.text.isEmpty == true)
            }
        }
    }
#endif
