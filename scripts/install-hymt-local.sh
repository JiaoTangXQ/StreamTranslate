#!/bin/zsh
set -euo pipefail
if (( $# != 2 )); then
    print -u2 'usage: install-hymt-local.sh <llama.cpp-runtime-directory> <Hy-MT2-model.gguf>'
    exit 2
fi
runtime_dir=${1:A}
model_file=${2:A}
support_dir="$HOME/Library/Application Support/StreamTranslate/HyMT"
[[ -x "$runtime_dir/llama-server" && -s "$model_file" ]]
stage=$(mktemp -d "${TMPDIR:-/tmp}/streamtranslate-hymt.XXXXXX")
trap 'find "$stage" -depth -delete 2>/dev/null || true' EXIT
mkdir -p "$stage/HyMT/runtime"
ditto "$runtime_dir/llama-server" "$stage/HyMT/runtime/llama-server"
ditto "$runtime_dir/libllama-server-impl.dylib" "$stage/HyMT/runtime/libllama-server-impl.dylib"
for library in "$runtime_dir/"*.0.dylib; do
    ditto "$library" "$stage/HyMT/runtime/${library:t}"
done
ditto "$runtime_dir/LICENSE" "$stage/HyMT/runtime/LICENSE"
for binary in "$stage/HyMT/runtime/"*.dylib "$stage/HyMT/runtime/llama-server"; do
    codesign --force --sign 'StreamTranslate Local Code Signing' "$binary"
    codesign --verify --strict "$binary"
done
ln -s "$model_file" "$stage/HyMT/model.gguf"
mkdir -p "${support_dir:h}"
if [[ -e "$support_dir" ]]; then
    backup_dir=$(mktemp -d "${support_dir:h}/HyMT-backup.XXXXXX")
    mv "$support_dir" "$backup_dir/HyMT"
    print -r -- "Previous runtime retained: $backup_dir/HyMT"
fi
mv "$stage/HyMT" "$support_dir"
print -r -- "Local translation runtime installed: $support_dir"
print -r -- "Model location (keep this disk connected): $model_file"
