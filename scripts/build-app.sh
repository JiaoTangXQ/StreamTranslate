#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
cd "$project_root"

# A macOS 26 SDK and Swift 6 toolchain are sufficient; Xcode is optional.
swift_flags=()
if [[ "${REDACT_SOURCE_PATHS:-0}" == 1 ]]; then
    swift_flags=(-Xcc "-ffile-prefix-map=$project_root=/src/StreamTranslate"
                 -Xcxx "-ffile-prefix-map=$project_root=/src/StreamTranslate")
fi
swift build -c release --product StreamTranslate --disable-build-manifest-caching --jobs "${BUILD_JOBS:-4}" "${swift_flags[@]}"
bin_dir=$(swift build -c release --show-bin-path)
app="$project_root/build/StreamTranslate.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto "$bin_dir/StreamTranslate" "$app/Contents/MacOS/StreamTranslate"
ditto "$project_root/StreamTranslate/Resources/Info.plist" "$app/Contents/Info.plist"
icon="$project_root/StreamTranslate/Resources/StreamTranslate.icns"
[[ -s "$icon" ]] || { print -u2 "Missing app icon: $icon"; exit 1; }
ditto "$icon" "$app/Contents/Resources/StreamTranslate.icns"

plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDevelopmentRegion en' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable StreamTranslate' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.jiaotangxq.StreamTranslate' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName StreamTranslate' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.8.0' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 26' "$plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 26.0' "$plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$plist"

# Preserve any resources introduced by Swift package dependencies.
for resource in "$bin_dir"/*.bundle(N); do
    ditto "$resource" "$app/Contents/Resources/${resource:t}"
done
# Include notices for the exact certificate/ASN.1/crypto dependencies used by
# the Mac companion server. The iPhone target does not build X509.
license_dir="$app/Contents/Resources/Licenses"
mkdir -p "$license_dir"
for dependency in swift-certificates swift-asn1 swift-crypto; do
    for notice in LICENSE.txt NOTICE.txt; do
        source_notice="$project_root/.build/checkouts/$dependency/$notice"
        if [[ -f "$source_notice" ]]; then
            ditto "$source_notice" "$license_dir/$dependency-$notice"
        fi
    done
done
plutil -lint "$plist"
echo "Built app: $app"
