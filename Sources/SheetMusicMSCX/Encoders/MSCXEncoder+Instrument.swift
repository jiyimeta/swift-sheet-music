import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Instrument {
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let longName {
            children.append(XMLTreeNode(name: "longName", text: longName))
        }
        if let shortName {
            children.append(XMLTreeNode(name: "shortName", text: shortName))
        }
        if let trackName {
            children.append(XMLTreeNode(name: "trackName", text: trackName))
        }
        if let v = minPitchPlayable {
            children.append(XMLTreeNode(name: "minPitchP", text: String(v)))
        }
        if let v = maxPitchPlayable {
            children.append(XMLTreeNode(name: "maxPitchP", text: String(v)))
        }
        if let v = minPitchAmateur {
            children.append(XMLTreeNode(name: "minPitchA", text: String(v)))
        }
        if let v = maxPitchAmateur {
            children.append(XMLTreeNode(name: "maxPitchA", text: String(v)))
        }
        if useDrumset {
            // MuseScore Studio looks up the drumset template by the
            // canonical `<instrumentId>` (Sound ID) — without it,
            // every per-pitch `<Drum>` override is ignored and all
            // drums collapse onto the default line. The `id`
            // attribute alone (e.g. "drumset") is not enough.
            children.append(XMLTreeNode(
                name: "instrumentId", text: "drum.group.set"
            ))
            children.append(XMLTreeNode(name: "useDrumset", text: "1"))
        }
        for pitch in drumLineMap.keys.sorted() {
            // MuseScore Studio refuses to apply per-pitch line
            // positions when a `<Drum>` entry lacks `<head>` /
            // `<voice>` / `<stem>` — every drum then renders on the
            // same default line. Supply GM-conventional defaults
            // (head shape from the pitch, voice 1 / stem-down for
            // bass-drum / pedal-hi-hat / low-floor-tom, otherwise
            // voice 0 / stem-up). Element order matches MuseScore's
            // own writer: head → line → voice → stem.
            let line = drumLineMap[pitch] ?? 0
            let head = gmDrumHead(forPitch: pitch)
            let voiceIndex = gmDrumVoiceIndex(forPitch: pitch)
            let stem = voiceIndex == 1 ? 2 : 1 // 1 = up, 2 = down
            var drumChildren: [XMLTreeNode] = [
                XMLTreeNode(name: "head", text: head),
                XMLTreeNode(name: "line", text: String(line)),
                XMLTreeNode(name: "voice", text: String(voiceIndex)),
            ]
            if let name = gmDrumName(forPitch: pitch) {
                drumChildren.append(XMLTreeNode(name: "name", text: name))
            }
            drumChildren.append(XMLTreeNode(name: "stem", text: String(stem)))
            children.append(XMLTreeNode(
                name: "Drum",
                attributes: ["pitch": String(pitch)],
                children: drumChildren
            ))
        }
        for art in articulations {
            children.append(art.encode())
        }
        for chan in channels {
            children.append(chan.encode(options: options))
        }
        return XMLTreeNode(
            name: "Instrument",
            attributes: ["id": id],
            children: children
        )
    }
}

/// GM drum-pitch → notehead shape used by MuseScore Studio's stock
/// drumset. `cross` covers hi-hats / cymbals / cowbells; `slash` is
/// the slashed snare variant; `slashed1` is the side-stick (rim)
/// glyph; everything else uses the standard round notehead.
private func gmDrumHead(forPitch pitch: Int) -> String {
    switch pitch {
    case 37: "slashed1" // Side Stick (rim shot)
    case 40: "slash" // Electric Snare (slashed snare)
    case 42, 44, 46, 49, 51, 52, 53, 54, 55, 57, 59:
        "cross" // Hi-hats, ride/crash/splash cymbals, cowbell, ride bell
    default: "normal"
    }
}

/// GM drum-pitch → voice index (`0` = stems-up "hands" voice;
/// `1` = stems-down "feet" voice for bass / pedal-hi-hat / low
/// floor tom). Mirrors `MidiImporter.gmDrumVoiceIndex(for:)` —
/// kept in sync there for round-trip consistency.
private func gmDrumVoiceIndex(forPitch pitch: Int) -> Int {
    switch pitch {
    case 35, 36, 41, 44: 1
    default: 0
    }
}

/// GM drum-pitch → human-readable name. MuseScore Studio's
/// drumset reader requires a `<name>` on each `<Drum>` entry —
/// without it, the per-pitch line/head overrides are silently
/// discarded and every drum collapses onto the default line.
private func gmDrumName(forPitch pitch: Int) -> String? {
    switch pitch {
    case 35: "Acoustic Bass Drum"
    case 36: "Bass Drum 1"
    case 37: "Side Stick"
    case 38: "Acoustic Snare"
    case 39: "Hand Clap"
    case 40: "Electric Snare"
    case 41: "Low Floor Tom"
    case 42: "Closed Hi-Hat"
    case 43: "High Floor Tom"
    case 44: "Pedal Hi-Hat"
    case 45: "Low Tom"
    case 46: "Open Hi-Hat"
    case 47: "Low-Mid Tom"
    case 48: "Hi-Mid Tom"
    case 49: "Crash Cymbal 1"
    case 50: "High Tom"
    case 51: "Ride Cymbal 1"
    case 52: "Chinese Cymbal"
    case 53: "Ride Bell"
    case 54: "Tambourine"
    case 55: "Splash Cymbal"
    case 56: "Cowbell"
    case 57: "Crash Cymbal 2"
    case 58: "Vibraslap"
    case 59: "Ride Cymbal 2"
    case 60: "Hi Bongo"
    case 61: "Low Bongo"
    default: nil
    }
}
