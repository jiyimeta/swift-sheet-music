import SheetMusicFoundation

/// Which voices of its instrument a dynamic or a hairpin plays in — MuseScore's `VoiceAssignment`
/// (`engraving/types/types.h:351-355`), saved as `<voiceAssignment>` (`types/typesconv.cpp:992-996`) only when it is
/// not the whole instrument, the default (`dom/textbase.cpp:2781-2782`, `dom/hairpin.cpp:771-772`).
public enum VoiceAssignment: String, Sendable, Equatable, CaseIterable {
    case allInInstrument
    case allInStaff
    case currentVoiceOnly

    /// MuseScore 4's precedence between two dynamics on one tick of one voice: its enum order, so the narrower
    /// assignment wins (`PlaybackContext::applyDynamic`, `engraving/playback/playbackcontext.cpp:805-837`).
    package var priority: Int {
        switch self {
        case .allInInstrument: 0
        case .allInStaff: 1
        case .currentVoiceOnly: 2
        }
    }

    /// MuseScore 3's and 4.0–4.3's `<dynType>` as MuseScore 4 reads it: 0 (staff) is the staff's voices, 1 (part) and
    /// 2 (system) the whole instrument (`rw/read206/read206.cpp:505-516`, `rw/read410/tread.cpp:771-776`).
    package init(dynType: Int) {
        self = dynType == 0 ? .allInStaff : .allInInstrument
    }
}
