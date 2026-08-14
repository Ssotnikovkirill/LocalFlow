#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
verification_id="${LOCALFLOW_VERIFY_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
output_directory="${project_root}/.build/localflow-verify-${verification_id}"

cd "$project_root"
LOCALFLOW_BUILD_ID="$verification_id" \
LOCALFLOW_BUILD_OUTPUT="$output_directory" \
    "${script_dir}/build.sh"

if [[ "${LOCALFLOW_RUN_SWIFTPM_TESTS:-0}" == "1" ]]; then
    scratch="${project_root}/.build/swiftpm-tests-${verification_id}"
    test ! -e "$scratch"
    swift test --scratch-path "$scratch" --parallel
fi

overlay="${project_root}/Validation/clt-modulemap-overlay.yaml"
xcrun swiftc \
    -vfsoverlay "$overlay" \
    -target arm64-apple-macosx13.3 \
    -swift-version 5 \
    -parse-as-library \
    -I "$output_directory" \
    -L "$output_directory" \
    -lLocalFlowCore \
    Validation/CoreLogicSmokeTests.swift \
    -o "${output_directory}/CoreLogicSmokeTests"

"${output_directory}/CoreLogicSmokeTests"
"${output_directory}/CoreLogicSmokeTests"
"${output_directory}/CoreLogicSmokeTests"

plutil -lint Resources/Info.plist
plutil -lint Resources/LocalFlow.entitlements
