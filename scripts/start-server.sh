#!/usr/bin/env bash
# Start the local whisper.cpp server for the Subtitle app.
# Exposes an OpenAI-style endpoint at:
#   http://HOST:PORT/v1/audio/transcriptions
#
# Includes anti-repetition settings to avoid Whisper's "stuck repeating the
# same line" hallucination on silence/music/non-speech:
#   -mc 0 : keep no previous-text context (breaks repetition loops)
#   -sns  : suppress non-speech tokens
#   --vad : skip non-speech segments (used automatically if a VAD model exists)
set -euo pipefail

ROOT="/Volumes/990plus/Whisper/whisper.cpp"
# Model selection: override with WHISPER_MODEL=<path or name>. Defaults to the
# higher-accuracy large-v3, falling back to large-v3-turbo if it's not present.
MODEL="${WHISPER_MODEL:-${ROOT}/models/ggml-large-v3.bin}"
# Allow passing a bare model name (e.g. WHISPER_MODEL=large-v3-turbo).
if [[ ! -f "${MODEL}" && -f "${ROOT}/models/ggml-${MODEL}.bin" ]]; then
  MODEL="${ROOT}/models/ggml-${MODEL}.bin"
fi
if [[ ! -f "${MODEL}" ]]; then
  MODEL="${ROOT}/models/ggml-large-v3-turbo.bin"
fi
VAD_MODEL="${ROOT}/models/ggml-silero-v5.1.2.bin"
HOST="127.0.0.1"
PORT="8080"

# Prefer the CoreML-enabled build (encoder on the Apple Neural Engine) if present.
if [[ -x "${ROOT}/build-coreml/bin/whisper-server" ]]; then
  SERVER="${ROOT}/build-coreml/bin/whisper-server"
else
  SERVER="${ROOT}/build/bin/whisper-server"
fi

if [[ ! -x "${SERVER}" ]]; then
  echo "Error: whisper-server binary not found at ${SERVER}" >&2
  echo "Build it first: cmake -B build && cmake --build build -j --config Release --target whisper-server" >&2
  exit 1
fi

if [[ ! -f "${MODEL}" ]]; then
  echo "Error: model not found at ${MODEL}" >&2
  exit 1
fi

ARGS=(
  -m "${MODEL}"
  --host "${HOST}"
  --port "${PORT}"
  --inference-path /v1/audio/transcriptions
  -l auto
  -t 8           # CPU threads for mel/encode work
  -mc 0          # keep no previous-text context -> prevents repetition loops
  -sns           # suppress non-speech tokens
  -pp            # print progress to the log
  -fa            # flash attention (faster, no meaningful accuracy loss)
  -bs 2          # beam search (2 = good accuracy, ~2x faster than 5)
  -bo 2          # best-of candidates
)

# VAD is OFF by default: it can mis-map timestamps and produce giant multi-minute
# cues on some files. Without VAD, Whisper's native ~30s windowing caps cue
# length. Enable with WHISPER_VAD=1 if you prefer VAD's non-speech skipping.
if [[ "${WHISPER_VAD:-0}" == "1" && -f "${VAD_MODEL}" ]]; then
  ARGS+=(
    --vad --vad-model "${VAD_MODEL}"
    --vad-max-speech-duration-s 20     # cap segment length -> no giant cues
    --vad-min-silence-duration-ms 200  # split on shorter pauses
  )
  echo "VAD enabled: ${VAD_MODEL}"
else
  echo "VAD disabled (set WHISPER_VAD=1 to enable)."
fi

echo "Starting whisper-server on http://${HOST}:${PORT}"
echo "Server: ${SERVER}"
echo "Model: ${MODEL}"
echo "Endpoint: http://${HOST}:${PORT}/v1/audio/transcriptions"

exec "${SERVER}" "${ARGS[@]}"
