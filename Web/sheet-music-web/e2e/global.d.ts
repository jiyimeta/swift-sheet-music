declare global {
  interface Window {
    /** Exposed by Examples/Web/main.js so a test can load a score by URL. */
    renderScoreFromURL(url: string): Promise<void>;
  }
}

export {};
