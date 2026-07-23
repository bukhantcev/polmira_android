"use strict";

if (typeof self.Worker !== "function") {
  self.Worker = class {};
}

importScripts("./opus-decoder.min.js?v=0.7.11");

const OpusDecoder = self["opus-decoder"]?.OpusDecoder;
let decoder = null;
let workQueue = Promise.resolve();

async function initializeDecoder() {
  if (decoder) {
    decoder.free();
  }

  if (typeof OpusDecoder !== "function") {
    throw new Error("The bundled Opus decoder could not be loaded.");
  }

  decoder = new OpusDecoder({
    channels: 2,
    coupledStreamCount: 1,
    forceStereo: true,
    sampleRate: 48000,
    streamCount: 1,
  });
  await decoder.ready;
  self.postMessage({ type: "decoderInitialized" });
}

function interleave(channelData, samplesDecoded) {
  const left = channelData[0];
  const right = channelData[1] || left;
  const pcm = new Float32Array(samplesDecoded * 2);

  for (let index = 0; index < samplesDecoded; index += 1) {
    pcm[index * 2] = left[index] || 0;
    pcm[index * 2 + 1] = right[index] || 0;
  }
  return pcm;
}

async function decodeFrame(data) {
  if (!decoder) {
    await initializeDecoder();
  }

  const opusFrame = new Uint8Array(data.opusBuffer);
  const result = decoder.decodeFrame(opusFrame);
  if (!result.samplesDecoded) {
    return;
  }

  const pcm = interleave(result.channelData, result.samplesDecoded);
  self.postMessage(
    { type: "decodedAudioData", pcmBuffer: pcm.buffer },
    [pcm.buffer],
  );
}

async function handleMessage(message) {
  const { type, data = {} } = message;
  switch (type) {
    case "init":
    case "reinitialize":
      await initializeDecoder();
      break;
    case "decode":
      await decodeFrame(data);
      break;
    case "updatePipelineStatus":
      break;
    case "close":
      if (decoder) {
        decoder.free();
        decoder = null;
      }
      self.close();
      break;
    default:
      break;
  }
}

self.onmessage = (event) => {
  workQueue = workQueue
    .then(() => handleMessage(event.data))
    .catch((error) => {
      self.postMessage({
        type: "decoderError",
        message: error?.message || String(error),
      });
    });
};
