import Foundation
import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

// One suite owns the primitive, fixture, stripping, and collision coverage.
// swiftlint:disable file_length

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

    /// `<StringData>` reaches the output through `Instrument.stringData` now
    /// rather than through a preserved bag (`StringDataTests`); it is still
    /// asserted here because this test's subject is that a `<Part>` survives
    /// intact, and `<clef>` beside it is genuinely preserved markup.
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
        // Deliberately not a real MuseScore element. This test is about an
        // *unknown* child holding its position, not about any particular one.
        // It previously used <FiguredBass>, then <Symbol>, and broke each time
        // that element was modeled; a synthetic tag ends that cycle.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part><Staff id="1"/><Instrument/></Part>
        <Staff id="1"><Measure><voice>
        <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        <UnmodeledElement><name>segno</name></UnmodeledElement>
        <Chord><durationType>quarter</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
        </voice></Measure></Staff></Score></museScore>
        """
        let score = try MSCXParser.parse(Data(xml.utf8))
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        guard case let .preserved(kept) = elements[1] else {
            Issue.record(Comment(
                rawValue: "expected the UnmodeledElement between the two chords, got \(elements)",
            ))
            return
        }
        #expect(kept.name == "UnmodeledElement")

        let root = try XMLTreeParser.parse(MSCXEncoder.encode(score))
        let voice = try #require(
            root.first("Score")?.all("Staff").last?
                .first("Measure")?.first("voice"),
        )
        #expect(voice.children.map(\.name) == ["Chord", "UnmodeledElement", "Chord"])
    }

    @Test("<LayoutBreak><subtype>nobreak</subtype> survives")
    func nobreakLayoutBreakSurvives() throws {
        let source = try MSCXFixtureLoader.mscxData("testMeasureRepeats")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("nobreak"))
    }

    @Test("<Chord><StemDirection> and <Note><Events> survive")
    func chordAndNoteMarkupSurvives() throws {
        let source = try MSCXFixtureLoader.mscxData("testDurationLargeError_ref")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(Self.occurrences(of: "<StemDirection>", in: text) == 14)
        #expect(Self.occurrences(of: "<Events>", in: text) == 2)
    }

    @Test("a non-parenthesis <Note><Symbol> survives")
    func unmodeledNoteSymbolSurvives() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part><Staff id="1"/><Instrument/></Part>
        <Staff id="1"><Measure><voice><Chord><durationType>quarter</durationType>
        <Note><Symbol><name>guitarString0</name></Symbol><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord></voice></Measure></Staff></Score></museScore>
        """
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(Data(xml.utf8)))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("<Symbol>"))
        #expect(text.contains("<name>guitarString0</name>"))
    }

    @Test("grace-chord <BeamMode> and <noStem> survive")
    func graceChordMarkupSurvives() throws {
        let source = try MSCXFixtureLoader.mscxData("guitarbend_gracebend")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(Self.occurrences(of: "<BeamMode>", in: text) == 3)
        #expect(Self.occurrences(of: "<noStem>", in: text) == 3)
    }

    @Test("<BarLine><span> survives")
    func barLineMarkupSurvives() throws {
        let source = try MSCXFixtureLoader.mscxData("legacybend_ms3_canonical")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("<span>1</span>"))
    }

    @Test("modeled <Arpeggio> content is re-emitted")
    func arpeggioContentSurvives() throws {
        let source = try MSCXFixtureLoader.mscxData("testArpeggio")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(Self.occurrences(of: "<Arpeggio>", in: text) == 5)
        #expect(Self.occurrences(of: "<timeStretch>", in: text) == 3)
        #expect(Self.occurrences(of: "<userLen1>", in: text) == 3)
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
        Self.installTask6Markup(marker, in: &score)
        let stripped = score.strippingPreservedMarkup()
        #expect(stripped.preservedMarkup.isEmpty)
        #expect(stripped.style.preservedMarkup.isEmpty)
        #expect(stripped.parts[0].preservedMarkup.isEmpty)
        #expect(stripped.parts[0].instrument.preservedMarkup.isEmpty)
        #expect(stripped.parts[0].instrument.channels[0].preservedMarkup.isEmpty)
        #expect(stripped.parts[0].staves[0].preservedMarkup.isEmpty)
        #expect(stripped.parts[0].staves[0].staffTypePreservedMarkup.isEmpty)
        #expect(stripped.parts[0].staves[0].measures[0].preservedMarkup.isEmpty)
        #expect(Self.task6Markup(in: stripped).isEmpty)
    }

    /// `strippingPreservedMarkup()` used to walk `blocks` and `parts`
    /// and nothing else, so the whole system lane — `Score.systemMeasures`
    /// — was never visited. The only bag reachable from a `SystemElement`
    /// is the one on the `Instrument` an `.instrumentChange` swaps in
    /// (and, below it, its `StringData` and its channels), which is why
    /// this went unnoticed: it needs a mid-score instrument change to
    /// show up at all.
    @Test("strippingPreservedMarkup reaches the system lane")
    func strippingClearsSystemElementMarkup() throws {
        let url = try #require(
            TestResources.url(forResource: "instrument-change", withExtension: "mscx"),
        )
        var score = try MSCXParser.parse(Data(contentsOf: url))
        let marker = PreservedXML(name: "unknown")

        var seeded = 0
        for measureIndex in score.systemMeasures.indices {
            for elementIndex in score.systemMeasures[measureIndex].elements.indices {
                guard case var .instrumentChange(change) =
                    score.systemMeasures[measureIndex].elements[elementIndex].element,
                    var instrument = change.instrument
                else { continue }
                instrument.preservedMarkup = [marker]
                for channelIndex in instrument.channels.indices {
                    instrument.channels[channelIndex].preservedMarkup = [marker]
                }
                change.instrument = instrument
                score.systemMeasures[measureIndex].elements[elementIndex].element =
                    .instrumentChange(change)
                seeded += 1
            }
        }
        // Without this the assertions below pass on an empty walk.
        #expect(seeded > 0, "fixture no longer carries a mid-score instrument change")

        let stripped = score.strippingPreservedMarkup()
        var remaining = 0
        for measure in stripped.systemMeasures {
            for positioned in measure.elements {
                guard case let .instrumentChange(change) = positioned.element,
                      let instrument = change.instrument
                else { continue }
                remaining += instrument.preservedMarkup.count
                remaining += instrument.stringData?.preservedMarkup.count ?? 0
                remaining += instrument.channels.reduce(0) { $0 + $1.preservedMarkup.count }
            }
        }
        #expect(remaining == 0)
    }

    /// **The walk's completeness gate.** Every test above names the
    /// bags it checks, so each one only proves that the author
    /// remembered their own type. `strippingPreservedMarkup()` was
    /// edited three times on 2026-09-06 by three people adding three
    /// different element kinds, and none of them asked what the
    /// function is supposed to reach — which is how the system lane
    /// stayed unvisited and how the grace-note path kept clearing
    /// `symbols` but not `fingerings`.
    ///
    /// This test asks instead. It reflects over the whole stripped
    /// `Score` and fails on any `[PreservedXML]` left non-empty
    /// anywhere in it, so a type added later is covered without anyone
    /// editing this file — **as long as a fixture puts that type in a
    /// score.** It replaces a hand-written list of bags with a
    /// hand-written corpus, which is better but not complete: the
    /// grace-note fingering fix below is a shape no fixture contains,
    /// and this sweep passes with or without it. Reach for a targeted
    /// test whenever the corpus does not exercise the shape.
    ///
    /// It sweeps every committed fixture rather than a named list for
    /// the same reason. A list would be a hand-maintained table of
    /// what is covered — the very thing this test replaces — one level
    /// up: someone adding `figured-bass.mscx` would have to remember to
    /// add it here, and nothing would tell them if they did not.
    @Test("no preserved markup survives anywhere in a stripped score")
    func strippingLeavesNoBagAnywhere() {
        var scoresWithMarkup = 0
        var leftovers: [String] = []
        for url in MSCXFixtureLoader.allMSCXURLs() {
            // Same policy as the preservation gate: a fixture this
            // reader does not claim to open says nothing either way.
            guard let data = try? Data(contentsOf: url),
                  let score = try? MSCXParser.parse(data)
            else { continue }

            let name = url.lastPathComponent
            if !Self.nonEmptyPreservedBagPaths(in: score, path: name).isEmpty {
                scoresWithMarkup += 1
            }
            leftovers += Self.nonEmptyPreservedBagPaths(
                in: score.strippingPreservedMarkup(), path: name,
            )
        }

        // Without this, a corpus whose bags all happen to be empty
        // would pass no matter what the walk does — the same blindness
        // the preservation gate has toward a tag no fixture contains.
        #expect(scoresWithMarkup > 0, "no committed fixture carries preserved markup")
        #expect(leftovers.isEmpty, "not stripped: \(leftovers.sorted().joined(separator: ", "))")
    }

    /// A fingering on a grace note kept its markup, and the sweep above
    /// cannot see it: no committed fixture puts a `<Fingering>` on a
    /// grace note, so the reflective walk never reaches one. That is the
    /// same blindness the preservation gate has toward a tag no fixture
    /// contains — the sweep proves the walk covers the corpus, not that
    /// the corpus covers the model. This test supplies the shape the
    /// corpus lacks by attaching the fingering itself.
    @Test("a fingering on a grace note is stripped like one on a full note")
    func strippingClearsGraceNoteFingerings() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("grace_after"))
        let marker = PreservedXML(name: "unknown")

        var seeded = 0
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                for measureIndex in score.parts[partIndex].staves[staffIndex].measures.indices {
                    seedGraceFingerings(
                        marker,
                        in: &score.parts[partIndex].staves[staffIndex].measures[measureIndex],
                        count: &seeded,
                    )
                }
            }
        }
        #expect(seeded > 0, "grace_after no longer carries a grace chord with notes")

        let leftovers = Self.nonEmptyPreservedBagPaths(in: score.strippingPreservedMarkup())
        #expect(leftovers.isEmpty, "not stripped: \(leftovers.sorted().joined(separator: ", "))")
    }

    /// Give every grace note in `measure` a fingering carrying `marker`.
    private func seedGraceFingerings(
        _ marker: PreservedXML, in measure: inout Measure, count: inout Int,
    ) {
        for voiceIndex in measure.voices.indices {
            for elementIndex in measure.voices[voiceIndex].elements.indices {
                guard case var .chord(chord) = measure.voices[voiceIndex].elements[elementIndex]
                else { continue }
                seedGraceFingerings(marker, in: &chord.graceNotesBefore, count: &count)
                seedGraceFingerings(marker, in: &chord.graceNotesAfter, count: &count)
                measure.voices[voiceIndex].elements[elementIndex] = .chord(chord)
            }
        }
    }

    private func seedGraceFingerings(
        _ marker: PreservedXML, in graces: inout [GraceChord], count: inout Int,
    ) {
        for graceIndex in graces.indices {
            for noteIndex in graces[graceIndex].notes.indices {
                graces[graceIndex].notes[noteIndex].fingerings = [
                    Fingering(text: "1", preservedMarkup: [marker]),
                ]
                count += 1
            }
        }
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
            expectNoTask6NameCollisions(
                score: score,
                sourceName: url.lastPathComponent,
                options: options,
            )
        }
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}

extension MSCXPreservedMarkupTests {
    fileprivate static func installTask6Markup(_ marker: PreservedXML, in score: inout Score) {
        let note = Note(pitch: 60, tpc: 14, preservedMarkup: [marker])
        let grace = GraceChord(
            graceType: .acciaccatura,
            duration: .eighth,
            notes: ChordNotes([note]),
            preservedMarkup: [marker],
        )
        let spanner = Spanner(
            kind: .slur,
            rawType: "Slur",
            preservedMarkup: [marker],
        )
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([note]),
            lyrics: [Lyric(text: "la", preservedMarkup: [marker])],
            graceNotesBefore: [grace],
            spanners: [spanner],
            preservedMarkup: [marker],
        )
        var measure = score.parts[0].staves[0].measures[0]
        measure.markers = [Marker(kind: .segno, preservedMarkup: [marker])]
        measure.jumps = [Jump(jumpTo: "start", playUntil: "end", preservedMarkup: [marker])]
        measure.voices[0].elements = [
            .chord(chord),
            .keySignature(KeySignature(concertKey: 0, preservedMarkup: [marker])),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4, preservedMarkup: [marker])),
            .clef(Clef(concertClefType: "G", preservedMarkup: [marker])),
            .barLine(BarLine(preservedMarkup: [marker])),
            .dynamic(Dynamic(subtype: "mf", velocity: 80, preservedMarkup: [marker])),
            .spanner(spanner),
            .harmony(Harmony(name: "C", preservedMarkup: [marker])),
            .sticking(Sticking(text: "R", preservedMarkup: [marker])),
            .expression(ExpressionText(text: "dolce", preservedMarkup: [marker])),
            .capo(Capo(text: "Capo 2", preservedMarkup: [marker])),
            .stringTunings(StringTunings(
                preset: "Drop D",
                stringData: StringData(preservedMarkup: [marker]),
                preservedMarkup: [marker],
            )),
            .ambitus(Ambitus(
                topPitch: 72,
                topTpc: 14,
                bottomPitch: 60,
                bottomTpc: 14,
                preservedMarkup: [marker],
            )),
            .figuredBass(FiguredBass(
                items: [FiguredBassItem(digit: 6, preservedMarkup: [marker])],
                preservedMarkup: [marker],
            )),
        ]
        score.parts[0].staves[0].measures[0] = measure
    }

    fileprivate static func task6Markup(in score: Score) -> [PreservedXML] {
        let measure = score.parts[0].staves[0].measures[0]
        var result = measure.markers.flatMap(\.preservedMarkup)
            + measure.jumps.flatMap(\.preservedMarkup)
        for element in measure.voices[0].elements {
            if case let .chord(value) = element { result += task6Markup(in: value) }
            if case let .keySignature(value) = element { result += value.preservedMarkup }
            if case let .timeSignature(value) = element { result += value.preservedMarkup }
            if case let .clef(value) = element { result += value.preservedMarkup }
            if case let .barLine(value) = element { result += value.preservedMarkup }
            if case let .dynamic(value) = element { result += value.preservedMarkup }
            if case let .spanner(value) = element { result += value.preservedMarkup }
            if case let .harmony(value) = element { result += value.preservedMarkup }
            if case let .sticking(value) = element { result += value.preservedMarkup }
            if case let .expression(value) = element { result += value.preservedMarkup }
            if case let .capo(value) = element { result += value.preservedMarkup }
            if case let .stringTunings(value) = element {
                result += value.preservedMarkup
                result += value.stringData?.preservedMarkup ?? []
            }
            if case let .ambitus(value) = element { result += value.preservedMarkup }
            if case let .figuredBass(value) = element {
                result += value.preservedMarkup
                result += value.items.flatMap(\.preservedMarkup)
            }
        }
        return result
    }

    fileprivate static func task6Markup(in chord: Chord) -> [PreservedXML] {
        chord.preservedMarkup
            + chord.notes.flatMap(\.preservedMarkup)
            + chord.lyrics.flatMap(\.preservedMarkup)
            + chord.spanners.flatMap(\.preservedMarkup)
            + chord.graceNotesBefore.flatMap {
                $0.preservedMarkup + $0.notes.flatMap(\.preservedMarkup)
            }
            + chord.graceNotesAfter.flatMap {
                $0.preservedMarkup + $0.notes.flatMap(\.preservedMarkup)
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
            if let stringData = part.instrument.stringData,
               let writtenStringData = writtenInstrument.first("StringData")
            {
                expectNoNameCollision(
                    stringData.preservedMarkup,
                    writtenChildren: writtenStringData.children,
                    context: "\(instrumentContext)/<StringData>",
                )
            }
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

    private func expectNoTask6NameCollisions(
        score: Score,
        sourceName: String,
        options: MSCXEncoderOptions,
    ) {
        for (partIndex, part) in score.parts.enumerated() {
            for (staffIndex, staff) in part.staves.enumerated() {
                for (measureIndex, measure) in staff.measures.enumerated() {
                    let context = "\(sourceName): <Part>[\(partIndex)]/<Staff>[\(staffIndex)]"
                        + "/<Measure>[\(measureIndex)]"
                    for (index, marker) in measure.markers.enumerated() {
                        expectNoNameCollision(
                            marker.preservedMarkup,
                            writtenChildren: marker.encode(options: options).children,
                            context: "\(context)/<Marker>[\(index)]",
                        )
                    }
                    for (index, jump) in measure.jumps.enumerated() {
                        expectNoNameCollision(
                            jump.preservedMarkup,
                            writtenChildren: jump.encode(options: options).children,
                            context: "\(context)/<Jump>[\(index)]",
                        )
                    }
                    for (voiceIndex, voice) in measure.voices.enumerated() {
                        for (elementIndex, element) in voice.elements.enumerated() {
                            expectNoVoiceElementNameCollisions(
                                element,
                                context: "\(context)/<voice>[\(voiceIndex)]/[\(elementIndex)]",
                                options: options,
                            )
                        }
                    }
                }
            }
        }
    }

    private func expectNoVoiceElementNameCollisions(
        _ element: VoiceElement,
        context: String,
        options: MSCXEncoderOptions,
    ) {
        if case let .chord(chord) = element {
            expectNoChordNameCollisions(chord, context: context, options: options)
        }
        if case let .keySignature(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .timeSignature(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .clef(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .dynamic(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .barLine(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .harmony(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .spanner(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .sticking(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .expression(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .capo(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .stringTunings(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .ambitus(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
        }
        if case let .figuredBass(value) = element {
            expectNoNameCollision(value.preservedMarkup, value.encode(options: options), context: context)
            for (index, item) in value.items.enumerated() {
                expectNoNameCollision(
                    item.preservedMarkup,
                    writtenChildren: item.encode(options: options).children,
                    context: "\(context)/<FiguredBassItem>[\(index)]",
                )
            }
        }
    }

    private func expectNoChordNameCollisions(
        _ chord: Chord,
        context: String,
        options: MSCXEncoderOptions,
    ) {
        // A `.measure` rest traps in the single-argument `encodeAsRest`
        // overload, which exists precisely to catch a caller that lost
        // the measure's effective duration. This check only compares
        // TAG NAMES, and those do not depend on the resolved value, so
        // a nominal 4/4 is enough to reach the same child list.
        let written = chord.notes.isEmpty
            ? chord.encodeAsRest(
                options: options, in: Fraction(numerator: 4, denominator: 4),
            )
            : chord.encodeAsChord(options: options)
        expectNoNameCollision(chord.preservedMarkup, written, context: context)
        for (index, note) in chord.notes.enumerated() {
            expectNoNameCollision(
                note.preservedMarkup, note.encode(options: options),
                context: "\(context)/<Note>[\(index)]",
            )
        }
        for (index, lyric) in chord.lyrics.enumerated() {
            expectNoNameCollision(
                lyric.preservedMarkup, lyric.encode(options: options),
                context: "\(context)/<Lyrics>[\(index)]",
            )
        }
        for (index, spanner) in chord.spanners.enumerated() {
            expectNoNameCollision(
                spanner.preservedMarkup, spanner.encodeChordAnchoredBegin(options: options),
                context: "\(context)/<Spanner>[\(index)]",
            )
        }
        for (index, grace) in chord.mscxFileOrderedGraces.enumerated() {
            let graceContext = "\(context)/<Chord>[grace \(index)]"
            expectNoNameCollision(
                grace.preservedMarkup, grace.encode(parentChord: chord, options: options),
                context: graceContext,
            )
            for (noteIndex, note) in grace.notes.enumerated() {
                expectNoNameCollision(
                    note.preservedMarkup, note.encode(options: options),
                    context: "\(graceContext)/<Note>[\(noteIndex)]",
                )
            }
        }
    }

    private func expectNoNameCollision(
        _ preservedMarkup: [PreservedXML],
        _ writtenNode: XMLTreeNode,
        context: String,
    ) {
        expectNoNameCollision(
            preservedMarkup,
            writtenChildren: writtenNode.children,
            context: context,
        )
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

/// The reflective search the stripping tests run on a whole `Score`.
///
/// In an extension because SwiftLint's `type_body_length` is measured per
/// type body and the suite is already at the ceiling.
extension MSCXPreservedMarkupTests {
    /// Reflect over `root` and return a path for every preserved-markup
    /// property that still holds something.
    ///
    /// `Mirror` is used deliberately: a hand-written walk would need the
    /// same maintenance as the function under test and would go stale in
    /// the same way.
    ///
    /// A property counts by its **name**, not its type: any label
    /// containing both "preserved" and "markup" — `preservedMarkup`,
    /// `staffTypePreservedMarkup`, and a `preservedTextMarkup` added
    /// later. Matching `[PreservedXML]` alone would have been the same
    /// mistake one level down: a second bag type would be invisible to
    /// the gate meant to find bags, and the naming convention is the
    /// thing every such field actually shares. Recursion stops at a
    /// matched property, since its contents are carried source rather
    /// than more bags to clear.
    static func nonEmptyPreservedBagPaths(
        in root: Any, path: String = "Score", depth: Int = 0,
    ) -> [String] {
        // Reached without a label by `VoiceElement.preserved`. Its children
        // are carried XML, and an arbitrarily deep subtree of it would be
        // walked for nothing.
        if root is PreservedXML { return [] }
        guard depth < 40 else { return ["\(path): reflection depth exceeded"] }
        var found: [String] = []
        for (offset, child) in Mirror(reflecting: root).children.enumerated() {
            // Collection and enum-payload children have no label.
            let step = child.label.map { ".\($0)" } ?? "[\(offset)]"
            if isPreservedMarkupLabel(child.label) {
                if let size = occupancy(of: child.value) {
                    found.append("\(path)\(step) (\(size))")
                }
                continue
            }
            found += nonEmptyPreservedBagPaths(
                in: child.value, path: path + step, depth: depth + 1,
            )
        }
        return found
    }

    private static func isPreservedMarkupLabel(_ label: String?) -> Bool {
        guard let label = label?.lowercased() else { return false }
        return label.contains("preserved") && label.contains("markup")
    }

    /// How much a preserved-markup property holds, or `nil` when it is
    /// empty. Written against `Mirror` rather than a concrete type so an
    /// array, an optional, and a future wrapper all answer.
    private static func occupancy(of value: Any) -> Int? {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .collection, .optional:
            return mirror.children.isEmpty ? nil : mirror.children.count
        default:
            return 1
        }
    }
}
