#!/bin/zsh
# Include vendored notices from the exact upstream llama.cpp release as well.
set -euo pipefail
(( $# == 1 )) || exit 2
license_dir=${1:A}
mkdir -p "$license_dir"
paths=(
    licenses/LICENSE-jsonhpp
    vendor/cpp-httplib/LICENSE
    vendor/hash/rotate-bits/LICENSE.md
    vendor/hash/sha256/LICENSE
    vendor/hash/xxhash/LICENSE
    tools/ui/src/lib/vendors/big-integer/LICENSE
    tools/ui/src/lib/vendors/nerdamer-prime/LICENSE
)
names=(json-hpp cpp-httplib rotate-bits sha256 xxhash big-integer nerdamer-prime)
for (( i=1; i<=${#paths}; ++i )); do
    curl -fL --retry 3 --connect-timeout 15 --max-time 90 \
        "https://raw.githubusercontent.com/ggml-org/llama.cpp/b10809/${paths[$i]}" \
        -o "$license_dir/llama-vendor-${names[$i]}.txt"
done
# b10809/vendor/cpp-httplib/CMakeLists.txt pins this version for release builds.
curl -fL --retry 3 --connect-timeout 15 --max-time 90 \
    'https://raw.githubusercontent.com/google/boringssl/0.20260903.0/LICENSE' \
    -o "$license_dir/BoringSSL-LICENSE.txt"
