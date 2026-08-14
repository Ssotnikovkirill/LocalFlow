#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
localflow_configuration="${LOCALFLOW_CONFIGURATION:-release}"
localflow_build_id="${LOCALFLOW_BUILD_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
localflow_output="${LOCALFLOW_BUILD_OUTPUT:-${project_root}/.build/localflow-direct-${localflow_build_id}}"

cd "$project_root"
if [[ "${LOCALFLOW_USE_SWIFTPM:-0}" == "1" ]]; then
    localflow_scratch="${project_root}/.build/swiftpm-${localflow_build_id}"
    if [[ -e "$localflow_scratch" ]]; then
        print -u2 "Refusing to reuse build directory: $localflow_scratch"
        exit 2
    fi
    swift build \
        --scratch-path "$localflow_scratch" \
        --configuration "$localflow_configuration" \
        --product LocalFlow
    print "LOCALFLOW_BINARY=${localflow_scratch}/${localflow_configuration}/LocalFlow"
    exit 0
fi

LOCALFLOW_BUILD_OUTPUT="$localflow_output" \
    "${script_dir}/build-direct-clt-workaround.sh"
