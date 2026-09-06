#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
project_root=${script_dir:h}
cd "$project_root"

if ! xcodebuild -version >/dev/null 2>&1; then
    print -u2 '需要完整 Xcode 和 iOS SDK；当前 Command Line Tools 无法生成 iPhone 安装包。'
    print -u2 '安装 Xcode 后启动一次并安装 iOS 平台，再选择其 Developer 目录。'
    exit 2
fi
generator="${XCODEGEN_PATH:-$project_root/build/tools/XcodeGen-2.46.0/xcodegen/bin/xcodegen}"
if [[ -z "${XCODEGEN_PATH:-}" ]] && command -v xcodegen >/dev/null 2>&1; then generator=$(command -v xcodegen); fi
[[ -x "$generator" ]] || { print -u2 '需要 XcodeGen 2.40+；安装后重试或设置 XCODEGEN_PATH。'; exit 2; }
"$generator" generate --spec project.yml
destination="${IOS_DESTINATION:-generic/platform=iOS}"
derived_data="${IOS_DERIVED_DATA_PATH:-$project_root/build/phone-derived}"
# Direct target builds can use the installed iPhoneOS SDK without a simulator
# runtime. Scheme destination validation in Xcode 26.6 otherwise rejects even
# generic iOS when no runtime has been installed. This is still a real Xcode
# arm64/iPhoneOS build, but it is unsigned and cannot be installed on a phone.
# For real-device signing, use Xcode with your own Team and provisioning profile.
if [[ "$destination" == 'generic/platform=iOS' ]]; then
    xcodebuild -project StreamTranslate.xcodeproj -target StreamTranslatePhone \
        -sdk iphoneos -configuration Debug \
        -clonedSourcePackagesDirPath "$derived_data/SourcePackages" \
        -jobs "${BUILD_JOBS:-4}" \
        SYMROOT="$derived_data/Build/Products" \
        OBJROOT="$derived_data/Build/Intermediates" \
        CLANG_MODULE_CACHE_PATH="$derived_data/ModuleCache" \
        CODE_SIGNING_ALLOWED=NO build
else
    xcodebuild -project StreamTranslate.xcodeproj -scheme StreamTranslatePhone \
        -configuration Debug -destination "$destination" \
        -derivedDataPath "$derived_data" -jobs "${BUILD_JOBS:-4}" \
        CODE_SIGNING_ALLOWED=NO build
fi
