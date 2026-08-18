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
} from "../../Web/sheet-music-web/dist-esm/index.js";

const PACKAGE_ROOT = new URL("../../Web/sheet-music-web/", import.meta.url);
const status = document.querySelector("#status");
const pagesHost = document.querySelector("#pages");
const fileInput = document.querySelector("#file");

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
  for (const page of pages) {
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(page.widthMM * PX_PER_MM);
    canvas.height = Math.round(page.heightMM * PX_PER_MM);
    canvas.style.width = `${page.widthMM * CSS_PX_PER_MM}px`;
    const ctx = canvas.getContext("2d");
    drawPage(ctx, page, PX_PER_MM, fonts);
    pagesHost.append(canvas);
  }
  document.body.dataset.pageCount = String(pages.length);
}

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

boot().catch((error) => {
  status.textContent = `engine failed: ${error.message}`;
});
