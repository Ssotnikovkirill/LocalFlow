#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
build_id="${LOCALFLOW_BUILD_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
output_directory="${LOCALFLOW_BUILD_OUTPUT:-${project_root}/.build/localflow-direct-${build_id}}"
overlay="${project_root}/Validation/clt-modulemap-overlay.yaml"
localflow_configuration="${LOCALFLOW_CONFIGURATION:-release}"
whisper_vendor="${project_root}/Vendor/WhisperCPP-macos13.3"

if [[ ! -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap \
    || ! -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]
then
    print -u2 "The known duplicate SwiftBridging CLT condition was not found."
    exit 3
fi

if [[ -e "$output_directory" ]]; then
    print -u2 "Refusing to overwrite build directory: $output_directory"
    exit 2
fi
mkdir -p "$output_directory"
cd "$project_root"

localflow_optimization=()
if [[ "$localflow_configuration" == "release" ]]; then
    localflow_optimization=(-O)
fi

xcrun swiftc \
    -vfsoverlay "$overlay" \
    -target arm64-apple-macosx13.3 \
    -swift-version 5 \
    -parse-as-library \
    -emit-library \
    -static \
    -emit-module \
    -module-name LocalFlowCore \
    "${localflow_optimization[@]}" \
    Sources/LocalFlowCore/*.swift \
    -emit-module-path "${output_directory}/LocalFlowCore.swiftmodule" \
    -o "${output_directory}/libLocalFlowCore.a"

xcrun clang++ \
    -std=c++17 \
    -arch arm64 \
    -mmacosx-version-min=13.3 \
    -O3 \
    -I Sources/CWhisperBridge/include \
    -I "${whisper_vendor}/include" \
    -I "${whisper_vendor}/ggml-include" \
    -c Sources/CWhisperBridge/LocalFlowWhisperBridge.cpp \
    -o "${output_directory}/LocalFlowWhisperBridge.o"

xcrun swiftc \
    -vfsoverlay "$overlay" \
    -target arm64-apple-macosx13.3 \
    -swift-version 5 \
    -parse-as-library \
    -I "$output_directory" \
    -I Sources/CWhisperBridge/include \
    -L "$output_directory" \
    -lLocalFlowCore \
    -L "${whisper_vendor}/lib" \
    -lwhisper \
    -lggml \
    -lggml-cpu \
    -lggml-blas \
    -lggml-metal \
    -lggml-base \
    -lc++ \
    -framework Accelerate \
    -framework Carbon \
    -framework Foundation \
    -framework Metal \
    -framework MetalKit \
    "${localflow_optimization[@]}" \
    -warnings-as-errors \
    "${output_directory}/LocalFlowWhisperBridge.o" \
    Sources/LocalFlowApp/*.swift \
    Sources/LocalFlowApp/Insertion/*.swift \
    Sources/LocalFlowApp/HotKey/*.swift \
    Sources/LocalFlowApp/Overlay/*.swift \
    Sources/LocalFlowApp/Permissions/*.swift \
    Sources/LocalFlowApp/Privacy/*.swift \
    Sources/LocalFlowApp/Settings/*.swift \
    Sources/LocalFlowApp/Speech/*.swift \
    Sources/LocalFlowApp/StatusBar/*.swift \
    -o "${output_directory}/LocalFlow"

print "Direct CLT-workaround build: ${output_directory}/LocalFlow"
print "LOCALFLOW_BINARY=${output_directory}/LocalFlow"
