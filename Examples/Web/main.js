// Demo host for @jiyimeta/sheet-music-web.
//
// Deliberately un-bundled: it imports the package's built ESM directly, so what
// runs here is what a consumer gets rather than something a bundler rewrote.
//
// Build first:
//   Scripts/wasm-build-web.sh
//   npm --prefix Web/sheet-music-web run build
import {
  drawPage,
  loadScoreFonts,
  loadSheetMusic,
  planPageTiles,
} from "../../Web/sheet-music-web/dist-esm/index.js";
import {
  createPlaybackEngine,
  createSpessaSynthHost,
} from "../../Web/sheet-music-web/dist-esm/playback/index.js";

const PACKAGE_ROOT = new URL("../../Web/sheet-music-web/", import.meta.url);
const status = document.querySelector("#status");
const pagesHost = document.querySelector("#pages");
const fileInput = document.querySelector("#file");

const soundFontInput = document.querySelector("#soundfont");
const playButton = document.querySelector("#play");
const stopButton = document.querySelector("#stop");
const countInBox = document.querySelector("#countin");
const metronomeBox = document.querySelector("#metronome");
const rateSlider = document.querySelector("#rate");
const rateReadout = document.querySelector("#rate-readout");
const loopFrom = document.querySelector("#loop-from");
const loopTo = document.querySelector("#loop-to");
const loopApply = document.querySelector("#loop-apply");
const loopClear = document.querySelector("#loop-clear");
const exportButton = document.querySelector("#export");
const playbackStatus = document.querySelector("#playback-status");
const mixerHost = document.querySelector("#mixer");

/**
 * Pixels per document millimetre. 96 dpi / 25.4 mm-per-inch is 1:1 on a
 * standard display; doubling it rasterizes glyphs at twice the resolution,
 * which is what keeps them sharp — the CSS width below scales the canvas back
 * down rather than scaling the bitmap up.
 */
const PX_PER_MM = (96 / 25.4) * 2;
const CSS_PX_PER_MM = 96 / 25.4;

let sheetMusic;
let fonts;
let openScore;

/** One entry per drawn canvas, so an overlay can be placed on the right tile. */
let tiles = [];
let soundFontBytes = null;
let synthHost = null;
let engine = null;
let loopRange = null;

async function boot() {
  sheetMusic = await loadSheetMusic({
    bundleURL: new URL("dist/", PACKAGE_ROOT),
    platform: "browser",
  });

  const metrics = await fetch(new URL("assets/bravura.smft", PACKAGE_ROOT));
  if (!metrics.ok) {
    throw new Error(`could not fetch bravura.smft (${metrics.status})`);
  }
  if (!sheetMusic.installSMuFLMetrics(new Uint8Array(await metrics.arrayBuffer()))) {
    throw new Error("the Bravura metrics table failed to install");
  }

  fonts = await loadScoreFonts({
    bravura: new URL("assets/bravura.woff2", PACKAGE_ROOT),
    edwinRoman: new URL("assets/edwin-roman.woff2", PACKAGE_ROOT),
  });

  status.textContent = `engine ${sheetMusic.engineVersionStamp()} ready — pick a score`;
  document.body.dataset.engineReady = "true";
}

function render(bytes) {
  openScore?.release();
  openScore = sheetMusic.loadScore(bytes);
  const { title, composer, partCount, staffCount, openingQuarterBpm } =
    openScore.metadata;
  status.textContent =
    `${title || "untitled"}${composer ? ` — ${composer}` : ""} · ` +
    `${partCount} part(s), ${staffCount} stave(s), ♩ = ${Math.round(openingQuarterBpm)}`;

  const pages = openScore.layout({ pageWidthMM: 210, pageHeightMM: 297 });
  pagesHost.replaceChildren();
  tiles = [];
  let tileCount = 0;
  for (const page of pages) {
    // The bridge's only layout mode is continuous, so a page is the whole
    // document — 18 metres for a six-part score, which is 135 000 pixels here.
    // A canvas that tall silently draws nothing, so it gets tiled.
    for (const tile of planPageTiles(page, PX_PER_MM)) {
      const holder = document.createElement("div");
      holder.className = "tile";
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(page.widthMM * PX_PER_MM);
      canvas.height = Math.round(tile.heightMM * PX_PER_MM);
      canvas.style.width = `${page.widthMM * CSS_PX_PER_MM}px`;
      drawPage(canvas.getContext("2d"), page, PX_PER_MM, fonts, {
        offsetMM: tile.offsetMM,
      });
      holder.append(canvas);
      pagesHost.append(holder);
      tiles.push({
        holder,
        offsetMM: tile.offsetMM,
        heightMM: tile.heightMM,
      });
      tileCount += 1;
    }
  }
  document.body.dataset.pageCount = String(pages.length);
  document.body.dataset.tileCount = String(tileCount);

  const summary = openScore.playbackSummary();
  loopFrom.max = String(summary?.measureCount ?? 1);
  loopTo.max = String(summary?.measureCount ?? 1);
  loopTo.value = String(summary?.measureCount ?? 1);
  resetPlayback();
  updateControls();
}

// MARK: overlays

/**
 * Places `element` at a document-millimetre rectangle, on whichever tile that
 * rectangle starts in. A rectangle straddling a tile boundary is clipped to the
 * tile it starts on — the tiling exists because a canvas taller than 65 535 px
 * silently draws nothing, and a highlight losing its bottom edge at that seam is
 * a smaller problem than the machinery to split it.
 */
function placeOnTile(element, xMM, yMM, widthMM, heightMM) {
  const tile = tiles.find(
    (candidate) =>
      yMM >= candidate.offsetMM && yMM < candidate.offsetMM + candidate.heightMM,
  );
  if (!tile) return false;
  element.style.left = `${xMM * CSS_PX_PER_MM}px`;
  element.style.top = `${(yMM - tile.offsetMM) * CSS_PX_PER_MM}px`;
  element.style.width = `${widthMM * CSS_PX_PER_MM}px`;
  element.style.height = `${heightMM * CSS_PX_PER_MM}px`;
  tile.holder.append(element);
  return true;
}

function clearOverlays(className) {
  for (const node of pagesHost.querySelectorAll(`.${className}`)) node.remove();
}

function drawCursor(rect) {
  clearOverlays("cursor");
  if (!rect) {
    document.body.dataset.cursorY = "";
    return;
  }
  const element = document.createElement("div");
  element.className = "cursor";
  if (placeOnTile(element, rect.xMM, rect.yMM, rect.widthMM, rect.heightMM)) {
    // Playwright reads these rather than pixels: what matters is that the
    // cursor advances, and sampling the canvas would also pick up the notes.
    document.body.dataset.cursorY = rect.yMM.toFixed(3);
    document.body.dataset.cursorMeasure = String(rect.measureIndex);
  }
}

function drawLoopHighlight() {
  clearOverlays("loop-highlight");
  if (!engine || !loopRange) return;
  const rects = engine.loopHighlightRects();
  for (let i = 0; i + 3 < rects.length; i += 4) {
    const element = document.createElement("div");
    element.className = "loop-highlight";
    placeOnTile(element, rects[i], rects[i + 1], rects[i + 2], rects[i + 3]);
  }
}

// MARK: playback

function resetPlayback() {
  engine?.dispose();
  engine = null;
  loopRange = null;
  clearOverlays("cursor");
  clearOverlays("loop-highlight");
  mixerHost.replaceChildren();
  document.body.dataset.playbackState = "stopped";
}

/**
 * The 128 General MIDI patches, grouped by family, built once.
 *
 * Read out of the engine rather than transcribed here — it is the same table
 * the iOS and Android mixers show, and a second copy would drift silently.
 */
let gmOptionGroups = null;

function gmPatchSelect(selected) {
  if (gmOptionGroups === null) {
    gmOptionGroups = new Map();
    for (const instrument of sheetMusic.gmInstruments()) {
      if (!gmOptionGroups.has(instrument.family)) {
        gmOptionGroups.set(instrument.family, []);
      }
      gmOptionGroups.get(instrument.family).push(instrument);
    }
  }
  const select = document.createElement("select");
  select.className = "patch";
  for (const [family, instruments] of gmOptionGroups) {
    const group = document.createElement("optgroup");
    group.label = family;
    for (const instrument of instruments) {
      const option = document.createElement("option");
      option.value = String(instrument.program);
      option.textContent = `${instrument.program}. ${instrument.name}`;
      group.append(option);
    }
    select.append(group);
  }
  select.value = String(selected);
  return select;
}

/** One row per mixer strip: patch, level, mute. */
function buildMixer() {
  mixerHost.replaceChildren();
  if (!engine) return;
  for (const channel of engine.mixerChannels()) {
    const midi = channel.strip.channel;
    const row = document.createElement("div");
    row.className = "strip";
    row.dataset.channel = String(midi);

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = channel.strip.displayName;

    const chan = document.createElement("span");
    chan.className = "channel";
    chan.textContent = `ch ${midi}`;

    const mute = document.createElement("label");
    const muteBox = document.createElement("input");
    muteBox.type = "checkbox";
    muteBox.className = "mute";
    muteBox.addEventListener("change", () => {
      engine?.setStripMuted(midi, muteBox.checked);
    });
    mute.append(muteBox, document.createTextNode(" mute"));

    const level = document.createElement("input");
    level.type = "range";
    level.min = "0";
    level.max = "127";
    level.value = String(channel.volume);
    level.className = "level";
    level.addEventListener("input", () => {
      engine?.setStripVolume(midi, Number(level.value));
    });

    const patch = document.createElement("label");
    if (channel.strip.isDrums) {
      // Percussion has no patch to pick: channel 9 selects the drum bank
      // whatever the program says.
      patch.textContent = "drum kit";
    } else {
      const select = gmPatchSelect(channel.program);
      select.addEventListener("change", () => {
        engine?.setStripProgram(midi, Number(select.value));
      });
      patch.append(select);
    }

    row.append(name, chan, mute, level, patch);
    mixerHost.append(row);
  }
  document.body.dataset.mixerStripCount = String(engine.mixerChannels().length);
}

function updateControls() {
  const ready = Boolean(openScore) && Boolean(soundFontBytes);
  playButton.disabled = !ready;
  stopButton.disabled = !engine;
  loopApply.disabled = !engine;
  loopClear.disabled = !engine;
  exportButton.disabled = !engine?.canExport;
  playButton.textContent = engine?.state === "playing" ? "Pause" : "Play";
}

/**
 * Builds the synth on first use, inside the click handler.
 *
 * An `AudioContext` cannot start outside a user gesture, and the AudioWorklet
 * the synth runs in needs a secure context — `http://localhost` qualifies,
 * opening `index.html` straight off the filesystem does not.
 */
async function ensureEngine() {
  if (engine) return engine;
  if (!synthHost) {
    synthHost = await createSpessaSynthHost({
      context: new AudioContext(),
      soundFont: soundFontBytes,
      processorURL: new URL(
        "node_modules/spessasynth_lib/dist/spessasynth_processor.min.js",
        PACKAGE_ROOT,
      ),
    });
  }
  engine = await createPlaybackEngine({
    score: openScore,
    host: synthHost,
    onCursor: drawCursor,
    onStateChange: (state) => {
      document.body.dataset.playbackState = state;
      playbackStatus.textContent = state;
      updateControls();
    },
  });
  engine.setMetronomeMuted(!metronomeBox.checked);
  engine.setRate(Number(rateSlider.value));
  buildMixer();
  return engine;
}

playButton.addEventListener("click", async () => {
  try {
    const active = await ensureEngine();
    if (active.state === "playing" || active.state === "counting-in") {
      active.pause();
    } else {
      await active.play({ countIn: countInBox.checked });
    }
    updateControls();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    playbackStatus.textContent = `playback failed: ${message}`;
    // Also on the body: a failed play leaves the state at "stopped", which is
    // indistinguishable from "nothing happened yet" to a test.
    document.body.dataset.playbackError = message;
  }
});

stopButton.addEventListener("click", () => {
  engine?.stop();
  updateControls();
});

soundFontInput.addEventListener("change", async () => {
  const file = soundFontInput.files?.[0];
  if (!file) return;
  soundFontBytes = await file.arrayBuffer();
  // A new bank means a new synth: the old one has the previous one loaded.
  await synthHost?.dispose();
  synthHost = null;
  resetPlayback();
  updateControls();
  document.body.dataset.soundfontReady = "true";
});

metronomeBox.addEventListener("change", () => {
  engine?.setMetronomeMuted(!metronomeBox.checked);
});

rateSlider.addEventListener("input", () => {
  const rate = Number(rateSlider.value);
  rateReadout.textContent = `${rate.toFixed(2)}×`;
  engine?.setRate(rate);
});

loopApply.addEventListener("click", () => {
  if (!engine) return;
  // The inputs count measures from 1, the bridge from 0, and the range is
  // half-open — so "1 to 2" means both bars.
  loopRange = {
    fromMeasureIndex: Number(loopFrom.value) - 1,
    toMeasureExclusive: Number(loopTo.value),
  };
  engine.setLoop(loopRange);
  drawLoopHighlight();
});

loopClear.addEventListener("click", () => {
  loopRange = null;
  engine?.setLoop(null);
  clearOverlays("loop-highlight");
});

exportButton.addEventListener("click", async () => {
  if (!engine) return;
  // Playing while rendering is not a problem for the engine, but the file would
  // be a snapshot of a mixer the user is still moving. Stop first.
  engine.pause();
  exportButton.disabled = true;
  playbackStatus.textContent = "rendering…";
  try {
    // The active loop, when there is one — exporting exactly what is being
    // looped is the common case, and matches AudioExportRange.currentLoop on
    // the other platforms.
    const bytes = await engine.exportWav(loopRange ? { range: loopRange } : {});
    const url = URL.createObjectURL(new Blob([bytes], { type: "audio/wav" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `${openScore?.metadata.title || "score"}.wav`;
    link.click();
    URL.revokeObjectURL(url);
    playbackStatus.textContent = `exported ${(bytes.length / 1e6).toFixed(1)} MB`;
    document.body.dataset.exportedBytes = String(bytes.length);
    // Peak level, for the browser test. A render that was configured wrong
    // produces a buffer of exactly the right length full of silence, which the
    // byte count cannot tell apart from a good one.
    const samples = new Int16Array(
      bytes.buffer,
      bytes.byteOffset + 44,
      (bytes.length - 44) >> 1,
    );
    let peak = 0;
    for (const sample of samples) peak = Math.max(peak, Math.abs(sample));
    document.body.dataset.exportedPeak = String(peak);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    playbackStatus.textContent = `export failed: ${message}`;
    document.body.dataset.exportError = message;
  } finally {
    updateControls();
  }
});

fileInput.addEventListener("change", async () => {
  const file = fileInput.files?.[0];
  if (!file) return;
  try {
    render(new Uint8Array(await file.arrayBuffer()));
  } catch (error) {
    status.textContent = `failed: ${
      error instanceof Error ? error.message : String(error)
    }`;
  }
});

// Playwright drives the viewer through this: a file input cannot be populated
// from a URL, and the point of the screenshot test is the rendering, not the
// picker.
window.renderScoreFromURL = async (url) => {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`could not fetch ${url} (${response.status})`);
  }
  render(new Uint8Array(await response.arrayBuffer()));
};

/**
 * Gives the browser test a valid SoundFont without committing one.
 *
 * `buildClickSoundFont` produces a bank-128 bank holding the two click samples
 * and nothing else, so the score plays silently — which is all the transport
 * test needs, and it sidesteps the question of which General MIDI bank may be
 * redistributed in this repository.
 */
window.useGeneratedSoundFont = () => {
  const wav = (frequency, seconds = 0.05, rate = 22050) => {
    const frames = Math.round(seconds * rate);
    const bytes = new Uint8Array(44 + frames * 2);
    const view = new DataView(bytes.buffer);
    const ascii = (offset, text) => {
      for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i));
    };
    ascii(0, "RIFF");
    view.setUint32(4, 36 + frames * 2, true);
    ascii(8, "WAVEfmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true); // PCM
    view.setUint16(22, 1, true); // mono
    view.setUint32(24, rate, true);
    view.setUint32(28, rate * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    ascii(36, "data");
    view.setUint32(40, frames * 2, true);
    for (let i = 0; i < frames; i++) {
      const decay = 1 - i / frames;
      const value = Math.sin((2 * Math.PI * frequency * i) / rate) * 0.6 * decay;
      view.setInt16(44 + i * 2, Math.round(value * 32767), true);
    }
    return bytes;
  };

  const sf2 = sheetMusic.buildClickSoundFont(wav(1600), wav(1200));
  if (sf2.length === 0) throw new Error("could not build a click SoundFont");
  soundFontBytes = sf2.slice().buffer;
  synthHost = null;
  resetPlayback();
  updateControls();
  document.body.dataset.soundfontReady = "true";
};

boot().catch((error) => {
  status.textContent = `engine failed: ${error.message}`;
});
