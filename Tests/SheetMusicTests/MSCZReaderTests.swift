import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicZip
import Testing

struct MSCZReaderTests {
    @Test func parseMatchesDirectMSCX() throws {
        let mscz = try #require(
            TestResources.url(forResource: "midi01", withExtension: "mscz"),
        )
        let mscx = try #require(
            TestResources.url(forResource: "midi01", withExtension: "mscx"),
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
        let empty = try buildArchiveData(entries: [])
        do {
            _ = try MSCZReader.parse(empty)
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case let .corruptedContainer(fault) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(fault.code == "mscz.noMainEntry")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func parseContentsOfURLMatchesDataOverload() throws {
        let url = try #require(
            TestResources.url(forResource: "midi01", withExtension: "mscz"),
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
        let mscxBytes = Data(mscx.utf8)
        var entries: [(path: String, data: Data)] = [
            ("score.mscx", mscxBytes),
        ]
        if let audioSettings {
            entries.append(("audiosettings.json", Data(audioSettings.utf8)))
        }
        return try buildArchiveData(entries: entries)
    }

    // MARK: - Pictures

    private static let pngName = "c30a2fc8801ac2ae196a1d9580695545.png"
    private static let jpgName = "099d26f8691e3a8bb734f122687d7220.jpg"

    @Test func parseLoadsTheReferencedPictures() throws {
        let score = try MSCZReader.parse(MSCXFixtureLoader.msczData("frames-pictures"))
        #expect(score.pictures.count == 2)
        let png = try #require(score.pictures[Self.pngName])
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(score.pictures[Self.jpgName] != nil)
    }

    @Test func mscxAloneHasNoPictures() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("frames-pictures"))
        #expect(score.pictures.isEmpty)
    }

    @Test func missingPictureIsADiagnostic() throws {
        let original = try MSCXFixtureLoader.msczData("frames-pictures")
        let trimmed = try archive(dropping: "Pictures/\(Self.pngName)", from: original)
        let result = try MSCZReader.parseWithDiagnostics(trimmed)

        let missing = result.diagnostics.filter { $0.code == "mscz.picture.missing" }
        #expect(missing.count == 1)
        #expect(missing.first?.severity == .warning)
        #expect(missing.first?.location == Self.pngName)
        #expect(result.score.pictures.count == 1)

        // The `<Image>` is preserved even though its bytes are gone.
        let text = try #require(String(data: MSCXEncoder.encode(result.score), encoding: .utf8))
        #expect(text.contains("<Image>"))
        #expect(text.contains(Self.pngName))
    }

    private func archive(dropping dropped: String, from data: Data) throws -> Data {
        let reader = try ZipReader(data: data)
        let ordered = reader.entries.values
            .sorted { ($0.payloadRange?.lowerBound ?? 0) < ($1.payloadRange?.lowerBound ?? 0) }
        var writer = ZipWriter()
        for entry in ordered where entry.path != dropped {
            try writer.add(path: entry.path, data: reader.read(entry), method: .deflate)
        }
        return writer.finish()
    }

    @Test func fallbackFileNameRenamedMainEntry() throws {
        // Zip only contains "renamed.mscx" at root — the rule-2 fallback
        // in MSCZReader should still locate it.
        let mscx = try #require(
            TestResources.url(forResource: "midi01", withExtension: "mscx"),
        )
        let mscxBytes = try Data(contentsOf: mscx)
        let msczBytes = try buildArchiveData(entries: [("renamed.mscx", mscxBytes)])
        let score = try MSCZReader.parse(msczBytes)
        #expect(score.division == 480)
    }

    private func buildArchiveData(
        entries: [(path: String, data: Data)],
    ) throws -> Data {
        var writer = ZipWriter()
        for entry in entries {
            try writer.add(path: entry.path, data: entry.data, method: .deflate)
        }
        return writer.finish()
    }
}
