#!/bin/zsh
set -euo pipefail

# Separate general-purpose model; the existing Qwen ASR/Hy-MT models are not
# used for summarization. Pin the upstream revision and verify the full payload.
summary_support="$HOME/Library/Application Support/StreamTranslate"
runtime_source="${1:-$summary_support/HyMT/runtime}"
[[ -x "$runtime_source/llama-server" ]] || {
    print -u2 'Missing llama.cpp runtime. Pass its directory as the first argument.'
    exit 1
}
stage=$(mktemp -d "${TMPDIR:-/tmp}/streamtranslate-summary.XXXXXX")
trap 'find "$stage" -depth -delete 2>/dev/null || true' EXIT
mkdir -p "$stage/Summary/runtime"
curl --fail --location --retry 2 --connect-timeout 15 --max-time 1200 \
    'https://huggingface.co/lmstudio-community/Qwen3-4B-Instruct-2507-GGUF/resolve/4edb920b6f14e3b9284d4502a6485103d72cde05/Qwen3-4B-Instruct-2507-Q4_K_M.gguf' \
    --output "$stage/Summary/model.gguf"
actual=$(shasum -a 256 "$stage/Summary/model.gguf" | awk '{print $1}')
[[ "$actual" == 8cdb57cbb880d313736a9bc4e3d3d2485f145b5e19cf33783746e753e82641fc ]] || {
    print -u2 'Summary model checksum mismatch; installation stopped.'; exit 1
}
ditto "$runtime_source" "$stage/Summary/runtime"
curl --fail --location --connect-timeout 15 --max-time 60 \
    'https://www.apache.org/licenses/LICENSE-2.0.txt' \
    --output "$stage/Summary/MODEL-LICENSE.txt"
print 'Qwen3-4B-Instruct-2507, Apache-2.0: https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507' > "$stage/Summary/MODEL-SOURCE.txt"
mkdir -p "$summary_support"
if [[ -e "$summary_support/Summary" ]]; then
    previous=$(mktemp -d "$summary_support/Summary-backup.XXXXXX")
    mv "$summary_support/Summary" "$previous/Summary"
fi
mv "$stage/Summary" "$summary_support/Summary"
print "Local summary model installed: $summary_support/Summary"
