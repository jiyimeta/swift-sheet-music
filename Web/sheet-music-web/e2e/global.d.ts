declare global {
  interface Window {
    /** Exposed by Examples/Web/main.js so a test can load a score by URL. */
    renderScoreFromURL(url: string): Promise<void>;
    /**
     * Exposed by Examples/Web/main.js so a test can arm playback without a
     * committed SoundFont: it builds a two-sample click bank in the page.
     */
    useGeneratedSoundFont(): void;
  }
}

export {};
