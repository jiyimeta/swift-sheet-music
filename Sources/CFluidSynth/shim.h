/* Shim over Homebrew's libfluidsynth so SwiftPM can import it as the
 * `CFluidSynth` system module. Header/library search paths come from
 * `pkgConfig: "fluidsynth"` in Package.swift; a build therefore needs
 * `fluid-synth` installed (Homebrew) and
 * `PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig` on the environment.
 *
 * FluidSynth is LGPL-2.1; only the Apple-only, opt-in
 * `SheetMusicAudioFluidSynth` product links it. The MIT core never does.
 */
#include <fluidsynth.h>
