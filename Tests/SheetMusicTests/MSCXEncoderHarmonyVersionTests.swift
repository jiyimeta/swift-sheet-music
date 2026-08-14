import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// The chord-symbol layout inside `<Harmony>` differs between the MSCX
/// generations we target, and getting it wrong is silent: MuseScore
/// skips a `Harmony` whose content it could not read, so the symbols
/// simply are not in the file the user opens.
@Suite("MSCXEncoder harmony layout per version")
struct MSCXEncoderHarmonyVersionTests {
    private func encodedXML(
        _ harmony: Harmony, targetVersion: MSCXVersion,
    ) throws -> String {
        let voice = Voice(elements: [.harmony(harmony)])
        let xml = try voice.encode(
            options: MSCXEncoderOptions(targetVersion: targetVersion),
        )
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [xml]),
        )
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func roundTrip(
        _ harmony: Harmony, targetVersion: MSCXVersion,
    ) throws -> Voice {
        let voice = Voice(elements: [.harmony(harmony)])
        let xml = try voice.encode(
            options: MSCXEncoderOptions(targetVersion: targetVersion),
        )
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [xml]),
        )
        let reparsed = try XMLTreeParser.parse(bytes)
        return try Voice.decode(#require(reparsed.first("voice")))
    }

    /// MuseScore 4.6 moved the chord-symbol content into a
    /// `<harmonyInfo>` wrapper and renamed `<base>` to `<bass>`
    /// (`rw/read460/tread.cpp:2957-2986`). We declare `version="4.60"`,
    /// so MuseScore reads our file with read460 — which does not know
    /// `<name>` / `<root>` / `<base>` as direct children of
    /// `<Harmony>` and drops them. The resulting `Harmony` has no
    /// `HarmonyInfo` at all, so `TWrite::write` skips it and EVERY
    /// chord symbol disappears from an exported score. Measured with
    /// MuseScore 4.7.4: 0 of 4 harmonies survived the flat form,
    /// 4 of 4 survived the wrapped form.
    @Test("v4 export uses harmonyInfo and the bass spelling")
    func v4UsesHarmonyInfoWrapper() throws {
        let xml = try encodedXML(
            Harmony(name: "m7", rootTpc: 13, bassTpc: 12, bassCase: .lower),
            targetVersion: .v4,
        )
        #expect(xml.contains("<harmonyInfo>"))
        #expect(xml.contains("<bass>12</bass>"))
        #expect(xml.contains("<bassCase>"))
        // The historical spellings must be gone, or read460 drops them.
        #expect(!xml.contains("<base>"))
        #expect(!xml.contains("<baseCase>"))
        // `<name>` / `<root>` belong INSIDE the wrapper; `<rootCase>` /
        // `<bassCase>` stay direct children of `<Harmony>`.
        let info = try #require(xml.range(of: "<harmonyInfo>"))
        let infoEnd = try #require(xml.range(of: "</harmonyInfo>"))
        let inner = xml[info.upperBound ..< infoEnd.lowerBound]
        #expect(inner.contains("<name>m7</name>"))
        #expect(inner.contains("<root>13</root>"))
        #expect(!inner.contains("<bassCase>"))
    }

    /// MuseScore 3 (and every reader before 4.6) expects the flat
    /// layout, so the v3 target must NOT gain the wrapper.
    @Test("v3 export keeps the flat legacy layout")
    func v3KeepsFlatLayout() throws {
        let xml = try encodedXML(
            Harmony(name: "m7", rootTpc: 13, bassTpc: 12, bassCase: .lower),
            targetVersion: .v3,
        )
        #expect(!xml.contains("<harmonyInfo>"))
        #expect(xml.contains("<base>12</base>"))
        #expect(xml.contains("<baseCase>"))
    }

    @Test("harmony round-trips through both export layouts")
    func roundTripsInBothLayouts() throws {
        let harmony = Harmony(
            name: "m7", rootTpc: 13, rootCase: .upper,
            bassTpc: 12, bassCase: .lower,
        )
        for version in [MSCXVersion.v3, .v4] {
            let decoded = try roundTrip(harmony, targetVersion: version)
            #expect(
                decoded == Voice(elements: [.harmony(harmony)]),
                "target \(version) failed",
            )
        }
    }
}
