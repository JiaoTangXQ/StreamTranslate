#!/bin/zsh

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    print -u2 -- "Nemotron Metal installation requires an Apple Silicon Mac."
    exit 1
fi

runtime_version="0.1.0"
runtime_archive="nemo-speech-${runtime_version}-macos-aarch64-metal.tar.gz"
runtime_sha256="f1dff4f9dd9c96214f8cb78b982812459132df8a4ad1a42409fd94de4a366244"
runtime_url="https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v${runtime_version}/${runtime_archive}"

model_filename="nemotron-speech-streaming-en-0.6b.q8_0.gguf"
model_sha256="d9a01898d2a611c8764e23a1c2f45e70bbd5a425dc4de93692ac951dd603812d"
model_revision="ebe59e5a817142986528bbbee5dba8db7b38ed50"
model_url="https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b/resolve/${model_revision}/${model_filename}?download=true"

support_root="$HOME/Library/Application Support/StreamTranslate/Nemotron"
support_parent=${support_root:h}
previous_root="${support_root}.previous"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/streamtranslate-nemotron.XXXXXX")

cleanup() {
    find "$temporary_root" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

runtime_download="$temporary_root/$runtime_archive"
model_download="$temporary_root/$model_filename"
staged_root="$temporary_root/staged"

print -- "Downloading NeMo-Speech.cpp ${runtime_version} Metal runtime..."
curl --fail --location --retry 3 --progress-bar \
    --output "$runtime_download" "$runtime_url"
print -r -- "$runtime_sha256  $runtime_download" | shasum -a 256 -c -

print -- "Downloading Nemotron Streaming English 0.6B Q8 (667 MiB)..."
curl --fail --location --retry 3 --progress-bar \
    --output "$model_download" "$model_url"
print -r -- "$model_sha256  $model_download" | shasum -a 256 -c -

mkdir -p "$staged_root/runtime" "$staged_root/models"
tar -xzf "$runtime_download" -C "$staged_root/runtime"
mv "$model_download" "$staged_root/models/$model_filename"

library="$staged_root/runtime/nemo-speech/lib/libnemo_speech_asr_c.1.dylib"
if [[ ! -f "$library" ]]; then
    print -u2 -- "Runtime archive did not contain the expected ASR library."
    exit 1
fi

mkdir -p "$support_parent"
if [[ -e "$previous_root" ]]; then
    find "$previous_root" -depth -delete
fi
if [[ -e "$support_root" ]]; then
    mv "$support_root" "$previous_root"
fi

restore_previous() {
    if [[ ! -e "$support_root" && -e "$previous_root" ]]; then
        mv "$previous_root" "$support_root"
    fi
}
trap 'restore_previous; cleanup' EXIT

mv "$staged_root" "$support_root"
if [[ -e "$previous_root" ]]; then
    find "$previous_root" -depth -delete
fi

trap cleanup EXIT
print -- "Nemotron installed at: $support_root"
print -- "Select '最低延迟（本机安装）' in StreamTranslate settings."
