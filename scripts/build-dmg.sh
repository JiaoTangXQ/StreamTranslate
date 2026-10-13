#!/bin/zsh
# Build a full, relocatable Apple Silicon distribution; no user data is copied.
set -euo pipefail
if (( $# != 1 )); then
    print -u2 'usage: zsh scripts/build-dmg.sh <output-directory-with-at-least-10GB-free>'
    exit 2
fi
script_dir=${0:A:h}
project_root=${script_dir:h}
output_dir=${1:A}
support_dir="${MODEL_SUPPORT_DIR:-$HOME/Library/Application Support/StreamTranslate}"
identity="${SIGN_IDENTITY:-StreamTranslate Local Code Signing}"
mkdir -p "$output_dir"
free_kb=$(df -k "$output_dir" | tail -1 | awk '{print $4}')
(( free_kb > 10 * 1024 * 1024 )) || { print -u2 'Need at least 10 GiB free in output directory'; exit 1; }
cd "$project_root"
REDACT_SOURCE_PATHS=1 zsh scripts/build-app.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/StreamTranslate.app/Contents/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/StreamTranslate.app/Contents/Info.plist)
label=Local-Unnotarized
sign_options=(--force --sign "$identity")
if [[ "$identity" == 'Developer ID Application:'* ]]; then
    label=DeveloperID-Unnotarized
    sign_options+=(--options runtime --timestamp)
else
    sign_options+=(--timestamp=none)
fi
[[ -z "${NOTARY_PROFILE:-}" || "$label" == DeveloperID-Unnotarized ]] || {
    print -u2 'Notarization requires SIGN_IDENTITY="Developer ID Application: ..."'; exit 1
}
stem="StreamTranslate-${version}-${build}-AppleSilicon-${label}"
dmg="$output_dir/$stem.dmg"
[[ ! -e "$dmg" && ! -e "$output_dir/$stem.audit.json" ]] || { print -u2 'Refusing to overwrite an existing release'; exit 1; }
stage=$(mktemp -d "$output_dir/dmg-stage.XXXXXX")
# Retain staging on success or failure for inspection; never remove user data.
print -r -- "Staging retained at: $stage"
# ExFAT creates AppleDouble files and lacks native executable permissions.
# Keep the actual bundle on HFS+ even when the output disk is ExFAT.
mount_dir=$(mktemp -d /tmp/streamtranslate-dmg-stage.XXXXXX)
mounted=0
cleanup_mount() {
    if (( mounted )); then hdiutil detach "$mount_dir" || true; fi
    rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup_mount EXIT
hdiutil create -size 4g -type SPARSE -fs HFS+ -volname StreamTranslateStage "$stage/staging.sparseimage"
hdiutil attach -nobrowse -mountpoint "$mount_dir" "$stage/staging.sparseimage"
mounted=1
zsh scripts/build-qwen-portable.sh "${QWEN_SOURCE_DIR:-$project_root/build/refinement/qwen-cpp-src}" "$stage/qwen-portable"
qwen_runtime="$stage/qwen-portable/runtime"
payload="$mount_dir/payload"
app="$payload/StreamTranslate.app"
mkdir -p "$payload"
ditto --norsrc --noextattr build/StreamTranslate.app "$app"
strip -S -x "$app/Contents/MacOS/StreamTranslate"
mkdir -p "$app/Contents/Helpers/Qwen" "$app/Contents/Helpers/HyMT" \
    "$app/Contents/Resources/Models" "$app/Contents/Resources/Licenses"
for name in Qwen HyMT; do
    [[ -s "$support_dir/$name/model.gguf" ]] || { print -u2 "Missing $name model"; exit 1; }
    # Resolve explicitly: never ship the development symlink to PortableSSD.
    model_file=${support_dir}/${name}/model.gguf
    ditto --norsrc --noextattr "${model_file:A}" "$app/Contents/Resources/Models/$name.gguf"
done
ditto --norsrc --noextattr "$qwen_runtime/QwenHelper" "$app/Contents/Helpers/Qwen/QwenHelper"
for binary in "$qwen_runtime/"*.dylib; do
    ditto --norsrc --noextattr "${binary:A}" "$app/Contents/Helpers/Qwen/${binary:t}"
done
for binary in "$support_dir/HyMT/runtime/"*.0.dylib \
    "$support_dir/HyMT/runtime/libllama-server-impl.dylib" "$support_dir/HyMT/runtime/llama-server"; do
    ditto --norsrc --noextattr "${binary:A}" "$app/Contents/Helpers/HyMT/${binary:t}"
done
licenses="$app/Contents/Resources/Licenses"
ditto LICENSE "$licenses/StreamTranslate-MIT.txt"
ditto docs/distribution-notices.txt "$licenses/NOTICE.txt"
ditto "$stage/qwen-portable/licenses" "$licenses"
ditto "$support_dir/HyMT/runtime/LICENSE" "$licenses/llama-cpp-MIT.txt"
ditto .build/checkouts/argmax-oss-swift/LICENSE "$licenses/Argmax-MIT.txt"
ditto .build/checkouts/argmax-oss-swift/NOTICES "$licenses/Argmax-NOTICES.txt"
ditto .build/checkouts/swift-argument-parser/LICENSE.txt "$licenses/Swift-Argument-Parser-LICENSE.txt"
curl -fL --retry 3 'https://www.apache.org/licenses/LICENSE-2.0.txt' -o "$licenses/Apache-2.0.txt"
curl -fL --retry 3 'https://huggingface.co/Qwen/Qwen3-ASR-0.6B/resolve/5eb144179a02acc5e5ba31e748d22b0cf3e303b0/README.md' -o "$licenses/Qwen-model-card.md"
curl -fL --retry 3 'https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/1cd5208700acedef4ef93019b6cfc148b8522d45/LICENSE.txt' -o "$licenses/HyMT-Apache-2.0.txt"
curl -fL --retry 3 'https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/1cd5208700acedef4ef93019b6cfc148b8522d45/README.md' -o "$licenses/HyMT-model-card.md"
zsh scripts/collect-runtime-licenses.sh "$licenses"
chmod -R u+rwX,go+rX "$app"
chmod 644 "$app/Contents/Resources/Models/"*.gguf
for binary in "$app/Contents/Helpers/"*/*; do
    chmod 755 "$binary"
    codesign "${sign_options[@]}" "$binary"
done
codesign "${sign_options[@]}" --entitlements StreamTranslate/Resources/StreamTranslate.entitlements "$app"
/usr/bin/python3 Tools/verify_distribution.py "$app" > "$output_dir/$stem.audit.json"
ditto docs/dmg-install-zh.txt "$payload/安装说明.txt"
ln -s /Applications "$payload/Applications"
hdiutil create -volname 'StreamTranslate' -srcfolder "$payload" -format UDZO \
    -imagekey zlib-level=6 -fs HFS+ "$dmg"
if [[ "$identity" == 'Developer ID Application:'* ]]; then
    codesign "${sign_options[@]}" "$dmg"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    # Never leave a failed submission named "Notarized".
    signed_stem="StreamTranslate-${version}-${build}-AppleSilicon-Notarized"
    [[ ! -e "$output_dir/$signed_stem.dmg" && ! -e "$output_dir/$signed_stem.audit.json" ]]
    mv "$dmg" "$output_dir/$signed_stem.dmg"
    mv "$output_dir/$stem.audit.json" "$output_dir/$signed_stem.audit.json"
    stem="$signed_stem"
    dmg="$output_dir/$stem.dmg"
    label=Notarized
fi
hdiutil verify "$dmg"
(cd "$output_dir" && shasum -a 256 "${dmg:t}" > "$stem.dmg.sha256")
print -r -- "DMG: $dmg"
print -r -- "Signing status: $label (local signing does not confer Gatekeeper trust)"
