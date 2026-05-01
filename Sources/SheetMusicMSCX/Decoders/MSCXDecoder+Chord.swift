import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Chord {
    static func decode(_ node: XMLTreeNode) throws -> Chord {
        guard
            let durationText = node.first("durationType")?.text,
            let baseDuration = NoteDuration(mscxName: durationText)
        else {
            throw SheetMusicError.malformedScore(reason: "Chord missing/invalid <durationType>")
        }
        let dots = Int(node.first("dots")?.text ?? "0") ?? 0
        let duration = baseDuration.dotted(dots)
        let notes = try node.all("Note").map { try Note.decode($0) }

        var arpeggio: Arpeggio?
        if let arpeggioNode = node.first("Arpeggio") {
            let subtype = Int(arpeggioNode.first("subtype")?.text ?? "0") ?? 0
            let stretch = Double(arpeggioNode.first("timeStretch")?.text ?? "1") ?? 1.0
            let userLen = Double(arpeggioNode.first("userLen1")?.text ?? "0") ?? 0.0
            arpeggio = Arpeggio(subtype: subtype, timeStretch: stretch, userLen1: userLen)
        }

        // <Lyrics><text>syllable</text></Lyrics> — one per verse line.
        // Verse number comes from <no> (0-indexed); absent = verse 0.
        // <syllabic> places the syllable in a hyphenated word;
        // <ticks> sizes melismas.
        var lyricsMap: [Int: Lyric] = [:]
        for lyricsNode in node.all("Lyrics") {
            let verse = Int(lyricsNode.first("no")?.text ?? "0") ?? 0
            let text = lyricsNode.first("text")?.text ?? ""
            let syllabic = (lyricsNode.first("syllabic")?.text)
                .flatMap(Syllabic.init(mscxValue:)) ?? .single
            let ticks = Int(lyricsNode.first("ticks")?.text ?? "0") ?? 0
            lyricsMap[verse] = Lyric(
                text: text, syllabic: syllabic, ticks: ticks)
        }
        let maxVerse = lyricsMap.keys.max() ?? -1
        let lyrics: [Lyric] = maxVerse >= 0
            ? (0...maxVerse).map { lyricsMap[$0] ?? Lyric(text: "") }
            : []

        return Chord(
            duration: duration, notes: ChordNotes(notes),
            arpeggio: arpeggio, lyrics: lyrics)
    }
}
