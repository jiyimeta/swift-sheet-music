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
        "by design: MuseScore linked-element bookkeeping is recomputed from the score link structure, "
            + "like eid identity (spec §3.4)."
    private static let flatFormReason =
        "by design: the MS2/MS3 flat form moves under <voice> in the encoder's canonical structure."
    private static let spatiumReason =
        "by design: the v4 encoder writes lowercase <spatium>; the decoded value round-trips."
    private static let endpointReason =
        "by design: spanner endpoint markers are recomputed from modeled offsets; "
            + "the <prev> side carries no model state (MSCXDecoder+Chord.swift)."
    private static let tremoloReason =
        "by design: unsupported tremolo embellishments are dropped after a diagnostic under the parser policy."
    private static let textContentReason =
        "by design: text style and inline markup remain for the TextContent parity work "
            + "(spec §6; parity doc §7.1)."
    private static let staffBodyBoxReason =
        "by design: top-level staff body boxes and their ordering are outside this spec (spec §3.5)."
    private static let soundIDReason =
        "genuinely lost, and not fixable by preserving it: MuseScore's <Instrument id> attribute "
            + "(template id) and <instrumentId> element (MusicXML Sound ID) hold different values, "
            + "this decoder collapses them, and the encoder synthesizes the element for a drumset — "
            + "so preserving it would make a programmatic drumset score stop comparing equal to "
            + "itself across a round trip. Recovering the Sound ID needs Instrument to model it."
    private static let instrumentLabelReason =
        "by design: MuseScore 5's <InstrumentLabel> wrapper holds <longName> / <shortName>, which "
            + "are modeled and re-emitted in MuseScore 4's direct-child form. Preserving the "
            + "wrapper too would duplicate modeled data and go stale on the first rename."
    private static func makeAllowedLosses() -> [String: String] {
        var result: [String: String] = [:]
        addPermanentLosses(to: &result)
        addTask5Losses(to: &result)
        addTask6Losses(to: &result)
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
            "GuitarBend/eid", "GuitarBendHold/eid", "HBox/eid", "KeySig/eid", "LaissezVib/eid",
            "LayoutBreak/eid", "Lyrics/eid", "Marker/eid", "Measure/eid", "Note/eid", "Rest/eid",
            "Score/eid", "Staff/eid", "StaffText/eid", "Symbol/eid", "SystemText/eid", "Tempo/eid",
            "Text/eid", "Tie/eid", "TimeSig/eid", "VBox/eid", "museScore/LastEID",
        ], because: elementIdentityReason, into: &result)
        allow([
            "BarLine/linked", "BarLine/linkedMain", "Chord/linked", "Chord/linkedMain",
            "Glissando/linked", "Glissando/linkedMain", "Note/linked", "Note/linkedMain",
            "Rest/linked", "Rest/linkedMain", "Slur/linked", "Slur/linkedMain",
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
            "location/measures", "prev/location",
        ], because: endpointReason, into: &result)

        // Permanent: parser policy and markup explicitly outside this design.
        allow([
            "Chord/TremoloSingleChord", "TremoloSingleChord/subtype",
        ], because: tremoloReason, into: &result)
        allow([
            "Text/style", "b/font", "text/b", "text/font", "text/sym",
        ], because: textContentReason, into: &result)
        allow([
            "HBox/width", "Staff/HBox", "Staff/TBox", "TBox/Text", "TBox/bottomGap",
            "TBox/bottomMargin", "TBox/height", "TBox/leftMargin", "TBox/rightMargin", "TBox/topGap",
            "TBox/topMargin", "Text/text", "VBox/bottomGap",
        ], because: staffBodyBoxReason, into: &result)
        allow([
            "Instrument/instrumentId",
        ], because: soundIDReason, into: &result)
        allow([
            "Instrument/InstrumentLabel", "InstrumentLabel/longName", "InstrumentLabel/shortName",
        ], because: instrumentLabelReason, into: &result)
    }

    private static func addTask5Losses(to result: inout [String: String]) {
        // Temporary: Task 5 preserves Measure bags and the ordered voice stream.
        allow([
            "Beam/l1", "Beam/l2", "LayoutBreak/subtype", "Measure/LayoutBreak", "voice/Beam",
            "voice/KeySig",
        ], because: "Task 5: preserve unmodeled Measure and position-sensitive voice markup.", into: &result)
    }

    private static func addTask6Losses(to result: inout [String: String]) {
        // Temporary: Task 6 preserves chord, note, notation-leaf, and spanner containers.
        allow([
            "Arpeggio/subtype", "Arpeggio/timeStretch", "Arpeggio/userLen1", "BarLine/span",
            "Chord/Arpeggio", "Chord/BeamMode", "Chord/StemDirection", "Chord/noStem", "Clef/isHeader",
            "Dynamic/veloChange", "Dynamic/veloChangeSpeed", "Event/len", "Events/Event",
            "Glissando/anchor", "Glissando/diagonal", "HairPin/Segment", "Harmony/name", "Jump/style",
            "KeySig/accidental", "KeySig/concertKey", "KeySig/mode", "Lyrics/ticks_f", "Marker/style",
            "Note/Events", "Note/LaissezVib", "Note/Spanner", "Note/Symbol", "Segment/off2",
            "Segment/offset", "Segment/subtype", "Spanner/prev", "Symbol/name", "TimeSig/showCourtesySig",
            "Volta/endHookType", "location/fractions", "location/voices", "next/location",
        ], because: "Task 6: preserve unmodeled chord, note, notation-leaf, and spanner markup.", into: &result)
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
