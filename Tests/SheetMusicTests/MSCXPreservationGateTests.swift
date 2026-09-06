import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// **The preservation gate.** Decode a fixture, encode it, and
/// require that every `parent/child` element pair present in the
/// source still appears at least as often in the output.
///
/// The 2-pass idempotency gate cannot see this: it compares pass 1
/// with pass 2, and information the decoder never captured is
/// already gone from pass 1. `Score`-equality round trips cannot see
/// it either — both sides are missing the same thing.
///
/// Pairs are `parent/child`, not bare tag names, because a bare name
/// cannot tell a real loss from a legitimate move: MuseScore 2 and 3
/// write `<Chord>` directly under `<Measure>`, this encoder always
/// writes it under `<voice>`.
enum MSCXPreservation {
    /// Every `parent/child` pair whose count dropped, with the size
    /// of the drop.
    static func losses(source: Data, encoded: Data) throws -> [String: Int] {
        let sourceCounts = try counts(XMLTreeParser.parse(source))
        let encodedCounts = try counts(XMLTreeParser.parse(encoded))
        var result: [String: Int] = [:]
        for (pair, count) in sourceCounts {
            let encodedCount = encodedCounts[pair] ?? 0
            if encodedCount < count {
                result[pair] = count - encodedCount
            }
        }
        return result
    }

    /// `parent/child` to why this loss is accepted.
    ///
    /// Entries whose reason names a task are temporary and must be
    /// deleted by that task. Entries marked "by design" are
    /// permanent; each states the design decision it follows from.
    static let allowedLosses = makeAllowedLosses()

    private static let elementIdentityReason =
        "by design: MuseScore element identity is regenerated instead of preserved (spec §3.4)."
    private static let linkedIdentityReason =
        "genuinely lost under this design: <linked> / <linkedMain> is MuseScore's excerpt link "
            + "bookkeeping, which this library does not model at all. On a chord, note, rest, or "
            + "barline it now survives as preserved markup; these four sit INSIDE a modeled "
            + "spanner payload, where the wrapper-level bag cannot reach them. A payload-level bag "
            + "would be needed — see spannerPayloadReason, which is the same limitation."
    private static let flatFormReason =
        "by design: the MS2/MS3 flat form moves under <voice> in the encoder's canonical structure."
    private static let spatiumReason =
        "by design: the v4 encoder writes lowercase <spatium>; the decoded value round-trips."
    private static let endpointReason =
        "by design: spanner endpoint markers are recomputed from modeled offsets; "
            + "the <prev> side carries no model state (MSCXDecoder+Chord.swift)."
    private static let crossVoiceEndpointReason =
        endpointReason + " Voice deltas are genuinely lost because Spanner models "
            + "measure/fraction offsets but not cross-voice endpoints, as pinned by "
            + "slur_ms3_exchangevoices.mscx and MSCXDecoder+Chord.swift's "
            + "mscx.slur.locationDropped diagnostic."
    private static let tremoloReason =
        "by design: unsupported tremolo embellishments are dropped after a diagnostic under the parser policy."
    private static let legacyTempoTextReason =
        "by design: these pairs survive only inside Tempo text, which the encoder regenerates "
            + "from beatsPerSecond, beatNote, and beatDots rather than round-tripping. MuseScore "
            + "2/3 writes the metronome glyph as a ScoreText-font character, while this encoder "
            + "writes a <sym>, so the source and regenerated plain text differ and preservation "
            + "would decline under the preserve-if-equal rule. Recovering that markup needs a "
            + "separate Tempo dirty flag."
    private static let soundIDReason =
        "genuinely lost, and not fixable by preserving it: MuseScore's <Instrument id> attribute "
            + "(template id) and <instrumentId> element (MusicXML Sound ID) hold different values, "
            + "this decoder collapses them, and the encoder synthesizes the element for a drumset — "
            + "so preserving it would make a programmatic drumset score stop comparing equal to "
            + "itself across a round trip. Recovering the Sound ID needs Instrument to model it."
    private static let staffHeadCMajorReason =
        "by design, and not a preservation gap: this <KeySig> is a staff-head C major, which IS "
            + "modeled as VoiceElement.keySignature(concertKey: 0). The encoder omits re-emitting "
            + "it because MuseScore does not write a redundant natural-sign key at the staff head — "
            + "behavior pinned by MSCXEncoderMS3Tests.initialZeroKeySigOmittedV4. Preserved markup "
            + "cannot restore a tag the decoder consumed."
    private static let instrumentLabelReason =
        "by design: MuseScore 5's <InstrumentLabel> wrapper holds <longName> / <shortName>, which "
            + "are modeled and re-emitted in MuseScore 4's direct-child form. Preserving the "
            + "wrapper too would duplicate modeled data and go stale on the first rename."
    private static let defaultClefDialectReason =
        "by design, and the same shape as keySignatureDialectReason: MuseScore writes the "
            + "staff's default clef as <defaultClef>, or as <defaultConcertClef> / "
            + "<defaultTransposingClef>, or as both halves of the pair. "
            + "MSCXDecoder+Staff.swift collapses all three spellings into one defaultClefType "
            + "and the encoder writes <defaultClef>. Preserving the pair alongside it would "
            + "emit three tags where MuseScore wrote two, and the copies would contradict the "
            + "modeled value the moment a host changed the clef."
    private static let keySignatureDialectReason =
        "by design, and not a preservation gap: MSCXDecoder+KeySignature.swift consumes "
            + "<concertKey>, falls back to <accidental>, and uses <mode> in its custom-key "
            + "fallback; MSCXEncoder+KeySignature.swift then writes the target-version spelling. "
            + "Preserved markup cannot restore a tag the decoder consumed."
    private static let harmonyStructureReason =
        "by design, and not a preservation gap: Harmony.name is modeled, and "
            + "MSCXEncoder+Harmony.swift moves it into <harmonyInfo> for the v4.60 reader; "
            + "the parent/child pair changes while the value survives, as pinned by "
            + "harmony-basic.mscx."
    private static let defaultCourtesyReason =
        "by design, and not a preservation gap: MSCXDecoder+TimeSignature.swift consumes "
            + "explicit <showCourtesySig>1</showCourtesySig>, and MSCXEncoder+TimeSignature.swift "
            + "elides that default; testInitialKeySigThenRepeatToMeas2.mscx pins the canonical "
            + "omission."
    private static let noteParenthesisSymbolReason =
        "by design, and not a preservation gap in this corpus: every <Note><Symbol> lost here is "
            + "a noteheadParenthesisLeft/Right consumed by MSCXDecoder+Note.swift's "
            + "decodeParentheses and re-emitted by MSCXEncoder+Note.swift as <parentheses> / "
            + "<Parenthesis>, as pinned by guitarbend_prebend.mscx. Every other Symbol name is "
            + "now modeled as EngravingSymbol in Note.symbols and round-trips, which "
            + "engraving-symbols.mscx pins directly rather than through this gate.\n"
            + "CAVEAT: this entry keys on the Note/Symbol and Symbol/name paths, not on the "
            + "glyph name, so it would also absorb a genuine EngravingSymbol loss. The gate "
            + "cannot narrow it — it sees element paths, not values — so the non-vacuous "
            + "fixture test EngravingSymbolEncodeTests.fixtureDecodesEveryEngravingSymbolItCarries "
            + "is what actually pins symbol survival. Do not treat a green gate as covering it."
    private static let spannerPayloadReason =
        "genuinely lost under this design: these fields are nested inside a modeled spanner "
            + "payload, and the wrapper-level Spanner preserved-markup bag cannot retain only the "
            + "unconsumed part of that payload. MSCXDecoder+Spanner.swift plus "
            + "slur_ms4_glissando_legato.mscx, testSingleNoteDynamics.mscx, and repeat52.mscx "
            + "pin the loss; a payload-level bag or model field would be required."
    private static let glissandoAnchorReason =
        "by design, and not user-data loss: <anchor>3</anchor> is the fixed note-anchor marker "
            + "inside the modeled Glissando payload. MSCXDecoder+Note.swift derives the anchor "
            + "from Note containment and MSCXEncoder+Note.swift writes the spanner there; the "
            + "nested source tag cannot ride in the wrapper-level bag. "
            + "slur_ms4_glissando_legato.mscx pins this spelling."
    private static func makeAllowedLosses() -> [String: String] {
        var result: [String: String] = [:]
        addPermanentLosses(to: &result)
        return result
    }

    private static func allow(
        _ pairs: [String], because reason: String,
        into result: inout [String: String],
    ) {
        for pair in pairs {
            precondition(result.updateValue(reason, forKey: pair) == nil, "duplicate allowed loss: \(pair)")
        }
    }

    private static func addPermanentLosses(to result: inout [String: String]) {
        // Permanent: identity and generated file metadata.
        allow([
            "Accidental/eid", "BarLine/eid", "Chord/eid", "Clef/eid", "Dynamic/eid",
            "GuitarBend/eid", "GuitarBendHold/eid", "HBox/eid", "KeySig/eid",
            "LayoutBreak/eid", "Lyrics/eid", "Marker/eid", "Measure/eid", "Note/eid", "Rest/eid",
            "Score/eid", "Staff/eid", "StaffText/eid", "Symbol/eid", "SystemText/eid", "Tempo/eid",
            "Text/eid", "Tie/eid", "TimeSig/eid", "VBox/eid", "museScore/LastEID",
        ], because: elementIdentityReason, into: &result)
        // `LaissezVib/eid` is deliberately NOT here. `<LaissezVib>` is
        // itself preserved whole, and the exclusion list only fires at
        // a CAPTURE point — an id nested inside a verbatim subtree
        // rides along with the element it identifies, which keeps that
        // subtree internally consistent. The exclusion exists for ids
        // on elements the model represents, where an edit could strand
        // them.
        allow([
            "Glissando/linked", "Glissando/linkedMain", "Slur/linked", "Slur/linkedMain",
        ], because: linkedIdentityReason, into: &result)
        allow([
            "museScore/programRevision", "museScore/programVersion",
        ], because: "by design: the encoder writes its own program identity for the format it emits.", into: &result)

        // Permanent: canonical structural and spelling changes.
        allow([
            "Measure/Chord", "Measure/KeySig", "Measure/TimeSig",
        ], because: flatFormReason, into: &result)
        allow([
            "Style/Spatium",
        ], because: spatiumReason, into: &result)
        allow([
            "Note/Spanner", "Spanner/prev", "location/fractions", "location/measures",
            "next/location", "prev/location",
        ], because: endpointReason, into: &result)
        allow([
            "location/voices",
        ], because: crossVoiceEndpointReason, into: &result)

        // Permanent: parser policy and markup explicitly outside this design.
        allow([
            "Chord/TremoloSingleChord", "TremoloSingleChord/subtype",
        ], because: tremoloReason, into: &result)
        // `Text/style` used to sit here too. The only fixture that lost it was
        // a `<TBox>`, whose whole subtree is now carried as preserved markup —
        // so it comes back, and the entry would be stale.
        allow([
            "b/font", "text/b", "text/font",
        ], because: legacyTempoTextReason, into: &result)
        allow([
            "Instrument/instrumentId",
        ], because: soundIDReason, into: &result)
        allow([
            "voice/KeySig",
        ], because: staffHeadCMajorReason, into: &result)
        allow([
            "Instrument/InstrumentLabel", "InstrumentLabel/longName", "InstrumentLabel/shortName",
        ], because: instrumentLabelReason, into: &result)
        allow([
            "Staff/defaultConcertClef", "Staff/defaultTransposingClef",
        ], because: defaultClefDialectReason, into: &result)
        addLeafPermanentLosses(to: &result)
    }

    private static func addLeafPermanentLosses(to result: inout [String: String]) {
        allow([
            "KeySig/accidental", "KeySig/concertKey", "KeySig/mode",
        ], because: keySignatureDialectReason, into: &result)
        allow([
            "Harmony/name",
        ], because: harmonyStructureReason, into: &result)
        allow([
            "TimeSig/showCourtesySig",
        ], because: defaultCourtesyReason, into: &result)
        allow([
            "Note/Symbol", "Symbol/name",
        ], because: noteParenthesisSymbolReason, into: &result)
        allow([
            "Glissando/diagonal", "HairPin/Segment", "Segment/off2", "Segment/offset",
            "Segment/subtype", "Volta/endHookType",
        ], because: spannerPayloadReason, into: &result)
        allow([
            "Glissando/anchor",
        ], because: glissandoAnchorReason, into: &result)
    }

    private static func counts(_ root: XMLTreeNode) -> [String: Int] {
        var result: [String: Int] = [:]
        func walk(_ node: XMLTreeNode, parent: String) {
            result["\(parent)/\(node.name)", default: 0] += 1
            for child in node.children {
                walk(child, parent: node.name)
            }
        }
        walk(root, parent: "")
        return result
    }
}

@Suite("MSCX preservation")
struct MSCXPreservationGateTests {
    @Test("committed fixtures lose nothing outside the allowlist")
    func fixturesPreserveMarkup() throws {
        for url in MSCXFixtureLoader.allMSCXURLs() {
            let source = try Data(contentsOf: url)
            guard let score = try? MSCXParser.parse(source) else { continue }
            let encoded = try MSCXEncoder.encode(score)
            let losses = try MSCXPreservation.losses(source: source, encoded: encoded)
            for (pair, count) in losses.sorted(by: { $0.key < $1.key })
                where MSCXPreservation.allowedLosses[pair] == nil
            {
                let message = "\(url.lastPathComponent): lost \(pair) x\(count) — "
                    + "model it, preserve it, or add it to allowedLosses with a reason"
                Issue.record(Comment(rawValue: message))
            }
        }
    }

    @Test("the allowlist has no entry that no fixture exercises")
    func allowlistHasNoDeadEntries() throws {
        var seen: Set<String> = []
        for url in MSCXFixtureLoader.allMSCXURLs() {
            let source = try Data(contentsOf: url)
            guard let score = try? MSCXParser.parse(source),
                  let encoded = try? MSCXEncoder.encode(score)
            else { continue }
            try seen.formUnion(MSCXPreservation.losses(source: source, encoded: encoded).keys)
        }
        for pair in MSCXPreservation.allowedLosses.keys where !seen.contains(pair) {
            Issue.record("allowedLosses[\(pair)] is stale — no fixture loses it any more; delete it")
        }
        for (pair, reason) in MSCXPreservation.allowedLosses {
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if normalized.isEmpty || normalized.contains("TODO") || normalized.contains("TBD") {
                Issue.record("allowedLosses[\(pair)] needs a complete, non-placeholder reason")
            }
        }
    }
}

/// The opt-in corpus layer: the same source-to-pass-1 comparison over every `.mscx` under the directory named
/// by `SM_MSCX_PRESERVATION_DIR`, recursively. Disabled — not failed, not skipped-with-a-warning — when the
/// variable is unset, following `MSCXIdempotencySweep` exactly.
///
///     SM_MSCX_PRESERVATION_DIR=~/path/to/scores swift test --filter MSCXPreservationSweep
///
/// A file that will not decode is reported and skipped rather than failed: a corpus of real scores contains
/// MuseScore versions this reader does not claim to open, and a gate that fails on them says nothing about
/// preservation. A file that decodes but whose encode throws is counted separately as `failed` and makes the
/// sweep fail. The run prints all counts because "no failure was reported" and "it measured every score" are
/// different facts.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SM_MSCX_PRESERVATION_DIR"] != nil))
struct MSCXPreservationSweep {
    @Test("every score in the corpus loses nothing outside the allowlist")
    func corpusPreservesMarkup() throws {
        let raw = try #require(ProcessInfo.processInfo.environment["SM_MSCX_PRESERVATION_DIR"])
        let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        let files = Self.scoreFiles(under: root)
        #expect(!files.isEmpty, "no .mscx found under \(root.path)")

        var loaded = 0
        var unreadable: [String] = []
        var failed: [String] = []
        var lossy: [String] = []
        for file in files {
            guard let source = try? Data(contentsOf: file),
                  let score = try? MSCXParser.parse(source)
            else {
                unreadable.append(file.lastPathComponent)
                continue
            }
            loaded += 1
            do {
                let encoded = try MSCXEncoder.encode(score)
                let losses = try MSCXPreservation.losses(source: source, encoded: encoded)
                    .filter { MSCXPreservation.allowedLosses[$0.key] == nil }
                guard !losses.isEmpty else { continue }
                let details = losses.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key) x\($0.value)" }
                    .joined(separator: ", ")
                lossy.append("\(file.lastPathComponent): \(details)")
            } catch {
                failed.append("\(file.lastPathComponent): \(error)")
            }
        }

        print("[mscx-preservation] files=\(files.count) loaded=\(loaded) "
            + "unreadable=\(unreadable.count) failed=\(failed.count) lossy=\(lossy.count)")
        for name in unreadable.prefix(20) {
            print("[mscx-preservation][unreadable] \(name)")
        }
        for line in failed.prefix(20) {
            print("[mscx-preservation][failed] \(line)")
        }
        for line in lossy.prefix(20) {
            print("[mscx-preservation][lossy] \(line)")
        }
        #expect(failed.isEmpty, "\(failed.count) of \(loaded) scores decoded but threw on re-encode")
        #expect(lossy.isEmpty, "\(lossy.count) of \(loaded) scores lost markup outside the allowlist")
    }

    private static func scoreFiles(under root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        )
        let found = (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.pathExtension.lowercased() == "mscx"
        }
        return found.sorted { $0.path < $1.path }
    }
}
