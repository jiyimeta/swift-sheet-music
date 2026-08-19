/**
 * Loads the two faces the renderer draws with.
 *
 * The engraver's geometry does not come from here — layout runs inside wasm
 * against the `bravura.smft` metrics table. These faces only rasterize glyphs
 * whose positions were already decided, which is why the two failure modes look
 * nothing alike: a missing font gives tofu boxes in the right places, a missing
 * metrics table gives correct glyphs in the wrong ones.
 */

export interface ScoreFonts {
  /** CSS family name for SMuFL music glyphs. */
  readonly smufl: string;
  /** CSS family name for body text and lyrics. */
  readonly textRoman: string;
}

export interface FontURLs {
  readonly bravura: URL | string;
  readonly edwinRoman: URL | string;
}

/**
 * Register both faces with the document and wait for them to be usable.
 *
 * Call this before the first `drawPage`. Adding a `FontFace` to the document is
 * not enough on its own: until its load promise resolves, Canvas2D silently
 * substitutes a fallback, which for Bravura means every music glyph rasterizes
 * as a tofu box with no error anywhere.
 */
export async function loadScoreFonts(urls: FontURLs): Promise<ScoreFonts> {
  const bravura = new FontFace("Bravura", `url(${String(urls.bravura)})`);
  const edwin = new FontFace("Edwin", `url(${String(urls.edwinRoman)})`);
  await Promise.all([bravura.load(), edwin.load()]);
  document.fonts.add(bravura);
  document.fonts.add(edwin);
  return { smufl: "Bravura", textRoman: "Edwin" };
}
