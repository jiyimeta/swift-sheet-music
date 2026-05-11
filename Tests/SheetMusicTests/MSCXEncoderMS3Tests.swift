import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder MS3 target")
struct MSCXEncoderMS3Tests {
    @Test("MSCXVersion has v3 and v4 cases")
    func mscxVersionCases() {
        let v3: MSCXVersion = .v3
        let v4: MSCXVersion = .v4
        #expect(v3 != v4)
    }

    @Test("MSCXEncoderOptions defaults to v4")
    func optionsDefaultsToV4() {
        let opts = MSCXEncoderOptions()
        #expect(opts.targetVersion == .v4)
    }

    @Test("MSCXEncoderOptions accepts v3")
    func optionsAcceptsV3() {
        let opts = MSCXEncoderOptions(targetVersion: .v3)
        #expect(opts.targetVersion == .v3)
    }

    @Test("MSCXEncoder.encode(_:options:) v4 default matches zero-arg")
    func encodeOptionsV4DefaultMatchesLegacy() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let legacy = try MSCXEncoder.encode(score)
        let options = try MSCXEncoder.encode(score, options: .init())
        #expect(legacy == options)
    }

    @Test("MSCZWriter.write(score:options:) round-trips score")
    func msczWriteOptionsRoundTrips() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCZWriter.write(score: score, options: .init())
        let reparsed = try MSCZReader.parse(bytes)
        #expect(reparsed.parts.count == score.parts.count)
    }

    @Test("SheetMusic.exportMSCZ accepts options")
    func sheetMusicExportMSCZAcceptsOptions() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ms3-export-\(UUID().uuidString).mscz",
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try SheetMusic.exportMSCZ(score, options: .init(targetVersion: .v3), to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("v3 root museScore version is 3.02")
    func v3RootVersionIs302() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)
        #expect(root.attributes["version"] == "3.02")
    }

    @Test("v4 root museScore version is 4.60")
    func v4RootVersionIs460() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
        let root = try XMLTreeParser.parse(bytes)
        #expect(root.attributes["version"] == "4.60")
    }

    @Test("v3 emits programVersion and programRevision before Score")
    func v3EmitsProgramVersionAndRevision() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)
        let names = root.children.map(\.name)
        #expect(names == ["programVersion", "programRevision", "Score"])
        #expect(root.first("programVersion")?.text == "3.6.2")
        #expect(root.first("programRevision")?.text == "3224f34")
    }

    @Test("v4 does not emit programVersion or programRevision")
    func v4OmitsProgramVersionAndRevision() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
        let root = try XMLTreeParser.parse(bytes)
        let names = root.children.map(\.name)
        #expect(names == ["Score"])
    }

    @Test("v3 emits LayerTag and currentLayer before Division")
    func v3EmitsLayerTagBeforeDivision() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)
        let scoreElement = try #require(root.first("Score"))
        let firstThree = scoreElement.children.prefix(3).map(\.name)
        #expect(firstThree == ["LayerTag", "currentLayer", "Division"])
        let layerTag = try #require(scoreElement.first("LayerTag"))
        #expect(layerTag.attributes["id"] == "0")
        #expect(layerTag.attributes["tag"] == "default")
        #expect(scoreElement.first("currentLayer")?.text == "0")
    }

    @Test("v4 has no LayerTag or currentLayer")
    func v4OmitsLayerTag() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
        let root = try XMLTreeParser.parse(bytes)
        let scoreElement = try #require(root.first("Score"))
        let names = scoreElement.children.map(\.name)
        #expect(!names.contains("LayerTag"))
        #expect(!names.contains("currentLayer"))
    }

    @Test("v3 emits show* flags after Style")
    func v3EmitsShowFlagsAfterStyle() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)
        let scoreElement = try #require(root.first("Score"))
        let names = scoreElement.children.map(\.name)
        let styleIndex = try #require(names.firstIndex(of: "Style"))
        #expect(
            Array(names[(styleIndex + 1) ... (styleIndex + 4)])
                == ["showInvisible", "showUnprintable", "showFrames", "showMargins"],
        )
        #expect(scoreElement.first("showInvisible")?.text == "1")
        #expect(scoreElement.first("showUnprintable")?.text == "1")
        #expect(scoreElement.first("showFrames")?.text == "1")
        #expect(scoreElement.first("showMargins")?.text == "0")
    }

    @Test("v3 emits canonical 13 metaTags in fixed order")
    func v3EmitsCanonical13MetaTags() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)
        let scoreElement = try #require(root.first("Score"))
        let metaNames = scoreElement.children
            .filter { $0.name == "metaTag" }
            .compactMap { $0.attributes["name"] }
        #expect(metaNames == [
            "arranger", "composer", "copyright", "creationDate",
            "lyricist", "movementNumber", "movementTitle", "platform",
            "poet", "source", "translator", "workNumber", "workTitle",
        ])
        let platform = scoreElement.children
            .first { $0.name == "metaTag" && $0.attributes["name"] == "platform" }
        #expect(platform?.text == "Apple Macintosh")
        let creationDate = scoreElement.children
            .first { $0.name == "metaTag" && $0.attributes["name"] == "creationDate" }
        let date = try #require(creationDate?.text)
        let regex = try Regex(#"^\d{4}-\d{2}-\d{2}$"#)
        #expect(date.wholeMatch(of: regex) != nil)
    }

    @Test("v3 metaTags use score-supplied values when present")
    func v3MetaTagsUseScoreValues() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        score.metaTags["composer"] = "J. S. Bach"
        score.metaTags["platform"] = "Linux"
        score.metaTags["creationDate"] = "1750-07-28"
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)
        let scoreElement = try #require(root.first("Score"))
        func value(_ name: String) -> String? {
            scoreElement.children
                .first { $0.name == "metaTag" && $0.attributes["name"] == name }?
                .text
        }
        #expect(value("composer") == "J. S. Bach")
        #expect(value("platform") == "Linux")
        #expect(value("creationDate") == "1750-07-28")
    }

    @Test("v4 metaTags use existing sorted-by-key emission")
    func v4MetaTagsUnchanged() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        score.metaTags = ["composer": "X", "arranger": "Y"]
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
        let root = try XMLTreeParser.parse(bytes)
        let scoreElement = try #require(root.first("Score"))
        let metaNames = scoreElement.children
            .filter { $0.name == "metaTag" }
            .compactMap { $0.attributes["name"] }
        #expect(metaNames == ["arranger", "composer"])
    }

    @Test("v3 Style block has only <Spatium> child (capital S)")
    func v3StyleEmitsOnlyCapitalSpatium() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)
        let style = try #require(root.first("Score")?.first("Style"))
        #expect(style.children.count == 1)
        #expect(style.children[0].name == "Spatium")
        #expect(style.children[0].text == String(score.style.spatium))
    }

    @Test("v4 Style block keeps existing emission (lowercase spatium)")
    func v4StyleEmissionUnchanged() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
        let root = try XMLTreeParser.parse(bytes)
        let style = try #require(root.first("Score")?.first("Style"))
        let names = style.children.map(\.name)
        #expect(names.contains("spatium"))
        #expect(!names.contains("Spatium"))
    }

    @Test("Initial KeySig with concertKey 0 is omitted (v4)")
    func initialZeroKeySigOmittedV4() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        // Force a leading C-major KeySig on staff 0 / measure 0 / voice 0.
        var voice = score.parts[0].staves[0].measures[0].voices[0]
        let withoutKeySig = voice.elements.filter {
            if case .keySignature = $0 { false } else { true }
        }
        var newElements: [VoiceElement] = [
            .keySignature(KeySignature(concertKey: 0)),
        ]
        newElements.append(contentsOf: withoutKeySig)
        voice.elements = newElements
        score.parts[0].staves[0].measures[0].voices[0] = voice

        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
        let root = try XMLTreeParser.parse(bytes)
        // Top-level (body) Staff comes after Part-scoped declaration Staffs.
        let staffBody = root.first("Score")?.children
            .last(where: { $0.name == "Staff" })
        let firstMeasure = try #require(staffBody?.first("Measure"))
        let firstVoice = try #require(firstMeasure.first("voice"))
        let voiceChildNames = firstVoice.children.map(\.name)
        #expect(!voiceChildNames.contains("KeySig"))
    }

    @Test("Initial KeySig with concertKey 0 is omitted (v3)")
    func initialZeroKeySigOmittedV3() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        var voice = score.parts[0].staves[0].measures[0].voices[0]
        let withoutKeySig = voice.elements.filter {
            if case .keySignature = $0 { false } else { true }
        }
        var newElements: [VoiceElement] = [
            .keySignature(KeySignature(concertKey: 0)),
        ]
        newElements.append(contentsOf: withoutKeySig)
        voice.elements = newElements
        score.parts[0].staves[0].measures[0].voices[0] = voice

        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)
        let staffBody = root.first("Score")?.children
            .last(where: { $0.name == "Staff" })
        let firstMeasure = try #require(staffBody?.first("Measure"))
        let firstVoice = try #require(firstMeasure.first("voice"))
        let voiceChildNames = firstVoice.children.map(\.name)
        #expect(!voiceChildNames.contains("KeySig"))
    }

    @Test("Mid-piece KeySig change still emitted (v4)")
    func midKeySigChangeStillEmittedV4() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        // Need at least two measures in staff 0 to test mid-piece change.
        guard score.parts[0].staves[0].measures.count >= 2 else { return }
        var v = score.parts[0].staves[0].measures[1].voices[0]
        v.elements.insert(.keySignature(KeySignature(concertKey: 2)), at: 0)
        score.parts[0].staves[0].measures[1].voices[0] = v

        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
        let root = try XMLTreeParser.parse(bytes)
        let staffBody = root.first("Score")?.children
            .last(where: { $0.name == "Staff" })
        let measures = staffBody?.children.filter { $0.name == "Measure" } ?? []
        let secondMeasure = try #require(measures.count >= 2 ? measures[1] : nil)
        let secondVoice = try #require(secondMeasure.first("voice"))
        let voiceChildNames = secondVoice.children.map(\.name)
        #expect(voiceChildNames.contains("KeySig"))
    }

    @Test("Initial non-zero KeySig is still emitted (v4)")
    func initialNonZeroKeySigStillEmittedV4() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        var voice = score.parts[0].staves[0].measures[0].voices[0]
        let withoutKeySig = voice.elements.filter {
            if case .keySignature = $0 { false } else { true }
        }
        var newElements: [VoiceElement] = [
            .keySignature(KeySignature(concertKey: 3)),
        ]
        newElements.append(contentsOf: withoutKeySig)
        voice.elements = newElements
        score.parts[0].staves[0].measures[0].voices[0] = voice

        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
        let root = try XMLTreeParser.parse(bytes)
        let staffBody = root.first("Score")?.children
            .last(where: { $0.name == "Staff" })
        let firstMeasure = try #require(staffBody?.first("Measure"))
        let firstVoice = try #require(firstMeasure.first("voice"))
        let voiceChildNames = firstVoice.children.map(\.name)
        #expect(voiceChildNames.contains("KeySig"))
    }

    @Test("v3 KeySig body emits <accidental>")
    func v3KeySigEmitsAccidental() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        // Use an initial non-zero KeySig — that path actually emits
        // (initial concertKey == 0 is suppressed at the staff head),
        // and midi01 has only one measure so a mid-piece change isn't
        // available here.
        var voice = score.parts[0].staves[0].measures[0].voices[0]
        let withoutKeySig = voice.elements.filter {
            if case .keySignature = $0 { false } else { true }
        }
        var newElements: [VoiceElement] = [
            .keySignature(KeySignature(concertKey: 2)),
        ]
        newElements.append(contentsOf: withoutKeySig)
        voice.elements = newElements
        score.parts[0].staves[0].measures[0].voices[0] = voice

        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)
        let staffBody = root.first("Score")?.children
            .last(where: { $0.name == "Staff" })
        let firstMeasure = try #require(staffBody?.first("Measure"))
        let keySig = try #require(firstMeasure.first("voice")?.first("KeySig"))
        #expect(keySig.first("accidental")?.text == "2")
        #expect(!keySig.children.map(\.name).contains("concertKey"))
    }

    @Test("v3 Spanner location emits <measures> before <fractions>")
    func v3SpannerLocationOrderReversed() throws {
        let spanner = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            nextMeasuresOffset: 1,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
        )
        let xml = spanner.encode(options: .init(targetVersion: .v3))
        let location = try #require(xml.first("next")?.first("location"))
        #expect(location.children.map(\.name) == ["measures", "fractions"])
    }

    @Test("v4 Spanner location order unchanged (fractions first)")
    func v4SpannerLocationOrderUnchanged() throws {
        let spanner = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            nextMeasuresOffset: 1,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
        )
        let xml = spanner.encode(options: .init(targetVersion: .v4))
        let location = try #require(xml.first("next")?.first("location"))
        #expect(location.children.map(\.name) == ["fractions", "measures"])
    }

    @Test("v3 Spanner skip-if-default still applies")
    func v3SpannerSkipIfDefault() {
        let spanner = Spanner(
            kind: .hairpin,
            rawType: "HairPin",
            nextMeasuresOffset: 0,
            nextFractionsOffset: nil,
        )
        let xml = spanner.encode(options: .init(targetVersion: .v3))
        #expect(!xml.children.map(\.name).contains("next"))
    }

    @Test("v4 KeySig body keeps <concertKey>")
    func v4KeySigKeepsConcertKey() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        var voice = score.parts[0].staves[0].measures[0].voices[0]
        let withoutKeySig = voice.elements.filter {
            if case .keySignature = $0 { false } else { true }
        }
        var newElements: [VoiceElement] = [
            .keySignature(KeySignature(concertKey: 2)),
        ]
        newElements.append(contentsOf: withoutKeySig)
        voice.elements = newElements
        score.parts[0].staves[0].measures[0].voices[0] = voice

        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
        let root = try XMLTreeParser.parse(bytes)
        let staffBody = root.first("Score")?.children
            .last(where: { $0.name == "Staff" })
        let firstMeasure = try #require(staffBody?.first("Measure"))
        let keySig = try #require(firstMeasure.first("voice")?.first("KeySig"))
        #expect(keySig.first("concertKey")?.text == "2")
        #expect(!keySig.children.map(\.name).contains("accidental"))
    }
}
