import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// Same ambiguity, same fix, as `LyricsVisibilityTests` — see the note there.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// A word split across a barline keeps its hyphen.
///
/// `placeMeasureElements` keeps its per-verse trail inside a per-measure pass, so until
/// `LayoutEngine+LyricHyphenSpans` the second half of "glo- / ri" got nothing at all — a case real lyrics hit
/// constantly. MuseScore has no trail: a hyphen is a `LyricsLine` spanner segmented per SYSTEM, which is what
/// these tests pin, in the two shapes that differ.
@Suite("LayoutEngine — lyric hyphens across a barline")
struct LyricHyphenAcrossBarlineTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// Bar 1 ends on "glo", bar 2 opens with "ri" and closes the word with "a". The cross-barline pair and a
    /// within-measure pair therefore live in one score, so a test can tell the two emitters apart.
    ///
    /// `openingSyllabic` is the control knob: `.begin` continues the word into bar 2, `.single` ends it
    /// there, and every assertion below is stated as the difference between the two runs.
    private static func score(openingSyllabic: Syllabic = .begin) -> Score {
        func chord(_ pitch: Int, _ lyric: Lyric?) -> VoiceElement {
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: pitch, tpc: 14)]),
                lyrics: lyric.map { [$0] } ?? [],
            ))
        }
        let measure1 = Measure(voices: [Voice(elements: [
            chord(60, nil), chord(62, nil), chord(64, nil),
            chord(65, Lyric(text: "glo", syllabic: openingSyllabic)),
        ])])
        let measure2 = Measure(voices: [Voice(elements: [
            chord(67, Lyric(text: "ri", syllabic: .middle)),
            chord(65, nil), chord(64, nil),
            chord(62, Lyric(text: "a", syllabic: .end)),
        ])])
        let staff = Staff(measures: [measure1, measure2])
        let part = Part(id: "1", instrument: Instrument(id: "voice"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    private struct Dash {
        let systemIndex: Int
        let minX: CGFloat
        let maxX: CGFloat
        var centerX: CGFloat {
            (minX + maxX) / 2
        }
    }

    private struct Syllable {
        let systemIndex: Int
        let text: String
        let centerX: CGFloat
    }

    /// Every hyphen dash in the document, in absolute coordinates, tagged with the system it landed in.
    private static func dashes(in document: LayoutDocument) -> [Dash] {
        var result: [Dash] = []
        for (systemIndex, system) in document.systems.enumerated() {
            for measure in system.measures {
                let base = system.origin.x + measure.origin.x
                for element in measure.elements {
                    guard case let .lyricHyphen(from, to, _) = element else { continue }
                    result.append(Dash(
                        systemIndex: systemIndex,
                        minX: base + min(from.x, to.x),
                        maxX: base + max(from.x, to.x),
                    ))
                }
            }
        }
        return result
    }

    private static func syllables(in document: LayoutDocument) -> [Syllable] {
        var result: [Syllable] = []
        for (systemIndex, system) in document.systems.enumerated() {
            for measure in system.measures {
                let base = system.origin.x + measure.origin.x
                for element in measure.elements {
                    guard case let .textMark(.lyrics(_, _, _, _), text, origin) = element else { continue }
                    result.append(Syllable(
                        systemIndex: systemIndex, text: text, centerX: base + origin.x,
                    ))
                }
            }
        }
        return result
    }

    private static func layout(_ score: Score, width: CGFloat) -> LayoutDocument {
        LayoutEngine.layout(
            score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: width,
        )
    }

    // MARK: - Within one system

    /// The whole point: the gap between the last syllable of a bar and the first of the next carries dashes.
    ///
    /// Stated as a difference against the `.single` run so it cannot pass on the within-measure "ri"—"a"
    /// hyphen, which both runs draw. Both runs are laid out at the same width, so the two syllables sit at the
    /// same x in each and the band examined is identical.
    @Test("A word broken over a barline gets its hyphen")
    func aCrossBarlineWordIsHyphenated() throws {
        let connected = Self.layout(Self.score(openingSyllabic: .begin), width: 900)
        let broken = Self.layout(Self.score(openingSyllabic: .single), width: 900)
        #expect(connected.systems.count == 1, "the fixture must lay out as one system for this test")

        let glo = try #require(Self.syllables(in: connected).first { $0.text == "glo" })
        let ri = try #require(Self.syllables(in: connected).first { $0.text == "ri" })
        func inGap(_ dashes: [Dash]) -> [Dash] {
            dashes.filter { $0.centerX > glo.centerX && $0.centerX < ri.centerX }
        }

        #expect(inGap(Self.dashes(in: broken)).isEmpty)
        #expect(!inGap(Self.dashes(in: connected)).isEmpty)
        // And the within-measure hyphen is untouched by all of this: both runs draw "ri"—"a".
        let a = try #require(Self.syllables(in: connected).first { $0.text == "a" })
        for document in [connected, broken] {
            #expect(Self.dashes(in: document).contains {
                $0.centerX > ri.centerX && $0.centerX < a.centerX
            })
        }
    }

    /// ONE dash across the barline, not one on each side of it.
    ///
    /// This is why the span is computed per system rather than per measure. MuseScore lays a hyphen out as a
    /// single spanner segment over the whole gap (`LyricsLayout::layoutDashes`), and a gap shorter than
    /// `lyricsDashMaxDistance` = 16 sp gets exactly one dash — centred, spanning the barline. Emitting per
    /// measure would produce two, which is a visibly wrong doubled hyphen rather than a missing one.
    @Test("A short cross-barline gap gets one dash, not one per measure")
    func aShortGapGetsASingleDash() throws {
        let document = Self.layout(Self.score(), width: 430)
        // One system, so "the gap" is a barline crossing and not a system break — the width is tight enough
        // to bring the gap under 16 sp, which is what makes the count below a single dash.
        #expect(document.systems.count == 1)
        let glo = try #require(Self.syllables(in: document).first { $0.text == "glo" })
        let ri = try #require(Self.syllables(in: document).first { $0.text == "ri" })
        let gap = Self.dashes(in: document).filter {
            $0.centerX > glo.centerX && $0.centerX < ri.centerX
        }

        // The control: the gap is genuinely under MuseScore's 16 sp dash distance, so one dash is the rule
        // being checked rather than an accident of this width.
        #expect(ri.centerX - glo.centerX < document.metrics.sp * 16)
        #expect(gap.count == 1)
    }

    // MARK: - Across a system break

    /// MuseScore draws BOTH halves at a system break: `lyricsLineEndX` sends a segment that does not end on
    /// this system to `System::endingXForOpenEndedLines()`, and `lyricsLineStartX` starts a segment that did
    /// not begin on it at `System::firstNoteRestSegmentX()`. So the word shows dashes at the end of one
    /// system and again at the start of the next.
    @Test("A word broken over a system break is hyphenated on both systems")
    func aSystemBreakGetsBothHalves() throws {
        // Narrow enough that the two measures wrap onto separate systems.
        let connected = Self.layout(Self.score(openingSyllabic: .begin), width: 260)
        let broken = Self.layout(Self.score(openingSyllabic: .single), width: 260)
        #expect(connected.systems.count == 2, "the fixture must wrap for this test to mean anything")

        let glo = try #require(Self.syllables(in: connected).first { $0.text == "glo" })
        let ri = try #require(Self.syllables(in: connected).first { $0.text == "ri" })
        #expect(glo.systemIndex == 0 && ri.systemIndex == 1, "the break must fall between the two syllables")

        /// Leaving system 0, to the right of "glo".
        func trailing(_ document: LayoutDocument) -> [Dash] {
            Self.dashes(in: document).filter { $0.systemIndex == 0 && $0.centerX > glo.centerX }
        }
        /// Arriving on system 1, to the left of "ri".
        func leading(_ document: LayoutDocument) -> [Dash] {
            Self.dashes(in: document).filter { $0.systemIndex == 1 && $0.centerX < ri.centerX }
        }

        #expect(trailing(broken).isEmpty)
        #expect(leading(broken).isEmpty)
        #expect(!trailing(connected).isEmpty)
        #expect(!leading(connected).isEmpty)
    }

    /// A trail is per verse and per voice, and a `.single` neighbour ends the word — so a hyphen is never
    /// drawn just because two syllables happen to be adjacent across a barline.
    @Test("An unconnected pair across a barline draws nothing")
    func anUnconnectedPairDrawsNothing() throws {
        let document = Self.layout(Self.score(openingSyllabic: .single), width: 900)
        let glo = try #require(Self.syllables(in: document).first { $0.text == "glo" })
        let ri = try #require(Self.syllables(in: document).first { $0.text == "ri" })

        // The control: this document DOES draw hyphens, so an empty gap is the rule and not a dead pass.
        #expect(!Self.dashes(in: document).isEmpty)
        #expect(!Self.dashes(in: document).contains {
            $0.centerX > glo.centerX && $0.centerX < ri.centerX
        })
    }

    /// A dangling `.begin` at the end of the score draws nothing — no trail running off into the margin.
    ///
    /// This state is reachable in a host, not hypothetical: folino's lyric caret commits a `.begin` the
    /// moment the user presses `-`, and leaving without typing the next syllable leaves the score holding one.
    /// The system-edge half of this pass asks the SCORE whether the neighbour outside the system continues
    /// the word, and there is no neighbour here, so nothing is emitted.
    @Test("A dangling begin with no following syllable draws no trail")
    func aDanglingBeginDrawsNothing() {
        func chord(_ pitch: Int, _ lyric: Lyric?) -> VoiceElement {
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: pitch, tpc: 14)]),
                lyrics: lyric.map { [$0] } ?? [],
            ))
        }
        let measure = Measure(voices: [Voice(elements: [
            chord(60, Lyric(text: "glo", syllabic: .begin)),
            chord(62, nil), chord(64, nil), chord(65, nil),
        ])])
        let staff = Staff(measures: [measure])
        let part = Part(id: "1", instrument: Instrument(id: "voice"), staves: [staff])
        let dangling = Score(division: 480, parts: [part])

        // The control: the same engine, same width, DOES draw a trail when a following syllable exists.
        #expect(!Self.dashes(in: Self.layout(Self.score(), width: 900)).isEmpty)
        #expect(Self.dashes(in: Self.layout(dangling, width: 900)).isEmpty)
    }
}
