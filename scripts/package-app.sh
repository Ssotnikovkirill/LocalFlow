#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
package_id="${LOCALFLOW_PACKAGE_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
destination="${1:-${project_root}/dist/LocalFlow-${package_id}.zip}"
build_output="${project_root}/.build/localflow-package-${package_id}"
stage_root="${LOCALFLOW_STAGE_ROOT:-/private/tmp/LocalFlow-stage-${package_id}}"
staged_app="${stage_root}/LocalFlow.app"

if [[ -e "$destination" || -L "$destination" ]]; then
    print -u2 "Refusing to overwrite existing destination: $destination"
    exit 2
fi
if [[ -e "$stage_root" || -L "$stage_root" ]]; then
    print -u2 "Refusing to overwrite existing stage root: $stage_root"
    exit 2
fi

cd "$project_root"
LOCALFLOW_CONFIGURATION=release \
LOCALFLOW_BUILD_ID="$package_id" \
LOCALFLOW_BUILD_OUTPUT="$build_output" \
    "${script_dir}/build.sh"

executable="${build_output}/LocalFlow"
if [[ ! -x "$executable" ]]; then
    print -u2 "A built LocalFlow executable was not found."
    exit 4
fi

mkdir -p "$stage_root"
contents="${staged_app}/Contents"
mkdir -p "${contents}/MacOS" "${contents}/Resources"
ditto --norsrc --noextattr "$executable" "${contents}/MacOS/LocalFlow"
ditto --norsrc --noextattr \
    "${project_root}/Resources/Info.plist" \
    "${contents}/Info.plist"
ditto --norsrc --noextattr \
    "${project_root}/Resources/Models" \
    "${contents}/Resources/Models"
for resource in \
    THIRD-PARTY-NOTICES.md \
    MODEL-MANIFEST.json \
    LICENSE-whisper.cpp.txt \
    LICENSE-OpenAI-Whisper.txt
do
    ditto --norsrc --noextattr \
        "${project_root}/Resources/${resource}" \
        "${contents}/Resources/${resource}"
done
find "${contents}/Resources" -type d -exec chmod 0755 {} +
find "${contents}/Resources" -type f -exec chmod 0644 {} +
chmod 755 "${contents}/MacOS/LocalFlow"

plutil -lint "${contents}/Info.plist"
codesign \
    --sign - \
    --options runtime \
    --entitlements "${project_root}/Resources/LocalFlow.entitlements" \
    "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

mkdir -p "${destination:h}"
ditto \
    --norsrc \
    --noextattr \
    -c -k \
    --keepParent \
    "$staged_app" \
    "$destination"
unzip -t "$destination"

print "Signed app stage: $staged_app"
print "Packaged: $destination"
