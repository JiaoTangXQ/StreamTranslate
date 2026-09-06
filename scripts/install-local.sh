#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
signing_name="StreamTranslate Local Code Signing"
destination="/Applications/StreamTranslate.app"
backup="/Applications/StreamTranslate.app.previous"

cd "$project_root"
if ! xcodebuild -version >/dev/null 2>&1; then
    "$script_dir/build-app.sh"
    built_app="$project_root/build/StreamTranslate.app"
else
    if [[ ! -d StreamTranslate.xcodeproj ]]; then
        xcodegen generate
    fi
    xcodebuild build \
        -project StreamTranslate.xcodeproj \
        -scheme StreamTranslate \
        -destination 'platform=macOS' \
        -configuration Release

    build_settings=$(xcodebuild -showBuildSettings \
        -project StreamTranslate.xcodeproj \
        -scheme StreamTranslate \
        -destination 'platform=macOS' \
        -configuration Release)
    target_build_dir=$(print -r -- "$build_settings" \
        | awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }')
    wrapper_name=$(print -r -- "$build_settings" \
        | awk -F ' = ' '/^[[:space:]]*WRAPPER_NAME = / { print $2; exit }')
    built_app="$target_build_dir/$wrapper_name"
fi

if [[ ! -d "$built_app" ]]; then
    echo "Built application not found: $built_app" >&2
    exit 1
fi

"$script_dir/setup-local-signing.sh"
identity_hash=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -v needle="\"$signing_name\"" 'index($0, needle) { print $2; exit }')
if [[ -z "$identity_hash" ]]; then
    echo "Missing valid signing identity: $signing_name" >&2
    exit 1
fi

install_tmp=$(mktemp -d)
cleanup() {
    find "$install_tmp" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

staged_app="$install_tmp/StreamTranslate.app"
ditto "$built_app" "$staged_app"
codesign --force --deep \
    --sign "$identity_hash" \
    --entitlements "$project_root/StreamTranslate/Resources/StreamTranslate.entitlements" \
    "$staged_app"
codesign --verify --deep --strict "$staged_app"

designated_requirement=$(codesign -dr - "$staged_app" 2>&1)
if [[ "$designated_requirement" == *'designated => cdhash'* ]]; then
    echo "Refusing to install an app with an unstable ad-hoc requirement." >&2
    exit 1
fi

osascript -e 'tell application id "com.jiaotangxq.StreamTranslate" to quit' 2>/dev/null || true
for _ in {1..20}; do
    pgrep -x StreamTranslate >/dev/null || break
    sleep 0.25
done
if pgrep -x StreamTranslate >/dev/null; then
    echo "StreamTranslate did not quit; installation stopped." >&2
    exit 1
fi

if [[ -e "$backup" ]]; then
    # Keep earlier rollback copies instead of silently deleting the last one.
    mkdir -p "$project_root/build/app-backups"
    archived_backup=$(mktemp -d "$project_root/build/app-backups/install.XXXXXX")
    mv "$backup" "$archived_backup/StreamTranslate.app"
fi
if [[ -e "$destination" ]]; then
    mv "$destination" "$backup"
fi

restore_previous() {
    if [[ ! -e "$destination" && -e "$backup" ]]; then
        mv "$backup" "$destination"
    fi
}
trap 'restore_previous; cleanup' EXIT

mv "$staged_app" "$destination"
codesign --verify --deep --strict "$destination"
open -a "$destination"

for _ in {1..20}; do
    pgrep -x StreamTranslate >/dev/null && break
    sleep 0.25
done
if ! pgrep -x StreamTranslate >/dev/null; then
    find "$destination" -depth -delete
    restore_previous
    echo "The signed application did not launch; restored the previous version." >&2
    exit 1
fi

trap cleanup EXIT
echo "Installed signed StreamTranslate at $destination"
if [[ -e "$backup" ]]; then
    echo "Previous version retained at $backup"
fi
print -r -- "$designated_requirement"
