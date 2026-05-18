#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    import Testing
    import ZIPFoundation

    struct MSCZReaderTests {
        @Test func parseMatchesDirectMSCX() throws {
            let mscz = try #require(
                Bundle.module.url(forResource: "midi01", withExtension: "mscz"),
            )
            let mscx = try #require(
                Bundle.module.url(forResource: "midi01", withExtension: "mscx"),
            )
            let msczScore = try MSCZReader.parse(Data(contentsOf: mscz))
            let mscxScore = try MSCXParser.parse(Data(contentsOf: mscx))
            #expect(msczScore == mscxScore)
        }

        @Test func corruptZipThrowsCorruptedContainer() {
            let junk = Data([0x00, 0x01, 0x02, 0x03, 0x04])
            do {
                _ = try MSCZReader.parse(junk)
                Issue.record("expected throw")
            } catch let error as SheetMusicError {
                guard case .corruptedContainer = error else {
                    Issue.record("wrong case: \(error)")
                    return
                }
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        @Test func emptyZipThrowsCorruptedContainer() throws {
            // Build an archive that has no entries at all.
            let archive = try Archive(accessMode: .create)
            let empty = try #require(archive.data)
            do {
                _ = try MSCZReader.parse(empty)
                Issue.record("expected throw")
            } catch let error as SheetMusicError {
                guard case let .corruptedContainer(reason) = error else {
                    Issue.record("wrong case: \(error)")
                    return
                }
                #expect(reason.lowercased().contains("mscx"))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        @Test func parseContentsOfURLMatchesDataOverload() throws {
            let url = try #require(
                Bundle.module.url(forResource: "midi01", withExtension: "mscz"),
            )
            let viaData = try MSCZReader.parse(Data(contentsOf: url))
            let viaURL = try MSCZReader.parse(contentsOf: url)
            #expect(viaData == viaURL)
        }

        @Test func parseContentsOfMissingURLThrowsIOError() {
            let missing = URL(fileURLWithPath: "/tmp/definitely-not-there.mscz")
            do {
                _ = try MSCZReader.parse(contentsOf: missing)
                Issue.record("expected throw")
            } catch let error as SheetMusicError {
                guard case let .ioError(u, _) = error else {
                    Issue.record("wrong case: \(error)")
                    return
                }
                #expect(u == missing)
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        /// MuseScore 4 stores per-part playback presets in
        /// `audiosettings.json` inside the `.mscz`. When the user picks a
        /// non-default SoundFont preset (e.g. "Square Lead" / program 80)
        /// for a part, only `audiosettings.json` is updated — the mscx
        /// keeps its template `<Channel><program>` (e.g. 52 = Choir Aahs
        /// for `voice.soprano`). The reader must apply those preset
        /// overrides so consumers see the sound MuseScore actually plays.
        @Test func audioSettingsOverridesChannelProgram() throws {
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Part id="1">
                  <Instrument id="soprano">
                    <Channel>
                      <program value="52"/>
                    </Channel>
                  </Instrument>
                  <Staff id="1"/>
                </Part>
                <Staff id="1"><Measure></Measure></Staff>
              </Score>
            </museScore>
            """
            let audio = """
            {
              "tracks": [
                { "partId": "1",
                  "in": { "resourceMeta": { "attributes": {
                    "presetBank": "0",
                    "presetProgram": "80",
                    "presetName": "Square Lead"
                  } } }
                }
              ]
            }
            """
            let mscz = try makeMSCZ(mscx: mscx, audioSettings: audio)
            let score = try MSCZReader.parse(mscz)
            #expect(score.parts[0].instrument.channels[0].program == 80)
        }

        /// `audiosettings.json` is optional — older MuseScore 3 files and
        /// hand-rolled archives don't ship one. The reader must still
        /// succeed and leave the mscx-declared program intact.
        @Test func missingAudioSettingsLeavesChannelUnchanged() throws {
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Part id="1">
                  <Instrument id="x">
                    <Channel><program value="52"/></Channel>
                  </Instrument>
                  <Staff id="1"/>
                </Part>
                <Staff id="1"><Measure></Measure></Staff>
              </Score>
            </museScore>
            """
            let mscz = try makeMSCZ(mscx: mscx, audioSettings: nil)
            let score = try MSCZReader.parse(mscz)
            #expect(score.parts[0].instrument.channels[0].program == 52)
        }

        /// MuseScore 4's MS Basic addresses drum kits via
        /// `presetBank=128, presetProgram=N` where N selects a kit variant
        /// ("Standard", "Standard 4", …). That addressing is MS-Basic-
        /// specific: third-party SoundFonts (e.g. `MuseScore_General.sf2`)
        /// don't have a matching preset at SF2 bank LSB 128 / program 4,
        /// so `AVAudioUnitSampler.loadSoundBankInstrument` would silently
        /// fail and the drum staff would be muted. The reader must keep
        /// the mscx-declared channel (typically `<program value="0"/>` =
        /// GM Standard Drum Kit) for drumset parts even when the audio
        /// settings entry has a `presetProgram`.
        @Test func audioSettingsDrumsetOverrideIgnored() throws {
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Part id="6">
                  <Instrument id="drumset">
                    <useDrumset>1</useDrumset>
                    <Channel><program value="0"/></Channel>
                  </Instrument>
                  <Staff id="1"/>
                </Part>
                <Staff id="1"><Measure></Measure></Staff>
              </Score>
            </museScore>
            """
            let audio = """
            {
              "tracks": [
                { "partId": "6",
                  "in": { "resourceMeta": { "attributes": {
                    "presetBank": "128",
                    "presetProgram": "4",
                    "presetName": "Standard 4",
                    "soundFontName": "MS Basic"
                  } } }
                }
              ]
            }
            """
            let mscz = try makeMSCZ(mscx: mscx, audioSettings: audio)
            let score = try MSCZReader.parse(mscz)
            let channel = score.parts[0].instrument.channels[0]
            #expect(score.parts[0].instrument.useDrumset)
            #expect(channel.program == 0)
            #expect(channel.bank == 0)
        }

        /// A track entry without `presetProgram` (typical for the drumset
        /// row in `audiosettings.json` and the auxiliary "999" metronome
        /// track) must not zero out the existing channel program. Only
        /// presets that explicitly nominate a program override.
        @Test func audioSettingsTrackWithoutPresetIgnored() throws {
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Part id="6">
                  <Instrument id="drumset">
                    <useDrumset>1</useDrumset>
                    <Channel><program value="0"/></Channel>
                  </Instrument>
                  <Staff id="1"/>
                </Part>
                <Staff id="1"><Measure></Measure></Staff>
              </Score>
            </museScore>
            """
            let audio = """
            {
              "tracks": [
                { "partId": "6",
                  "in": { "resourceMeta": { "attributes": {
                    "soundFontName": "MS Basic"
                  } } }
                }
              ]
            }
            """
            let mscz = try makeMSCZ(mscx: mscx, audioSettings: audio)
            let score = try MSCZReader.parse(mscz)
            #expect(score.parts[0].instrument.channels[0].program == 0)
            #expect(score.parts[0].instrument.useDrumset)
        }

        /// Build a minimal `.mscz` archive in-memory with the given main
        /// `.mscx` content and, optionally, an `audiosettings.json` at the
        /// archive root.
        private func makeMSCZ(
            mscx: String, audioSettings: String?,
        ) throws -> Data {
            let archive = try Archive(accessMode: .create)
            let mscxBytes = Data(mscx.utf8)
            try archive.addEntry(
                with: "score.mscx", type: .file,
                uncompressedSize: Int64(mscxBytes.count),
                compressionMethod: .deflate,
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, mscxBytes.count)
                return mscxBytes.subdata(in: start ..< end)
            }
            if let audioSettings {
                let bytes = Data(audioSettings.utf8)
                try archive.addEntry(
                    with: "audiosettings.json", type: .file,
                    uncompressedSize: Int64(bytes.count),
                    compressionMethod: .deflate,
                ) { position, size in
                    let start = Int(position)
                    let end = min(start + size, bytes.count)
                    return bytes.subdata(in: start ..< end)
                }
            }
            return try #require(archive.data)
        }

        @Test func fallbackFileNameRenamedMainEntry() throws {
            // Zip only contains "renamed.mscx" at root — the rule-2 fallback
            // in MSCZReader should still locate it.
            let mscx = try #require(
                Bundle.module.url(forResource: "midi01", withExtension: "mscx"),
            )
            let mscxBytes = try Data(contentsOf: mscx)
            let archive = try Archive(accessMode: .create)
            try archive.addEntry(
                with: "renamed.mscx",
                type: .file,
                uncompressedSize: Int64(mscxBytes.count),
                compressionMethod: .deflate,
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, mscxBytes.count)
                return mscxBytes.subdata(in: start ..< end)
            }
            let msczBytes = try #require(archive.data)
            let score = try MSCZReader.parse(msczBytes)
            #expect(score.division == 480)
        }
    }
#endif
