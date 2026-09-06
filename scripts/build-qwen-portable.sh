#!/bin/zsh
# Build without the host-specific M4 instructions used by local benchmarks.
set -euo pipefail
(( $# == 2 )) || { print -u2 'usage: build-qwen-portable.sh <qwen-source> <output-directory>'; exit 2; }
source_dir=${1:A}
output_dir=${2:A}
script_dir=${0:A:h}
project_root=${script_dir:h}
cmake_bin="${CMAKE_BIN:-$project_root/build/verification/venv/bin/cmake}"
[[ -x "$cmake_bin" ]] || cmake_bin=cmake
[[ -f "$source_dir/include/qwen3_asr.h" ]] || { print -u2 'Pinned qwen3-asr.cpp source is required'; exit 1; }
if [[ -e "$source_dir/.git" ]]; then
    [[ $(git -C "$source_dir" rev-parse HEAD) == 6dcc586e5073fd6e85ee5728e75f0903d6c70c6c ]]
fi
# Source archives have no .git; their provenance is recorded in NOTICE.txt.
# Do not let git walk up into the unrelated StreamTranslate repository.
mkdir -p "$output_dir/runtime" "$output_dir/licenses"
library_dir="$output_dir/build"
# Upstream unconditionally appends -march=native to Release. Use the other
# configuration with explicitly optimized, no-debug flags instead of editing it.
"$cmake_bin" -S "$source_dir" -B "$library_dir" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    '-DCMAKE_C_FLAGS_RELWITHDEBINFO=-O3 -DNDEBUG -mcpu=apple-m1' \
    '-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=-O3 -DNDEBUG -mcpu=apple-m1' \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DGGML_NATIVE=OFF '-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16' \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DQWEN3_ASR_TEST=OFF
if rg -q -- '-m(arch|cpu)=native|\+i8mm|\+sme' "$library_dir/compile_commands.json"; then
    print -u2 'Refusing non-portable CPU compilation flags'; exit 1
fi
"$cmake_bin" --build "$library_dir" --target qwen3-asr -j "${BUILD_JOBS:-4}"
for name in libqwen3-asr.dylib libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib; do
    ditto --norsrc --noextattr "$library_dir/$name" "$output_dir/runtime/$name"
    if otool -l "$output_dir/runtime/$name" | rg -F -q "$library_dir"; then
        install_name_tool -delete_rpath "$library_dir" "$output_dir/runtime/$name"
    fi
    install_name_tool -add_rpath '@loader_path' "$output_dir/runtime/$name"
done
clang++ -std=c++17 -O3 -mcpu=apple-m1 -mmacosx-version-min=26.0 \
    "$project_root/Native/QwenHelper/main.cpp" \
    -I "$source_dir/include" -I "$source_dir/src" -I "$source_dir/ggml/include" \
    -L "$library_dir" -lqwen3-asr -Wl,-rpath,@executable_path -o "$output_dir/runtime/QwenHelper"
ditto "$source_dir/LICENSE" "$output_dir/licenses/qwen3-asr-cpp.txt"
ditto "$source_dir/ggml/LICENSE" "$output_dir/licenses/ggml.txt"
print -r -- "Portable Qwen runtime (sign after copying to HFS+/APFS): $output_dir/runtime"
