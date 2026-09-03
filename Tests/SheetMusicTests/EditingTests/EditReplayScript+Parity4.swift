@testable import SheetMusicCore

extension EditReplayScript {
    /// The harmony group's four steps — the tail of `parity(staff:)`, which appends them to its own list after the
    /// spanner group's, and the last steps this chain will ever have. They live in a sibling file for the reason
    /// `parityVisibility()` and `paritySpanners(staff:)` do, and every step number below is the CHAIN's (89…92),
    /// not this array's.
    ///
    /// The group is one intent (73: `setChordSymbol`), so it is spelled the only way a single intent can pin its
    /// whole payload: written (89), retyped as a roman numeral (90) — the replace-in-place path, and the only step
    /// in either chain encoding a harmony type other than 0 — cleared (91), and written once more (92) so the
    /// chain ends on a symbol that stands.
    ///
    /// ## Index stability
    ///
    /// - **Bar 3 of the FLUTE (steps 89…92)** is NOT the bare measure rest the fixture put there. Step 84's volta
    ///   is measure-granular and writes on the canonical staff — which is the flute — at index 0, and steps 85 /
    ///   86 undo and re-apply it, so it is still standing when this group arrives: the bar reads
    ///   `[volta, r measure]` and the rest is element 1, not 0. (`bar3Rest` in `parity(staff:)` names element 0
    ///   because step 27, its only other user, runs fifty-seven steps before the volta exists.) From there each
    ///   step names the index the step before it left: 89 inserts the symbol at the rest's own index — an
    ///   insertion lands nearest the timed element, so it goes AFTER the volta, not ahead of it — and the rest
    ///   becomes element 2; 90 names element 2 and finds the symbol in its run, replacing it in place, so nothing
    ///   shifts; 91 names element 2 again and removes the symbol, putting the rest back at element 1; 92 names
    ///   element 1 and inserts once more. The volta sits at index 0 throughout and is never addressed.
    ///
    /// A chord symbol over a REST is deliberate rather than a convenience: MuseScore parents one on any
    /// chord-rest's segment, and a lead sheet's symbols over rests are its ordinary shape. Bar 3's rest is also
    /// the one slot no earlier step of the chain addresses by index, which is what makes the arithmetic above
    /// local to these four steps.
    ///
    /// ## Fingerprints that repeat
    ///
    /// One of the four: step 91 removes the symbol steps 89 / 90 wrote and lands back on step 88's value. The
    /// other three are new — `ScoreFingerprintHasher.combine(_ harmony:)` hashes `name`, `harmonyType`,
    /// `rootTpc` and `bassTpc`, so both a different name (89, 92) and a different type on the same name (90) move
    /// it. Step 92 does not repeat: nothing takes its `C` back, so the chain still ends on a value no earlier
    /// step produced, which is what `EditReplayDeterminismTests.scriptIsNotInert` reads.
    static func parityHarmony(staff: StaffAddress) -> [EditReplayStep] {
        // The measure rest of bar 3 with step 84's volta standing ahead of it, and the same rest once step 89 has
        // put a symbol in between. Bound rather than spelled inline so the two indices cannot drift apart.
        let bar3RestBehindVolta = VoiceElementID(staff: staff, measureIndex: 3, voiceIndex: 0, elementIndex: 1)
        let bar3RestBehindSymbol = VoiceElementID(staff: staff, measureIndex: 3, voiceIndex: 0, elementIndex: 2)

        return [
            // Step 89: `Am7` before bar 3's measure rest — the harmony group's first write, and the first chord
            // symbol in either chain. The rest becomes element 2.
            .intent(.setChordSymbol(at: bar3RestBehindVolta, name: "Am7", harmonyType: .standard)),
            // Step 90: `bVII` on the same rest, now element 2 — the symbol in its run is replaced in place, and
            // this is the only step encoding a harmony type other than 0.
            .intent(.setChordSymbol(at: bar3RestBehindSymbol, name: "bVII", harmonyType: .roman)),
            // Step 91: and cleared — lands back on step 88's fingerprint. `harmonyType` is `.standard` on a
            // removal: the wire zeroes it when `hasName == 0`, so any other value here would describe bytes the
            // codec cannot produce.
            .intent(.setChordSymbol(at: bar3RestBehindSymbol, name: nil, harmonyType: .standard)),
            // Step 92: `C` back on the rest (element 1 again) — the chain ends on a symbol that stands, so its
            // final fingerprint is new, as `scriptIsNotInert` needs.
            .intent(.setChordSymbol(at: bar3RestBehindVolta, name: "C", harmonyType: .standard)),
        ]
    }
}
