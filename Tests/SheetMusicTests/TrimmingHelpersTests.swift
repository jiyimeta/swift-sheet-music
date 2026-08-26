import Foundation
@testable import SheetMusicFoundation
import Testing

/// `SheetMusicFoundation` reimplements the three `trimmingCharacters(in:)`
/// sets this package uses, because `CharacterSet` is not part of
/// `FoundationEssentials`. Every MSCX and MusicXML decoder that normalizes an
/// element's text runs through them, so a divergence would move parsed values
/// rather than fail loudly.
///
/// Foundation is the oracle, so the differential half is Apple-only.
@Suite("Trimming helpers match CharacterSet trimming")
struct TrimmingHelpersTests {
    /// One representative from every category the sets are defined by, plus the
    /// boundary cases that a hand-written range list tends to miss.
    private static let probes: [String] = [
        "", " ", "  ", "x", " x ", "\tx\t", "\nx\n", "\r\nx\r\n",
        "x y", "  x  y  ",
        // Zs beyond U+0020: NBSP, Ogham space, en/em quad, thin space, narrow
        // NBSP, medium mathematical space, ideographic space.
        "\u{00A0}x\u{00A0}", "\u{1680}x\u{1680}", "\u{2000}x\u{2000}",
        "\u{2009}x\u{2009}", "\u{202F}x\u{202F}", "\u{205F}x\u{205F}",
        "\u{3000}x\u{3000}",
        // Zl / Zp.
        "\u{2028}x\u{2028}", "\u{2029}x\u{2029}",
        // NEL, vertical tab, form feed.
        "\u{0085}x\u{0085}", "\u{000B}x\u{000B}", "\u{000C}x\u{000C}",
        // Cc and Cf: NUL, unit separator, DEL, C1, soft hyphen, ZWSP, ZWNJ,
        // LRM, LRE, word joiner, BOM.
        "\u{0000}x\u{0000}", "\u{001F}x\u{001F}", "\u{007F}x\u{007F}",
        "\u{0080}x\u{0080}", "\u{00AD}x\u{00AD}", "\u{200B}x\u{200B}",
        "\u{200C}x\u{200C}", "\u{200E}x\u{200E}", "\u{202A}x\u{202A}",
        "\u{2060}x\u{2060}", "\u{FEFF}x\u{FEFF}",
        // Mixed runs, and content that must survive untouched.
        " \t\n x \n\t ", "\u{3000}\u{00A0} ピアノ \u{00A0}\u{3000}",
        "ピアノ — Étude", "0", "-1.27", "hcenter,vcenter",
        // A space followed by a combining mark: one grapheme, so a
        // Character-based trim would disagree with a scalar-based one.
        "\u{0020}\u{0301}x",
        // Only-trimmable input must collapse to empty.
        " \t\n\u{3000}\u{00A0}",
    ]

    #if canImport(Darwin)
        @Test("trimmingHorizontalWhitespace matches .whitespaces")
        func horizontalWhitespace() {
            for probe in Self.probes {
                let expected = probe.trimmingCharacters(in: .whitespaces)
                #expect(
                    probe.trimmingHorizontalWhitespace() == expected,
                    "input \(probe.debugDescription)",
                )
            }
        }

        @Test("trimmingWhitespaceAndNewlines matches .whitespacesAndNewlines")
        func whitespaceAndNewlines() {
            for probe in Self.probes {
                let expected = probe.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(
                    probe.trimmingWhitespaceAndNewlines() == expected,
                    "input \(probe.debugDescription)",
                )
            }
        }

        @Test("trimmingControlCharacters matches .controlCharacters")
        func controlCharacters() {
            for probe in Self.probes {
                let expected = probe.trimmingCharacters(in: .controlCharacters)
                #expect(
                    probe.trimmingControlCharacters() == expected,
                    "input \(probe.debugDescription)",
                )
            }
        }

        /// Sweep every scalar the sets could plausibly contain, so the category
        /// lookup is checked rather than just the handful sampled above.
        @Test("scalar sweep matches CharacterSet membership")
        func scalarSweep() {
            for value in 0 ... 0xFFFF {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let probe = "\(Character(scalar))x\(Character(scalar))"
                #expect(
                    probe.trimmingHorizontalWhitespace()
                        == probe.trimmingCharacters(in: .whitespaces),
                    "whitespaces at U+\(String(value, radix: 16, uppercase: true))",
                )
                #expect(
                    probe.trimmingWhitespaceAndNewlines()
                        == probe.trimmingCharacters(in: .whitespacesAndNewlines),
                    "whitespacesAndNewlines at U+\(String(value, radix: 16, uppercase: true))",
                )
                #expect(
                    probe.trimmingControlCharacters()
                        == probe.trimmingCharacters(in: .controlCharacters),
                    "controlCharacters at U+\(String(value, radix: 16, uppercase: true))",
                )
            }
        }
    #endif

    /// Behaviour pinned without the oracle, so the helpers stay meaningful on
    /// platforms where `CharacterSet` does not exist.
    @Test("trims only at the ends, at scalar level")
    func interiorIsPreserved() {
        #expect("  a  b  ".trimmingHorizontalWhitespace() == "a  b")
        #expect("\n a \n b \n".trimmingWhitespaceAndNewlines() == "a \n b")
        #expect("\u{3000}語\u{3000}句\u{3000}".trimmingHorizontalWhitespace() == "語\u{3000}句")
        // Tabs are horizontal whitespace; newlines are not.
        #expect("\t x \n".trimmingHorizontalWhitespace() == "x \n")
        #expect("".trimmingWhitespaceAndNewlines().isEmpty)
    }
}
