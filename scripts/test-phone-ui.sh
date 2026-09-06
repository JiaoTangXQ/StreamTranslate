#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
project_root=${script_dir:h}
cd "$project_root"

[[ -n "${IOS_SIMULATOR_ID:-}" ]] || {
    print -u2 '设置 IOS_SIMULATOR_ID 为专用测试模拟器 UUID；用 xcrun simctl list devices available 查看。'
    exit 2
}
xcodebuild -checkFirstLaunchStatus
# Let CoreSimulator finish first-boot migration before XCTest attaches.
# Only the explicitly selected test device is booted or reset by this script.
xcrun simctl bootstatus "$IOS_SIMULATOR_ID" -b
generator="${XCODEGEN_PATH:-$project_root/build/tools/XcodeGen-2.46.0/xcodegen/bin/xcodegen}"
if [[ -z "${XCODEGEN_PATH:-}" ]] && command -v xcodegen >/dev/null 2>&1; then generator=$(command -v xcodegen); fi
[[ -x "$generator" ]] || { print -u2 '请安装 XcodeGen 或设置 XCODEGEN_PATH。'; exit 2; }
"$generator" generate --spec project.yml
derived_data="${IOS_DERIVED_DATA_PATH:-$project_root/build/phone-simulator}"
results="${IOS_TEST_RESULTS_PATH:-$project_root/build/phone-ui-$(date +%Y%m%d-%H%M%S).xcresult}"
[[ ! -e "$results" ]] || { print -u2 "测试结果路径已存在，拒绝覆盖：$results"; exit 2; }

# The reset launch flag only exists in simulator Debug builds. These tests
# use synthetic/unpaired state and do not require an Apple signing account.
xcodebuild test -project StreamTranslate.xcodeproj -scheme StreamTranslatePhone \
    -configuration Debug -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_ID" \
    -derivedDataPath "$derived_data" -resultBundlePath "$results" \
    -jobs "${BUILD_JOBS:-2}" -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES
