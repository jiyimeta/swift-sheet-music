/**
 * A stand-in for `AudioBuffer`, which Node does not have.
 *
 * The encoders read four members and nothing else — `numberOfChannels`,
 * `length`, `sampleRate` and `getChannelData` — so this is the whole surface
 * they need. Keeping it here rather than in each test file means a new encoder
 * cannot quietly start depending on a fifth member that only the browser has.
 */
export function fakeAudioBuffer(
  channels: Float32Array[],
  sampleRate = 44_100,
): AudioBuffer {
  const length = channels[0]?.length ?? 0;
  return {
    numberOfChannels: channels.length,
    length,
    sampleRate,
    duration: length / sampleRate,
    getChannelData: (index: number) => channels[index]!,
  } as unknown as AudioBuffer;
}
