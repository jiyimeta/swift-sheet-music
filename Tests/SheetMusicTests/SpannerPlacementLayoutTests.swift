#if os(macOS)
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// An authored `<placement>` has to beat the per-kind default the
    /// layout derives from the spanner's type and subtype, and an
    /// authored `<numbersOnly>` has to beat `Sid::ottavaNumbersOnly`.
    @Suite("Spanner placement overrides")
    struct SpannerPlacementLayoutTests {
        private let _installApple = TestSupport.installApple

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
                      <Spanner type="\(spannerXML)
                      <next><location><measures>1</measures></location></next>
                      </Spanner>
                      <Chord><durationType>whole</durationType>
                        <Note><pitch>71</pitch><tpc>19</tpc></Note>
                      </Chord>
                    </voice>
                  </Measure>
                  <Measure>
                    <voice>
                      <Chord><durationType>whole</durationType>
                        <Note><pitch>71</pitch><tpc>19</tpc></Note>
                      </Chord>
                    </voice>
                  </Measure>
                </Staff>
              </Score>
            </museScore>
            """
        }

        /// Returns the first spanner segment's kind and whether it was
        /// placed below the staff.
        private static func firstSegment(
            _ spannerXML: String,
        ) throws -> (kind: LayoutElement.SpannerKind, isBelow: Bool) {
            let score = try MSCXParser.parse(Data(mscx(spannerXML).utf8))
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            for system in doc.systems {
                let staffTop = system.staffOrigins.first?.y ?? 0
                for el in system.spanners {
                    guard case let .spannerSegment(kind, from, _, _, _, _) = el
                    else { continue }
                    return (kind, from.y > staffTop + doc.metrics.staffHeight)
                }
            }
            Issue.record("no spanner segment laid out")
            throw CancellationError()
        }

        @Test("an authored placement flips an ottava off its styled side")
        func ottavaPlacementOverride() throws {
            guard #available(macOS 15.0, *) else { return }
            // 8va is styled ABOVE, 8vb BELOW — both must yield to the
            // authored value.
            let alta = try Self.firstSegment(
                """
                Ottava"><Ottava><subtype>8va</subtype>
                <placement>below</placement></Ottava>
                """,
            )
            #expect(alta.isBelow)
            let bassa = try Self.firstSegment(
                """
                Ottava"><Ottava><subtype>8vb</subtype>
                <placement>above</placement></Ottava>
                """,
            )
            #expect(!bassa.isBelow)
        }

        @Test("an authored placement flips a hairpin and a trill too")
        func placementAppliesToEveryKind() throws {
            guard #available(macOS 15.0, *) else { return }
            // Hairpins are styled BELOW, trills ABOVE.
            let hairpin = try Self.firstSegment(
                """
                HairPin"><HairPin><subtype>0</subtype>
                <placement>above</placement></HairPin>
                """,
            )
            #expect(!hairpin.isBelow)
            let trill = try Self.firstSegment(
                """
                Trill"><Trill><subtype>trill</subtype>
                <placement>below</placement></Trill>
                """,
            )
            #expect(trill.isBelow)
        }

        @Test("the styled side still applies when nothing is authored")
        func defaultPlacementIsUnchanged() throws {
            guard #available(macOS 15.0, *) else { return }
            let alta = try Self.firstSegment(
                "Ottava\"><Ottava><subtype>8va</subtype></Ottava>",
            )
            #expect(!alta.isBelow)
            let bassa = try Self.firstSegment(
                "Ottava\"><Ottava><subtype>8vb</subtype></Ottava>",
            )
            #expect(bassa.isBelow)
        }

        @Test("an authored numbersOnly beats the score style")
        func numbersOnlyOverride() throws {
            guard #available(macOS 15.0, *) else { return }
            // The score style defaults to true; this element opts out.
            let segment = try Self.firstSegment(
                """
                Ottava"><Ottava><subtype>15mb</subtype>
                <numbersOnly>0</numbersOnly></Ottava>
                """,
            )
            #expect(
                segment.kind
                    == .ottava(subtype: .fifteenMB, numbersOnly: false),
            )
        }
    }
#endif
