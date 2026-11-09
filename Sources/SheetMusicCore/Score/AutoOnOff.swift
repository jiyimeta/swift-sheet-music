import SheetMusicFoundation

/// A three-way setting: defer to the level above (`auto`), or force the behavior on or off whatever that level says.
/// C++: `mu::engraving::AutoOnOff` (`types/types.h:338`); MuseScore 4.6 writes it as `auto` / `on` / `off`
/// (`types/typesconv.cpp:1008-1011`).
public enum AutoOnOff: String, Sendable, Equatable, CaseIterable {
    case auto, on, off
}
