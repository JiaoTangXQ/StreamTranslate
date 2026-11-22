'use strict';
// Phone microphone → 16 kHz mono Int16 in 100 ms frames for the Mac recognizer.
// A windowed-sinc low-pass removes content above 7.2 kHz before resampling,
// so 44.1/48 kHz input does not alias into the speech band.
class StreamTranslateCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.step = sampleRate / 16000;
    const taps = 31, cutoff = Math.min(0.45, 7200 / sampleRate);
    this.taps = new Float32Array(taps);
    let sum = 0;
    for (let i = 0; i < taps; i++) {
      const n = i - (taps - 1) / 2;
      const sinc = n === 0 ? 2 * cutoff : Math.sin(2 * Math.PI * cutoff * n) / (Math.PI * n);
      const window = 0.54 - 0.46 * Math.cos(2 * Math.PI * i / (taps - 1));
      this.taps[i] = sinc * window; sum += this.taps[i];
    }
    for (let i = 0; i < taps; i++) this.taps[i] /= sum;
    this.history = new Float32Array(taps); this.head = 0;
    this.previous = 0; this.phase = 0;
    this.frame = new Int16Array(1600); this.filled = 0; this.energy = 0;
  }
  filter(sample) {
    this.history[this.head] = sample;
    let value = 0, index = this.head;
    for (let i = 0; i < this.taps.length; i++) {
      value += this.taps[i] * this.history[index];
      index = index === 0 ? this.history.length - 1 : index - 1;
    }
    this.head = (this.head + 1) % this.history.length;
    return value;
  }
  emit(value) {
    const clamped = Math.max(-1, Math.min(1, value));
    this.frame[this.filled++] = clamped < 0 ? clamped * 32768 : clamped * 32767;
    this.energy += clamped * clamped;
    if (this.filled === this.frame.length) {
      const rms = Math.sqrt(this.energy / this.frame.length);
      this.port.postMessage({pcm: this.frame.buffer, rms}, [this.frame.buffer]);
      this.frame = new Int16Array(1600); this.filled = 0; this.energy = 0;
    }
  }
  process(inputs) {
    const channels = inputs[0];
    if (!channels || !channels.length) return true;
    const input = channels[0];
    for (let i = 0; i < input.length; i++) {
      let sample = input[i];
      for (let c = 1; c < channels.length; c++) sample += channels[c][i];
      const current = this.filter(sample / channels.length);
      // Linear interpolation between filtered input samples at 16 kHz times.
      while (this.phase < 1) {
        this.emit(this.previous + (current - this.previous) * this.phase);
        this.phase += this.step;
      }
      this.phase -= 1;
      this.previous = current;
    }
    return true;
  }
}
registerProcessor('streamtranslate-capture', StreamTranslateCapture);
