import Foundation
import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// The capture / restore primitives behind preserved markup.
///
/// The end-to-end property — "a fixture loses nothing on decode →
/// encode" — lives in `MSCXPreservationGateTests`. These pin the
/// pieces that gate depends on, so a failure there can be told apart
/// from a failure here.
@Suite("MSCX preserved markup primitives")
struct MSCXPreservedMarkupTests {
    @Test("consumed children are not preserved")
    func skipsConsumed() {
        let node = XMLTreeNode(name: "Chord", children: [
            XMLTreeNode(name: "durationType", text: "quarter"),
            XMLTreeNode(name: "StemDirection", text: "up"),
        ])
        let kept = node.preservedMarkup(consuming: ["durationType"])
        #expect(kept.map(\.name) == ["StemDirection"])
        #expect(kept.first?.text == "up")
    }

    @Test("source order is kept")
    func keepsOrder() {
        let node = XMLTreeNode(name: "Score", children: [
            XMLTreeNode(name: "Order"),
            XMLTreeNode(name: "Division", text: "480"),
            XMLTreeNode(name: "Synthesizer"),
        ])
        #expect(
            node.preservedMarkup(consuming: ["Division"]).map(\.name)
                == ["Order", "Synthesizer"],
        )
    }

    @Test("eid and the other never-preserved tags are dropped")
    func dropsExcluded() {
        let node = XMLTreeNode(name: "Chord", children: [
            XMLTreeNode(name: "eid", text: "abc"),
            XMLTreeNode(name: "StemDirection", text: "up"),
        ])
        #expect(node.preservedMarkup(consuming: []).map(\.name) == ["StemDirection"])
    }

    @Test("nested subtrees survive the round trip through PreservedXML")
    func nestedRoundTrip() {
        let source = XMLTreeNode(name: "Instrument", children: [
            XMLTreeNode(name: "StringData", children: [
                XMLTreeNode(name: "frets", text: "19"),
                XMLTreeNode(name: "string", attributes: ["l": "0"], text: "40"),
            ]),
        ])
        let kept = source.preservedMarkup(consuming: [])
        #expect(kept.count == 1)
        #expect(XMLTreeNode(preserved: kept[0]) == source.children[0])
    }

    @Test("<Order> and <showFrames> survive decode → encode")
    func scoreLevelUnknownSubtreesSurvive() throws {
        let source = try MSCXFixtureLoader.mscxData("grace_after")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let root = try XMLTreeParser.parse(encoded)
        let score = try #require(root.first("Score"))
        let order = score.first("Order")
        let showFrames = score.first("showFrames")
        #expect(order != nil)
        #expect(showFrames != nil)
    }

    @Test("<StringData> and <Instrument><clef> survive decode → encode")
    func partLevelMarkupSurvives() throws {
        let source = try MSCXFixtureLoader.mscxData("guitarbend_simple")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let root = try XMLTreeParser.parse(encoded)
        let part = try #require(root.first("Score")?.first("Part"))
        let instrument = try #require(part.first("Instrument"))
        let strings = try #require(instrument.first("StringData"))
        let clef = instrument.first("clef")
        #expect(strings.all("string").count == 6)
        #expect(clef != nil)
        // The MusicXML Sound ID does NOT come back: `<instrumentId>` is
        // consumed as a fallback for the `id` attribute and synthesized
        // for drumsets, so it cannot ride in preserved markup. See
        // `MSCXPreservation.soundIDReason`. Bound to a local because
        // SwiftLint reads a bare `first(…) != nil` as the
        // `first(where:)` overload and asks for `contains`.
        let soundID = instrument.first("instrumentId")
        #expect(soundID == nil)
        #expect(instrument.attributes["id"] == "guitar-steel")
    }

    @Test("<Channel><controller> survives decode → encode")
    func channelControllerSurvives() throws {
        let source = try MSCXFixtureLoader.mscxData("testMidiPort")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let root = try XMLTreeParser.parse(encoded)
        let score = try #require(root.first("Score"))
        let controllers = score.all("Part")
            .compactMap { $0.first("Instrument") }
            .flatMap { $0.all("Channel") }
            .flatMap { $0.all("controller") }
        #expect(controllers.count == 149)
        #expect(controllers.allSatisfy {
            $0.attributes["ctrl"] == "0" && $0.attributes["value"] == "1"
        })
    }

    @Test("unmodeled <StaffType> children survive decode → encode")
    func staffTypeMarkupSurvives() throws {
        let source = try MSCXFixtureLoader.mscxData("slur_ms4_glissando_legato")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let root = try XMLTreeParser.parse(encoded)
        let part = try #require(root.first("Score")?.first("Part"))
        let staffType = try #require(
            part.all("Staff")
                .compactMap { $0.first("StaffType") }
                .first { $0.attributes["group"] == "tablature" },
        )
        #expect(staffType.children.map(\.name) == [
            "name", "lines", "lineDistance", "stemless", "timesig", "durations",
            "durationFontName", "durationFontSize", "durationFontY", "fretFontName",
            "fretFontSize", "fretFontY", "linesThrough", "minimStyle", "onLines",
            "showRests", "stemsDown", "stemsThrough", "upsideDown", "useNumbers",
        ])
    }

    @Test("an unknown voice child keeps its position in the stream")
    func unknownVoiceChildKeepsPosition() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part><Staff id="1"/><Instrument/></Part>
        <Staff id="1"><Measure><voice>
        <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        <FiguredBass><ticks>480</ticks></FiguredBass>
        <Chord><durationType>quarter</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
        </voice></Measure></Staff></Score></museScore>
        """
        let score = try MSCXParser.parse(Data(xml.utf8))
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        guard case let .preserved(kept) = elements[1] else {
            Issue.record(Comment(
                rawValue: "expected the FiguredBass between the two chords, got \(elements)",
            ))
            return
        }
        #expect(kept.name == "FiguredBass")

        let root = try XMLTreeParser.parse(MSCXEncoder.encode(score))
        let voice = try #require(
            root.first("Score")?.all("Staff").last?
                .first("Measure")?.first("voice"),
        )
        #expect(voice.children.map(\.name) == ["Chord", "FiguredBass", "Chord"])
    }

    @Test("<LayoutBreak><subtype>nobreak</subtype> survives")
    func nobreakLayoutBreakSurvives() throws {
        let source = try MSCXFixtureLoader.mscxData("testMeasureRepeats")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("nobreak"))
    }

    @Test("emitPreservedMarkup: false leaves preserved markup out")
    func preservedMarkupCanBeSuppressed() throws {
        let source = try MSCXFixtureLoader.mscxData("grace_after")
        var options = MSCXEncoderOptions()
        options.emitPreservedMarkup = false
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source), options: options)
        let root = try XMLTreeParser.parse(encoded)
        let score = try #require(root.first("Score"))
        let order = score.first("Order")
        let showFrames = score.first("showFrames")
        #expect(order == nil)
        #expect(showFrames == nil)
    }

    @Test("strippingPreservedMarkup clears it")
    func strippingClearsPreservedMarkup() throws {
        let source = try MSCXFixtureLoader.mscxData("grace_after")
        var score = try MSCXParser.parse(source)
        let marker = PreservedXML(name: "unknown")
        score.parts[0].preservedMarkup = [marker]
        score.parts[0].instrument.preservedMarkup = [marker]
        score.parts[0].instrument.channels[0].preservedMarkup = [marker]
        score.parts[0].staves[0].preservedMarkup = [marker]
        score.parts[0].staves[0].staffTypePreservedMarkup = [marker]
        score.parts[0].staves[0].measures[0].preservedMarkup = [marker]
        let stripped = score.strippingPreservedMarkup()
        #expect(stripped.preservedMarkup.isEmpty)
        #expect(stripped.style.preservedMarkup.isEmpty)
        #expect(stripped.parts[0].preservedMarkup.isEmpty)
        #expect(stripped.parts[0].instrument.preservedMarkup.isEmpty)
        #expect(stripped.parts[0].instrument.channels[0].preservedMarkup.isEmpty)
        #expect(stripped.parts[0].staves[0].preservedMarkup.isEmpty)
        #expect(stripped.parts[0].staves[0].staffTypePreservedMarkup.isEmpty)
        #expect(stripped.parts[0].staves[0].measures[0].preservedMarkup.isEmpty)
    }

    /// A tag that appears both in a node's preserved markup and in
    /// the children the encoder writes means the decoder read it but
    /// its consumed set does not list it. The emit helper quietly
    /// drops that duplicate, so the preservation and idempotency
    /// gates cannot expose the drift; this test compares against an
    /// encode with preserved markup disabled so it can.
    @Test("no preserved tag collides with one the encoder writes")
    func preservedNamesNeverCollide() throws {
        for url in MSCXFixtureLoader.allMSCXURLs() {
            guard let score = try? MSCXParser.parse(Data(contentsOf: url)) else { continue }
            var options = MSCXEncoderOptions()
            options.emitPreservedMarkup = false
            let root = try score.encode(options: options)
            let encodedScore = try #require(root.first("Score"))

            let scoreNames = Set(score.preservedMarkup.map(\.name))
            let writtenScoreNames = Set(encodedScore.children.map(\.name))
            let scoreCollisions = scoreNames.intersection(writtenScoreNames).sorted()
            #expect(
                scoreCollisions.isEmpty,
                Comment(
                    rawValue: "\(url.lastPathComponent): <Score> writes \(scoreCollisions) and also "
                        + "preserves them — add them to the decoder's consumed set",
                ),
            )

            let styleNames = Set(score.style.preservedMarkup.map(\.name))
            let writtenStyleNames = Set(encodedScore.first("Style")?.children.map(\.name) ?? [])
            let styleCollisions = styleNames.intersection(writtenStyleNames).sorted()
            #expect(
                styleCollisions.isEmpty,
                Comment(
                    rawValue: "\(url.lastPathComponent): <Style> writes \(styleCollisions) and also "
                        + "preserves them — add them to the decoder's consumed set",
                ),
            )

            try expectNoPartLevelNameCollisions(
                score: score,
                writtenScore: encodedScore,
                sourceName: url.lastPathComponent,
            )
            expectNoMeasureNameCollisions(
                score: score,
                writtenScore: encodedScore,
                sourceName: url.lastPathComponent,
            )
        }
    }

    private func expectNoMeasureNameCollisions(
        score: Score,
        writtenScore: XMLTreeNode,
        sourceName: String,
    ) {
        let staves = score.parts.flatMap(\.staves)
        for (staffIndex, pair) in zip(staves, writtenScore.all("Staff")).enumerated() {
            for (measureIndex, measurePair) in zip(
                pair.0.measures,
                pair.1.all("Measure"),
            ).enumerated() {
                expectNoNameCollision(
                    measurePair.0.preservedMarkup,
                    writtenChildren: measurePair.1.children,
                    context: "\(sourceName): <Staff>[\(staffIndex)]/<Measure>[\(measureIndex)]",
                )
            }
        }
    }

    private func expectNoPartLevelNameCollisions(
        score: Score,
        writtenScore: XMLTreeNode,
        sourceName: String,
    ) throws {
        for (partIndex, pair) in zip(score.parts, writtenScore.all("Part")).enumerated() {
            let part = pair.0
            let writtenPart = pair.1
            let context = "\(sourceName): <Part>[\(partIndex)]"
            expectNoNameCollision(
                part.preservedMarkup,
                writtenChildren: writtenPart.children,
                context: context,
            )
            let writtenInstrument = try #require(writtenPart.first("Instrument"))
            let instrumentContext = "\(context)/<Instrument>"
            let permittedInstrumentCollisions: Set<String> = part.instrument.useDrumset
                ? ["instrumentId"]
                : []
            expectNoNameCollision(
                part.instrument.preservedMarkup,
                writtenChildren: writtenInstrument.children,
                permitted: permittedInstrumentCollisions,
                context: instrumentContext,
            )
            for (channelIndex, channelPair) in zip(
                part.instrument.channels,
                writtenInstrument.all("Channel"),
            ).enumerated() {
                expectNoNameCollision(
                    channelPair.0.preservedMarkup,
                    writtenChildren: channelPair.1.children,
                    context: "\(instrumentContext)/<Channel>[\(channelIndex)]",
                )
            }
            for (staffIndex, staffPair) in zip(
                part.staves,
                writtenPart.all("Staff"),
            ).enumerated() {
                let staff = staffPair.0
                let writtenStaff = staffPair.1
                let staffContext = "\(context)/<Staff>[\(staffIndex)]"
                expectNoNameCollision(
                    staff.preservedMarkup,
                    writtenChildren: writtenStaff.children,
                    context: staffContext,
                )
                let writtenStaffType = try #require(writtenStaff.first("StaffType"))
                expectNoNameCollision(
                    staff.staffTypePreservedMarkup,
                    writtenChildren: writtenStaffType.children,
                    context: "\(staffContext)/<StaffType>",
                )
            }
        }
    }

    private func expectNoNameCollision(
        _ preservedMarkup: [PreservedXML],
        writtenChildren: [XMLTreeNode],
        permitted: Set<String> = [],
        context: String,
    ) {
        let preservedNames = Set(preservedMarkup.map(\.name))
        let writtenNames = Set(writtenChildren.map(\.name))
        let collisions = preservedNames.intersection(writtenNames)
            .subtracting(permitted)
            .sorted()
        #expect(
            collisions.isEmpty,
            Comment(
                rawValue: "\(context) writes \(collisions) and also preserves them — "
                    + "add them to the decoder's consumed set",
            ),
        )
    }
}
