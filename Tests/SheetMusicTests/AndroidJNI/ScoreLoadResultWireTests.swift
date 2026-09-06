#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicLoader
    import Testing

    /// `nativeLoadScore` answers `0` for every failure, so a corrupt ZIP, an unrecognized format and
    /// a structurally invalid `<Measure>` reach an Android host as one indistinguishable answer —
    /// while an Apple host gets a `ScoreFault` whose dotted `code` is a localization key. And because
    /// the parsers are permissive by design, a score that *did* load may have quietly lost an
    /// ornament, which only `parseWithDiagnostics` reports.
    struct ScoreLoadResultWireTests {
        private func fixtureBytes(
            _ name: String, _ ext: String,
        ) throws -> Data {
            let url = try #require(TestResources.url(forResource: name, withExtension: ext))
            return try Data(contentsOf: url)
        }

        private func decode(_ data: Data) throws -> ScoreLoadResultWire {
            try ScoreLoadResultWire(decoding: data)
        }

        @Test
        func successCarriesAHandleAndNoFault() throws {
            let result = try decode(
                nativeLoadScoreWithDiagnostics(bytes: fixtureBytes("midi01", "mscx")),
            )
            defer { scoreTable.release(result.scoreHandle) }
            #expect(result.scoreHandle != 0)
            #expect(result.faultCode.isEmpty)
            #expect(result.faultMessage.isEmpty)
        }

        /// The handle this returns is the same kind of handle `nativeLoadScore` returns — usable by
        /// every other entry point, and the caller's to release. A result that decoded but whose
        /// handle the rest of the bridge did not recognize would be worse than no entry point.
        @Test
        func theHandleIsUsableByTheRestOfTheBridge() throws {
            let result = try decode(
                nativeLoadScoreWithDiagnostics(bytes: fixtureBytes("midi01", "mscx")),
            )
            defer { scoreTable.release(result.scoreHandle) }
            #expect(!nativeScoreMetadata(scoreHandle: result.scoreHandle).isEmpty)
        }

        /// The whole point: a failure names itself. `bridge.scoreFormat.unrecognized` is
        /// `ScoreLoader`'s own code for a payload matching no format, so this pins the code a host
        /// would switch on rather than merely "something non-empty".
        @Test
        func anUnrecognizedPayloadReportsItsFaultCode() throws {
            let result = try decode(
                nativeLoadScoreWithDiagnostics(bytes: Data("not a score at all".utf8)),
            )
            #expect(result.scoreHandle == 0)
            #expect(result.faultCode == "bridge.scoreFormat.unrecognized")
            #expect(!result.faultMessage.isEmpty)
        }

        /// Empty input is its own case rather than falling through to "unrecognized": a host that
        /// handed over zero bytes has a different bug from one that handed over a JPEG.
        @Test
        func emptyInputReportsItsOwnFaultCode() throws {
            let result = try decode(nativeLoadScoreWithDiagnostics(bytes: Data()))
            #expect(result.scoreHandle == 0)
            #expect(result.faultCode == "bridge.scoreFormat.empty")
        }

        /// XML that announces itself as MuseScore and then is not: the fault must come from the MSCX
        /// reader (an `mscx.*` or `xml.*` code), not from the format sniffer, or a host would report
        /// "unrecognized format" for a file whose format was recognized fine.
        @Test
        func aTruncatedMuseScoreDocumentFaultsFromTheParser() throws {
            let result = try decode(
                nativeLoadScoreWithDiagnostics(
                    bytes: Data("<museScore version=\"4.60\"><Score>".utf8),
                ),
            )
            #expect(result.scoreHandle == 0)
            #expect(result.faultCode != "bridge.scoreFormat.unrecognized")
            #expect(!result.faultCode.isEmpty)
        }

        /// Severity numbering is shared with `PdfDiagnosticWire` on purpose — two diagnostic
        /// surfaces reaching one host with opposite numbering is only ever found by a user being
        /// shown a warning as an aside.
        @Test
        func severityMatchesThePdfDiagnosticNumbering() {
            #expect(ScoreDiagnosticWire.severityValue(for: .info) == 0)
            #expect(ScoreDiagnosticWire.severityValue(for: .warning) == 1)
        }

        @Test
        func diagnosticsRoundTripThroughTheWire() throws {
            let wire = ScoreLoadResultWire(
                scoreHandle: 7,
                diagnostics: [
                    ScoreDiagnostic(
                        severity: .warning,
                        code: "mscx.tremolo.unknownSubtype",
                        message: "dropped a tremolo",
                        location: "measure 12, voice 1, Tremolo",
                    ),
                    ScoreDiagnostic(severity: .info, code: "mscx.compat.ms2", message: "MS2 path"),
                ],
            )
            let decoded = try decode(wire.encodeToData())
            #expect(decoded.diagnostics.count == 2)
            #expect(decoded.diagnostics[0].severity == 1)
            #expect(decoded.diagnostics[0].code == "mscx.tremolo.unknownSubtype")
            #expect(decoded.diagnostics[0].location == "measure 12, voice 1, Tremolo")
            // A `nil` location flattens to empty: the wire has no reason to distinguish absent from
            // empty, and a host renders both the same way.
            #expect(decoded.diagnostics[1].location.isEmpty)
        }

        /// Diagnostics are dropped on the failure path rather than partially reported: the parsers
        /// throw from wherever they got to, so whatever accumulated describes a document that never
        /// became a score, and showing "3 warnings" beside a hard failure misleads.
        @Test
        func aFailureCarriesNoDiagnostics() throws {
            let result = try decode(
                nativeLoadScoreWithDiagnostics(bytes: Data("not a score at all".utf8)),
            )
            #expect(result.diagnostics.isEmpty)
        }

        // MARK: - ScoreLoader

        /// `loadScore` is now a projection of `loadScoreWithDiagnostics`, so the two can never
        /// disagree about which parser owns a payload. Pinned across every format the sniffer knows,
        /// because "the diagnostics variant forgot the format someone just added" is precisely the
        /// silent drift `ScoreLoader`'s own doc comment exists to prevent.
        @Test(arguments: [
            ("midi01", "mscx"),
            ("midi01", "mscz"),
            ("glissando-wavy", "musicxml"),
        ])
        func bothLoadersAgreeOnEveryFormat(name: String, ext: String) throws {
            let bytes = try fixtureBytes(name, ext)
            let plain = try ScoreLoader.loadScore(bytes: bytes)
            let withDiagnostics = try ScoreLoader.loadScoreWithDiagnostics(bytes: bytes)
            #expect(plain.stableFingerprint == withDiagnostics.score.stableFingerprint)
        }

        /// MusicXML has no diagnostic channel and the MIDI importer none either, so both answer with
        /// an empty array. Asserted rather than assumed so that wiring one up later has to come here
        /// and say so.
        @Test
        func musicXMLReportsNoDiagnostics() throws {
            let loaded = try ScoreLoader.loadScoreWithDiagnostics(
                bytes: fixtureBytes("glissando-wavy", "musicxml"),
            )
            #expect(loaded.diagnostics.isEmpty)
        }
    }
#endif
