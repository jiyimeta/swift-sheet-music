// Demo host for @jiyimeta/sheet-music-web.
//
// Deliberately un-bundled: it imports the package's built ESM directly, so what
// runs here is what a consumer gets rather than something a bundler rewrote.
//
// Build first:
//   Scripts/wasm-build-web.sh
//   npm --prefix Web/sheet-music-web run build
import {
  drawTile,
  loadScoreFonts,
  loadSheetMusic,
  planViewportTiles,
  reconcileMounts,
  splitIntoBands,
} from "../../Web/sheet-music-web/dist-esm/index.js";
import {
  createPlaybackEngine,
  createSpessaSynthHost,
} from "../../Web/sheet-music-web/dist-esm/playback/index.js";

const PACKAGE_ROOT = new URL("../../Web/sheet-music-web/", import.meta.url);
const status = document.querySelector("#status");
const pagesHost = document.querySelector("#pages");
const scoreSpacer = document.querySelector("#score-spacer");
const tileLayer = document.querySelector("#tile-layer");
const overlayLayer = document.querySelector("#overlay-layer");
const fileInput = document.querySelector("#file");

const soundFontInput = document.querySelector("#soundfont");
const playButton = document.querySelector("#play");
const stopButton = document.querySelector("#stop");
const editModeBox = document.querySelector("#edit-mode");
const countInBox = document.querySelector("#countin");
const metronomeBox = document.querySelector("#metronome");
const rateSlider = document.querySelector("#rate");
const rateReadout = document.querySelector("#rate-readout");
const zoomSlider = document.querySelector("#zoom");
const zoomReadout = document.querySelector("#zoom-readout");
const staffSizeSlider = document.querySelector("#staff-size");
const staffSizeReadout = document.querySelector("#staff-size-readout");
const loopFrom = document.querySelector("#loop-from");
const loopTo = document.querySelector("#loop-to");
const loopApply = document.querySelector("#loop-apply");
const loopClear = document.querySelector("#loop-clear");
const tuningSlider = document.querySelector("#tuning");
const tuningReadout = document.querySelector("#tuning-readout");
const exportButton = document.querySelector("#export");
const playbackStatus = document.querySelector("#playback-status");
const mixerHost = document.querySelector("#mixer");

/**
 * Pixels per document millimetre. 96 dpi / 25.4 mm-per-inch is 1:1 on a
 * standard display; doubling it rasterizes glyphs at twice the resolution,
 * which is what keeps them sharp — the CSS width below scales the canvas back
 * down rather than scaling the bitmap up.
 */
const BASE_CSS_PX_PER_MM = 96 / 25.4;
const BASE_RASTER_SCALE = 2;
const DEFAULT_ZOOM = 1;
let zoom = DEFAULT_ZOOM;
let pxPerMM = BASE_CSS_PX_PER_MM * BASE_RASTER_SCALE * zoom;

let sheetMusic;
let fonts;
let openScore;

let pageModels = [];
let tiles = [];
let mountedTiles = new Map();
let canvasPool = [];
let documentHeightMM = 0;
let documentWidthMM = 0;
let bandCount = 0;
let totalCommands = 0;
let lastEditGeneration = 0;
let soundFontBytes = null;
let synthHost = null;
let engine = null;
let loopRange = null;
let lastCursorRect = null;
let editMode = false;
let selectedItem = null;
let selectedPitch = null;
let editCount = 0;

const CHROMATIC_SHARP_TPCS = [14, 21, 16, 23, 18, 13, 20, 15, 22, 17, 24, 19];
const LETTER_PITCH_CLASSES = new Map([
  ["C", 0],
  ["D", 2],
  ["E", 4],
  ["F", 5],
  ["G", 7],
  ["A", 9],
  ["B", 11],
]);
const DIGIT_DURATIONS = new Map([
  ["1", "whole"],
  ["2", "half"],
  ["3", "quarter"],
  ["4", "eighth"],
  ["5", "sixteenth"],
  ["6", "thirtySecond"],
  ["7", "sixtyFourth"],
]);

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
  selectedItem = null;
  selectedPitch = null;
  editCount = 0;
  document.body.dataset.editRefusal = "";
  if (editMode) {
    openScore.beginEditing();
  }
  const { title, composer, partCount, staffCount, openingQuarterBpm } =
    openScore.metadata;
  status.textContent =
    `${title || "untitled"}${composer ? ` — ${composer}` : ""} · ` +
    `${partCount} part(s), ${staffCount} stave(s), ♩ = ${Math.round(openingQuarterBpm)}`;

  drawOpenScore();
  resetPlayback();
  updateEditDataset();
  updateControls();
}

function cssPxPerMM() {
  return BASE_CSS_PX_PER_MM * zoom;
}

function layoutRequest() {
  return {
    pageWidthMM: 210,
    pageHeightMM: 297,
    options: { staffSize: Number(staffSizeSlider.value) },
  };
}

function currentScrollTopMM() {
  return pagesHost.scrollTop / cssPxPerMM();
}

function buildPageModels(pages) {
  pageModels = [];
  tiles = [];
  documentHeightMM = 0;
  documentWidthMM = 0;
  bandCount = 0;
  totalCommands = 0;

  for (const page of pages) {
    const bands = splitIntoBands(page);
    const pageOffsetMM = documentHeightMM;
    const pageTiles = planViewportTiles(page, pxPerMM);
    pageModels.push({ page, bands, pageOffsetMM });
    bandCount += bands.length;
    documentHeightMM += page.heightMM;
    documentWidthMM = Math.max(documentWidthMM, page.widthMM);
    for (const tile of pageTiles) {
      tiles.push({
        page,
        bands,
        pageOffsetMM,
        tile,
        offsetMM: pageOffsetMM + tile.offsetMM,
        heightMM: tile.heightMM,
      });
      totalCommands += page.commands.length;
    }
  }
}

function replanTiles() {
  tiles = [];
  totalCommands = 0;
  for (const model of pageModels) {
    for (const tile of planViewportTiles(model.page, pxPerMM)) {
      tiles.push({
        page: model.page,
        bands: model.bands,
        pageOffsetMM: model.pageOffsetMM,
        tile,
        offsetMM: model.pageOffsetMM + tile.offsetMM,
        heightMM: tile.heightMM,
      });
      totalCommands += model.page.commands.length;
    }
  }
}

function resizeDocument() {
  const scale = cssPxPerMM();
  scoreSpacer.style.width = `${documentWidthMM * scale}px`;
  scoreSpacer.style.height = `${documentHeightMM * scale}px`;
}

function takeCanvas() {
  return canvasPool.pop() ?? document.createElement("canvas");
}

function releaseCanvas(canvas) {
  canvas.width = 0;
  canvas.height = 0;
  canvas.removeAttribute("style");
  canvasPool.push(canvas);
}

function dropMountedTiles() {
  for (const mounted of mountedTiles.values()) {
    mounted.holder.remove();
    releaseCanvas(mounted.canvas);
  }
  mountedTiles = new Map();
}

function tileBandCommandCount(tileInfo) {
  const tileBottomMM = tileInfo.tile.offsetMM + tileInfo.tile.heightMM;
  let count = 0;
  for (const band of tileInfo.bands) {
    if (band.topMM < tileBottomMM && band.topMM + band.heightMM > tileInfo.tile.offsetMM) {
      count += band.commands.length;
    }
  }
  return count;
}

function mountTile(index) {
  if (mountedTiles.has(index)) return;
  const tileInfo = tiles[index];
  if (!tileInfo) return;

  const scale = cssPxPerMM();
  const holder = document.createElement("div");
  holder.className = "tile";
  holder.dataset.offsetMm = String(tileInfo.offsetMM);
  holder.dataset.heightMm = String(tileInfo.heightMM);
  holder.style.left = "0";
  holder.style.top = `${tileInfo.offsetMM * scale}px`;
  holder.style.width = `${tileInfo.page.widthMM * scale}px`;
  holder.style.height = `${tileInfo.heightMM * scale}px`;

  const canvas = takeCanvas();
  canvas.width = Math.round(tileInfo.page.widthMM * pxPerMM);
  canvas.height = Math.round(tileInfo.heightMM * pxPerMM);
  canvas.style.width = `${tileInfo.page.widthMM * scale}px`;
  canvas.style.height = `${tileInfo.heightMM * scale}px`;
  drawTile(canvas.getContext("2d"), tileInfo.bands, pxPerMM, fonts, tileInfo.tile);

  holder.append(canvas);
  tileLayer.append(holder);
  mountedTiles.set(index, {
    holder,
    canvas,
    pixels: canvas.width * canvas.height,
    walkedCommands: tileBandCommandCount(tileInfo),
  });
}

function unmountTile(index) {
  const mounted = mountedTiles.get(index);
  if (!mounted) return;
  mounted.holder.remove();
  releaseCanvas(mounted.canvas);
  mountedTiles.delete(index);
}

function reconcileVisibleTiles() {
  const window = {
    scrollTopMM: currentScrollTopMM(),
    viewportMM: pagesHost.clientHeight / cssPxPerMM(),
  };
  const next = reconcileMounts(tiles, window, new Set(mountedTiles.keys()));
  for (const index of next.unmount) unmountTile(index);
  for (const index of next.mount) mountTile(index);
  updateViewportDataset();
}

function updateRenderDataset() {
  document.body.dataset.pageCount = String(pageModels.length);
  document.body.dataset.tileCount = String(tiles.length);
  document.body.dataset.bandCount = String(bandCount);
  document.body.dataset.totalCommands = String(totalCommands);
}

function updateViewportDataset() {
  let mountedPixels = 0;
  let walkedCommands = 0;
  for (const mounted of mountedTiles.values()) {
    mountedPixels += mounted.pixels;
    walkedCommands += mounted.walkedCommands;
  }
  document.body.dataset.mountedTiles = String(mountedTiles.size);
  document.body.dataset.mountedPixels = String(mountedPixels);
  document.body.dataset.scrollTopMm = currentScrollTopMM().toFixed(3);
  document.body.dataset.pxPerMm = pxPerMM.toFixed(6);
  document.body.dataset.walkedCommands = String(walkedCommands);
}

function redrawOverlays() {
  drawCursor(lastCursorRect);
  drawLoopHighlight();
  drawSelectionAndCaret();
}

function rebuildRaster({ anchorMM }) {
  dropMountedTiles();
  replanTiles();
  resizeDocument();
  pagesHost.scrollTop = anchorMM * cssPxPerMM();
  reconcileVisibleTiles();
  redrawOverlays();
  updateRenderDataset();
  updateViewportDataset();
}

function drawOpenScore({ preserveScroll = false } = {}) {
  if (!openScore) return;
  const anchorMM = preserveScroll ? currentScrollTopMM() : 0;
  const pages = openScore.layout(layoutRequest());
  lastEditGeneration = openScore.editGeneration;
  buildPageModels(pages);
  resizeDocument();
  dropMountedTiles();
  pagesHost.scrollTop = anchorMM * cssPxPerMM();
  reconcileVisibleTiles();
  redrawOverlays();
  updateRenderDataset();

  const summary = openScore.playbackSummary();
  loopFrom.max = String(summary?.measureCount ?? 1);
  loopTo.max = String(summary?.measureCount ?? 1);
  loopTo.value = String(summary?.measureCount ?? 1);
}

// MARK: overlays

function clearOverlays(className) {
  for (const node of overlayLayer.querySelectorAll(`.${className}`)) node.remove();
}

function placeInDocument(element, xMM, yMM, widthMM, heightMM) {
  const scale = cssPxPerMM();
  element.style.left = `${xMM * scale}px`;
  element.style.top = `${yMM * scale}px`;
  element.style.width = `${widthMM * scale}px`;
  element.style.height = `${heightMM * scale}px`;
  overlayLayer.append(element);
}

function drawCursor(rect) {
  lastCursorRect = rect;
  clearOverlays("cursor");
  if (!rect) {
    document.body.dataset.cursorY = "";
    return;
  }
  const element = document.createElement("div");
  element.className = "cursor";
  placeInDocument(element, rect.xMM, rect.yMM, rect.widthMM, rect.heightMM);
  // Playwright reads these rather than pixels: what matters is that the cursor
  // advances, and sampling the canvas would also pick up the notes.
  document.body.dataset.cursorY = rect.yMM.toFixed(3);
  document.body.dataset.cursorMeasure = String(rect.measureIndex);
}

function drawLoopHighlight() {
  clearOverlays("loop-highlight");
  if (!engine || !loopRange) return;
  const rects = engine.loopHighlightRects();
  for (let i = 0; i + 3 < rects.length; i += 4) {
    const element = document.createElement("div");
    element.className = "loop-highlight";
    placeInDocument(element, rects[i], rects[i + 1], rects[i + 2], rects[i + 3]);
  }
}

function drawSelectionAndCaret() {
  clearOverlays("selection");
  clearOverlays("caret");
  document.body.dataset.caretX = "";
  document.body.dataset.caretY = "";
  if (!openScore || !selectedItem) return;
  const rect = openScore.caretRect(selectedItem, 3);
  if (!rect) return;

  const selection = document.createElement("div");
  selection.className = "selection";
  placeInDocument(selection, rect.xMM, rect.yMM, rect.widthMM, rect.heightMM);

  const caret = document.createElement("div");
  caret.className = "caret";
  placeInDocument(caret, rect.xMM, rect.yMM, 0.45, rect.heightMM);
  document.body.dataset.caretX = rect.xMM.toFixed(3);
  document.body.dataset.caretY = rect.yMM.toFixed(3);
}

function selectedItemToken(item) {
  if (!item) return "";
  return (
    `${item.kind}:` +
    [
      item.partIndex,
      item.staffIndexInPart,
      item.measureIndex,
      item.voiceIndex,
      item.elementIndex,
      item.noteIndexInChord,
    ].join("/")
  );
}

function updateEditDataset() {
  const state = openScore?.editState();
  document.body.dataset.editMode = editMode ? "true" : "";
  document.body.dataset.selectedItem = selectedItemToken(selectedItem);
  document.body.dataset.selectedPitch =
    selectedItem?.kind === "note" && selectedPitch !== null ? String(selectedPitch) : "";
  document.body.dataset.editCount = String(editCount);
  document.body.dataset.canUndo = state?.canUndo ? "true" : "";
  document.body.dataset.canRedo = state?.canRedo ? "true" : "";
  document.body.dataset.fingerprint = openScore?.fingerprint ?? "";
}

function clearSelection() {
  selectedItem = null;
  selectedPitch = null;
  clearOverlays("selection");
  clearOverlays("caret");
  updateEditDataset();
}

function selectAtPoint(xMM, yMM) {
  if (!openScore) return;
  const item = openScore.hitTest(xMM, yMM, 0);
  if (!item) {
    clearSelection();
    return;
  }
  selectedItem = item;
  selectedPitch = item.kind === "note" ? item.pitch : null;
  drawSelectionAndCaret();
  document.body.dataset.editRefusal = "";
  updateEditDataset();
}

function relayoutAfterAcceptedEdit(keepSelection) {
  if (openScore?.editGeneration !== lastEditGeneration) {
    drawOpenScore({ preserveScroll: true });
  }
  if (!keepSelection) {
    selectedItem = null;
    selectedPitch = null;
  }
  drawSelectionAndCaret();
  updateEditDataset();
  updateControls();
}

function applyDemoEdit(intent) {
  if (!openScore) return false;
  const outcome = openScore.applyEdit(intent);
  document.body.dataset.editRefusal = outcome.accepted ? "" : outcome.code;
  if (!outcome.accepted) {
    updateEditDataset();
    return false;
  }
  editCount += 1;
  relayoutAfterAcceptedEdit(true);
  return true;
}

function runUndoRedo(operation) {
  if (!openScore) return;
  const outcome = operation === "undo" ? openScore.undo() : openScore.redo();
  document.body.dataset.editRefusal = outcome.accepted ? "" : outcome.code;
  if (!outcome.accepted) {
    updateEditDataset();
    return;
  }
  editCount += 1;
  relayoutAfterAcceptedEdit(false);
}

function noteRef(item) {
  return {
    partIndex: item.partIndex,
    staffIndexInPart: item.staffIndexInPart,
    measureIndex: item.measureIndex,
    voiceIndex: item.voiceIndex,
    elementIndex: item.elementIndex,
    noteIndexInChord: item.noteIndexInChord,
  };
}

function elementRef(item) {
  return {
    partIndex: item.partIndex,
    staffIndexInPart: item.staffIndexInPart,
    measureIndex: item.measureIndex,
    voiceIndex: item.voiceIndex,
    elementIndex: item.elementIndex,
  };
}

function pitchNear(letter, referencePitch) {
  const pitchClass = LETTER_PITCH_CLASSES.get(letter);
  if (pitchClass === undefined) return referencePitch;
  let pitch = Math.floor(referencePitch / 12) * 12 + pitchClass;
  while (pitch - referencePitch > 6) pitch -= 12;
  while (referencePitch - pitch > 6) pitch += 12;
  return pitch;
}

function handleEditKey(event) {
  if (!editMode || !openScore) return;
  const undoKey = event.key.toLowerCase() === "z" && (event.metaKey || event.ctrlKey);
  if (undoKey) {
    event.preventDefault();
    runUndoRedo(event.shiftKey ? "redo" : "undo");
    return;
  }
  if (!selectedItem) return;

  if (event.key === "ArrowUp" || event.key === "ArrowDown") {
    if (selectedItem.kind !== "note" || selectedPitch === null) return;
    event.preventDefault();
    const pitch = selectedPitch + (event.key === "ArrowUp" ? 1 : -1);
    if (
      applyDemoEdit({
        type: "setNotePitch",
        at: noteRef(selectedItem),
        pitch,
        tpc: CHROMATIC_SHARP_TPCS[((pitch % 12) + 12) % 12],
        accidental: null,
      })
    ) {
      selectedPitch = pitch;
      selectedItem = {
        ...selectedItem,
        pitch,
        tpc: CHROMATIC_SHARP_TPCS[((pitch % 12) + 12) % 12],
      };
      updateEditDataset();
    }
    return;
  }

  const letter = event.key.toUpperCase();
  if (LETTER_PITCH_CLASSES.has(letter)) {
    if (selectedItem.kind !== "note" && selectedItem.kind !== "rest") return;
    event.preventDefault();
    const pitch = pitchNear(letter, selectedPitch ?? 60);
    const intent =
      selectedItem.kind === "rest"
        ? {
            type: "inputNote",
            at: elementRef(selectedItem),
            pitch,
            tpc: CHROMATIC_SHARP_TPCS[pitch % 12],
          }
        : {
            type: "writeNote",
            at: elementRef(selectedItem),
            pitch,
            tpc: CHROMATIC_SHARP_TPCS[pitch % 12],
          };
    if (applyDemoEdit(intent)) {
      selectedItem = {
        ...selectedItem,
        kind: "note",
        pitch,
        tpc: CHROMATIC_SHARP_TPCS[pitch % 12],
      };
      selectedPitch = pitch;
      updateEditDataset();
    }
    return;
  }

  const duration = DIGIT_DURATIONS.get(event.key);
  if (duration) {
    if (selectedItem.kind !== "note" && selectedItem.kind !== "rest") return;
    event.preventDefault();
    applyDemoEdit({
      type: selectedItem.kind === "note" ? "setChordDuration" : "setRestDuration",
      at: elementRef(selectedItem),
      duration,
    });
    return;
  }

  if (event.key === "Backspace") {
    event.preventDefault();
    applyDemoEdit({ type: "delete", at: elementRef(selectedItem) });
  }
}

// MARK: playback

function resetPlayback() {
  engine?.dispose();
  engine = null;
  loopRange = null;
  lastCursorRect = null;
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

    const solo = document.createElement("label");
    const soloBox = document.createElement("input");
    soloBox.type = "checkbox";
    soloBox.className = "solo";
    soloBox.addEventListener("change", () => {
      engine?.setStripSoloed(midi, soloBox.checked);
      // Solo changes what every OTHER strip is doing, so the whole panel's
      // audible state has to be re-read rather than just this row's.
      reflectAudibility();
    });
    solo.append(soloBox, document.createTextNode(" solo"));

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

    row.append(name, chan, mute, solo, level, patch);
    mixerHost.append(row);
  }
  document.body.dataset.mixerStripCount = String(engine.mixerChannels().length);
  reflectAudibility();
}

/** Dim the rows that solo has silenced, so the panel says what is sounding. */
function reflectAudibility() {
  if (!engine) return;
  for (const channel of engine.mixerChannels()) {
    const row = mixerHost.querySelector(`.strip[data-channel="${channel.strip.channel}"]`);
    if (row) row.style.opacity = channel.audible ? "1" : "0.45";
  }
  document.body.dataset.audibleStrips = engine
    .mixerChannels()
    .filter((channel) => channel.audible)
    .map((channel) => channel.strip.channel)
    .join(",");
}

function updateControls() {
  const ready = Boolean(openScore) && Boolean(soundFontBytes);
  playButton.disabled = !ready || editMode;
  stopButton.disabled = !engine || editMode;
  loopApply.disabled = !engine || editMode;
  loopClear.disabled = !engine || editMode;
  exportButton.disabled = !engine?.canExport || editMode;
  playButton.textContent = engine?.state === "playing" ? "Pause" : "Play";
}

function setEditMode(enabled) {
  if (editMode === enabled) return;
  editMode = enabled;
  resetPlayback();
  selectedItem = null;
  selectedPitch = null;
  if (openScore) {
    if (enabled) {
      openScore.beginEditing();
    } else {
      openScore.endEditing();
    }
  }
  clearOverlays("selection");
  clearOverlays("caret");
  updateEditDataset();
  updateControls();
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
  if (Number(tuningSlider.value) !== 0) {
    engine.setMasterTuning(Number(tuningSlider.value));
  }
  // A generated click bank, layered ahead of the GM one on the metronome synth.
  // Without it the metronome uses whatever the score's bank has at notes 76 and
  // 77 — a pair of wood blocks in General MIDI.
  const click = sheetMusic.buildClickSoundFont(clickWav(1800), clickWav(1200));
  if (click.length > 0) {
    const applied = await engine.setMetronomeClickSoundFont(click.slice().buffer);
    document.body.dataset.clickBank = applied ? "custom" : "gm";
  }
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

tuningSlider.addEventListener("input", () => {
  const cents = Number(tuningSlider.value);
  const hz = 440 * 2 ** (cents / 1200);
  tuningReadout.textContent = `${cents >= 0 ? "+" : ""}${cents}¢ (${hz.toFixed(1)} Hz)`;
  engine?.setMasterTuning(cents);
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

editModeBox.addEventListener("change", () => {
  setEditMode(editModeBox.checked);
});

document.addEventListener("keydown", handleEditKey);

pagesHost.addEventListener("scroll", () => {
  reconcileVisibleTiles();
});

pagesHost.addEventListener("click", (event) => {
  if (!openScore) return;
  // The spacer's bounding rect is already in viewport coordinates and already
  // shifted by the scroll, so both axes are one subtraction. Reaching for
  // `scrollTop` and `offsetTop` instead double-counts the scroll container's
  // own padding, which puts every tap a few millimetres off — far enough to
  // miss the staff it was aimed at.
  const spacerBox = scoreSpacer.getBoundingClientRect();
  const scale = cssPxPerMM();
  const xMM = (event.clientX - spacerBox.left) / scale;
  const yMM = (event.clientY - spacerBox.top) / scale;
  if (xMM < 0 || yMM < 0 || xMM > documentWidthMM || yMM > documentHeightMM) {
    if (editMode) clearSelection();
    return;
  }
  if (editMode) {
    selectAtPoint(xMM, yMM);
    return;
  }
  if (!engine) return;
  engine.seekToPoint(xMM, yMM);
  document.body.dataset.lastTap = `${xMM.toFixed(1)},${yMM.toFixed(1)}`;
  document.body.dataset.lastTapSeconds = String(
    openScore?.playerSecondsAtPoint(xMM, yMM),
  );
});

zoomSlider.addEventListener("input", () => {
  const anchorMM = currentScrollTopMM();
  zoom = Number(zoomSlider.value);
  pxPerMM = BASE_CSS_PX_PER_MM * BASE_RASTER_SCALE * zoom;
  zoomReadout.textContent = `${zoom.toFixed(2)}×`;
  if (pageModels.length > 0) {
    rebuildRaster({ anchorMM });
  } else {
    updateViewportDataset();
  }
});

staffSizeSlider.addEventListener("input", () => {
  staffSizeReadout.textContent = staffSizeSlider.value;
});

staffSizeSlider.addEventListener("change", () => {
  if (openScore) {
    drawOpenScore({ preserveScroll: true });
  }
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
/**
 * A short decaying sine as a mono 16-bit WAV — the input
 * `SheetMusic.buildClickSoundFont` turns into a bank-128 SoundFont.
 *
 * Synthesized rather than fetched so the demo needs no click assets, and so the
 * browser test can build a valid SoundFont without one being committed.
 */
function clickWav(frequency, seconds = 0.05, rate = 22050) {
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
}

window.useGeneratedSoundFont = () => {
  const sf2 = sheetMusic.buildClickSoundFont(clickWav(1600), clickWav(1200));
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
