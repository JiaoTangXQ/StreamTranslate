#!/bin/zsh
# Install a locally built, pinned native runtime; never needs Python at app runtime.
set -euo pipefail
if (( $# != 3 )); then
    print -u2 'usage: install-qwen-local.sh <qwen-cpp-source> <qwen-cpp-build> <model.gguf>'
    exit 2
fi
source_dir=${1:A}
library_dir=${2:A}
model_file=${3:A}
script_dir=${0:A:h}
project_root=${script_dir:h}
support_dir="$HOME/Library/Application Support/StreamTranslate/Qwen"
[[ -f "$source_dir/include/qwen3_asr.h" && -f "$library_dir/libqwen3-asr.dylib" && -s "$model_file" ]]
stage=$(mktemp -d "${TMPDIR:-/tmp}/streamtranslate-qwen.XXXXXX")
trap 'find "$stage" -depth -delete 2>/dev/null || true' EXIT
mkdir -p "$stage/Qwen/runtime" "$stage/Qwen/licenses"
for name in libqwen3-asr.dylib libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib; do
    ditto "$library_dir/$name" "$stage/Qwen/runtime/$name"
    if otool -l "$stage/Qwen/runtime/$name" | rg -F -q "$library_dir"; then
        install_name_tool -delete_rpath "$library_dir" "$stage/Qwen/runtime/$name"
    fi
    install_name_tool -add_rpath '@loader_path' "$stage/Qwen/runtime/$name"
done
clang++ -std=c++17 -O3 "$project_root/Native/QwenHelper/main.cpp" \
    -I "$source_dir/include" -I "$source_dir/src" -I "$source_dir/ggml/include" \
    -L "$library_dir" -lqwen3-asr -Wl,-rpath,@executable_path \
    -o "$stage/Qwen/runtime/QwenHelper"
ditto "$source_dir/LICENSE" "$stage/Qwen/licenses/qwen3-asr-cpp.txt"
ditto "$source_dir/ggml/LICENSE" "$stage/Qwen/licenses/ggml.txt"
for binary in "$stage/Qwen/runtime/"*; do
    codesign --force --sign 'StreamTranslate Local Code Signing' "$binary"
    codesign --verify --strict "$binary"
done
# Link deliberately: no second 1.35 GB copy on a nearly full internal SSD.
ln -s "$model_file" "$stage/Qwen/model.gguf"
mkdir -p "${support_dir:h}"
if [[ -e "$support_dir" ]]; then
    backup_dir=$(mktemp -d "${support_dir:h}/Qwen-backup.XXXXXX")
    mv "$support_dir" "$backup_dir/Qwen"
    print -r -- "Previous runtime retained: $backup_dir/Qwen"
fi
mv "$stage/Qwen" "$support_dir"
print -r -- "Native runtime installed: $support_dir"
print -r -- "Model location (keep this disk connected): $model_file"
