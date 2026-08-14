#!/bin/zsh
set -euo pipefail
setopt NO_CLOBBER

script_dir="${0:A:h}"
project_root="${script_dir:h}"
release_id="${LOCALFLOW_RELEASE_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

case "$release_id" in
    ("" | *[!A-Za-z0-9._-]*)
        print -u2 "Release ID must contain only letters, digits, '.', '_' or '-'."
        exit 2
        ;;
esac

destination="${1:-${project_root}/dist/LocalFlow-release-gate-${release_id}.zip}"
gate_root="${LOCALFLOW_RELEASE_ROOT:-${project_root}/.build/localflow-release-gate-${release_id}}"
verify_id="${release_id}-core"
package_id="${release_id}-package"
verify_output="${project_root}/.build/localflow-verify-${verify_id}"
swiftpm_test_output="${project_root}/.build/swiftpm-tests-${verify_id}"
package_output="${project_root}/.build/localflow-package-${package_id}"
stage_root="${LOCALFLOW_RELEASE_STAGE_ROOT:-/private/tmp/LocalFlow-release-stage-${release_id}}"
extract_root="${LOCALFLOW_RELEASE_EXTRACT_ROOT:-/private/tmp/LocalFlow-release-extract-${release_id}}"
extracted_app="${extract_root}/LocalFlow.app"
executable="${extracted_app}/Contents/MacOS/LocalFlow"
resources="${extracted_app}/Contents/Resources"

die() {
    print -u2 -r -- "release-gate: $*"
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 \
        || die "required tool is unavailable: $1"
}

require_absent() {
    if [[ -e "$1" || -L "$1" ]]; then
        die "refusing to overwrite existing path: $1"
    fi
}

check_mode() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(/usr/bin/stat -f "%Lp" "$path")"
    [[ "$actual" == "$expected" ]] \
        || die "wrong mode for $path: expected $expected, got $actual"
}

validate_pcm() {
    local path="$1"
    local label="$2"
    local byte_count

    [[ -f "$path" && ! -L "$path" && -r "$path" ]] \
        || die "$label PCM is not a readable regular file: $path"
    byte_count="$(/usr/bin/stat -f "%z" "$path")"
    (( byte_count > 0 && byte_count % 4 == 0 )) \
        || die "$label PCM must be non-empty Float32 data: $path"
}

require_output_line() {
    local path="$1"
    local expected="$2"
    /usr/bin/grep -Fq -- "$expected" "$path" \
        || die "self-test output is missing: $expected"
}

for required_tool in \
    awk \
    codesign \
    ditto \
    find \
    grep \
    lipo \
    otool \
    python3 \
    shasum \
    sort \
    stat \
    tee \
    uniq \
    unzip \
    wc \
    xcrun
do
    require_tool "$required_tool"
done

vtool="$(xcrun --find vtool)" \
    || die "vtool is unavailable through xcrun"

for reserved_path in \
    "$destination" \
    "$gate_root" \
    "$verify_output" \
    "$swiftpm_test_output" \
    "$package_output" \
    "$stage_root" \
    "$extract_root"
do
    require_absent "$reserved_path"
done

mkdir "$gate_root"
verify_log="${gate_root}/core-verification.log"
package_log="${gate_root}/packaging.log"
zip_test_log="${gate_root}/zip-integrity.log"
archive_list="${gate_root}/archive-entries.txt"
selftest_log="${gate_root}/bundled-self-test.log"
corpus_report="${gate_root}/strict-corpus-report.json"
corpus_error_log="${gate_root}/strict-corpus-stderr.log"
auto_report="${gate_root}/strict-auto-report.json"
auto_error_log="${gate_root}/strict-auto-stderr.log"
: > "$verify_log"
: > "$package_log"
: > "$zip_test_log"

print "Release gate ID: $release_id"
print "1/10 Core verification (three independent smoke runs)"
if ! (
    cd "$project_root"
    LOCALFLOW_CONFIGURATION=release \
    LOCALFLOW_RUN_SWIFTPM_TESTS="${LOCALFLOW_RELEASE_RUN_SWIFTPM_TESTS:-0}" \
    LOCALFLOW_USE_SWIFTPM=0 \
    LOCALFLOW_VERIFY_ID="$verify_id" \
        "${script_dir}/verify.sh" 2>&1
) | /usr/bin/tee -a "$verify_log"
then
    die "core verification failed; see $verify_log"
fi

core_pass_count="$(
    /usr/bin/grep -c "^CoreLogicSmokeTests: PASS$" "$verify_log" || true
)"
[[ "$core_pass_count" == "3" ]] \
    || die "expected exactly three core smoke passes, got $core_pass_count"

print "2/10 Build, sign and package into reserved paths"
if ! (
    cd "$project_root"
    LOCALFLOW_PACKAGE_ID="$package_id" \
    LOCALFLOW_STAGE_ROOT="$stage_root" \
    LOCALFLOW_USE_SWIFTPM=0 \
        "${script_dir}/package-app.sh" "$destination" 2>&1
) | /usr/bin/tee -a "$package_log"
then
    die "packaging failed; see $package_log"
fi
[[ -f "$destination" && ! -L "$destination" ]] \
    || die "package was not created as a regular ZIP: $destination"

print "3/10 ZIP integrity and safe single-root layout"
if ! /usr/bin/unzip -t "$destination" 2>&1 \
    | /usr/bin/tee -a "$zip_test_log"
then
    die "ZIP integrity check failed; see $zip_test_log"
fi

/usr/bin/unzip -Z1 "$destination" > "$archive_list"
[[ -s "$archive_list" ]] || die "ZIP has no entries"

duplicate_entries="$(
    /usr/bin/sort "$archive_list" | /usr/bin/uniq -d
)"
[[ -z "$duplicate_entries" ]] \
    || die "ZIP contains duplicate entries: $duplicate_entries"

while IFS= read -r archive_entry; do
    [[ -n "$archive_entry" ]] || die "ZIP contains an empty entry name"
    case "$archive_entry" in
        (/* | ../* | */../* | */..)
            die "ZIP contains an unsafe path: $archive_entry"
            ;;
        (LocalFlow.app | LocalFlow.app/*)
            ;;
        (*)
            die "ZIP contains an unexpected root entry: $archive_entry"
            ;;
    esac
done < "$archive_list"

/usr/bin/grep -Fxq "LocalFlow.app/Contents/MacOS/LocalFlow" \
    "$archive_list" \
    || die "ZIP does not contain the LocalFlow executable"

mkdir "$extract_root"
/usr/bin/ditto -x -k "$destination" "$extract_root"
[[ -d "$extracted_app" && ! -L "$extracted_app" ]] \
    || die "extracted LocalFlow.app is missing or is a symlink"

top_level_count="$(
    /usr/bin/find "$extract_root" -mindepth 1 -maxdepth 1 -print \
        | /usr/bin/wc -l \
        | /usr/bin/awk '{ print $1 }'
)"
[[ "$top_level_count" == "1" ]] \
    || die "extracted ZIP must contain exactly one top-level item"

unexpected_symlink="$(
    /usr/bin/find "$extracted_app" -type l -print -quit
)"
[[ -z "$unexpected_symlink" ]] \
    || die "bundle contains an unexpected symlink: $unexpected_symlink"

print "4/10 Bundle signature and executable metadata"
[[ -x "$executable" && -f "$executable" && ! -L "$executable" ]] \
    || die "extracted executable is missing or is not executable"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$extracted_app"

architectures="$(/usr/bin/lipo -archs "$executable")"
[[ "$architectures" == "arm64" ]] \
    || die "executable must be thin arm64, got: $architectures"

info_plist="${extracted_app}/Contents/Info.plist"
/usr/bin/plutil -lint "$info_plist"
plist_minimum="$(
    /usr/libexec/PlistBuddy \
        -c "Print :LSMinimumSystemVersion" \
        "$info_plist"
)"
binary_minimum="$(
    "$vtool" -show-build "$executable" \
        | /usr/bin/awk '$1 == "minos" { print $2; exit }'
)"
[[ "$plist_minimum" == "13.3" ]] \
    || die "Info.plist minimum macOS must be 13.3, got: $plist_minimum"
[[ "$binary_minimum" == "$plist_minimum" ]] \
    || die \
        "binary minimum macOS ($binary_minimum) differs from Info.plist ($plist_minimum)"

print "5/10 System-only dynamic dependencies"
dependencies="$(
    /usr/bin/otool -L "$executable" \
        | /usr/bin/awk 'NR > 1 { print $1 }'
)"
[[ -n "$dependencies" ]] || die "otool reported no dynamic dependencies"

dependency_count=0
while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    (( dependency_count += 1 ))
    case "$dependency" in
        (/System/Library/* | /usr/lib/*)
            ;;
        (*)
            die "non-system dynamic dependency: $dependency"
            ;;
    esac
done <<< "$dependencies"
(( dependency_count > 0 )) || die "no dynamic dependencies were validated"

print "6/10 Bundled model size and SHA-256"
model_file_count="$(
    /usr/bin/find "${resources}/Models" -type f -maxdepth 1 -print \
        | /usr/bin/wc -l \
        | /usr/bin/awk '{ print $1 }'
)"
[[ "$model_file_count" == "3" ]] \
    || die "Models directory must contain exactly three regular files"

verify_model() {
    local file_name="$1"
    local expected_bytes="$2"
    local expected_sha256="$3"
    local model_path="${resources}/Models/${file_name}"
    local actual_bytes
    local actual_sha256

    [[ -f "$model_path" && ! -L "$model_path" ]] \
        || die "bundled model is missing: $file_name"
    actual_bytes="$(/usr/bin/stat -f "%z" "$model_path")"
    [[ "$actual_bytes" == "$expected_bytes" ]] \
        || die \
            "$file_name size mismatch: expected $expected_bytes, got $actual_bytes"
    actual_sha256="$(
        /usr/bin/shasum -a 256 "$model_path" \
            | /usr/bin/awk '{ print $1 }'
    )"
    [[ "$actual_sha256" == "$expected_sha256" ]] \
        || die "$file_name SHA-256 mismatch"
}

verify_model \
    "ggml-small-q5_1.bin" \
    "190085487" \
    "52914f6730a59593fd6108d21dcac060a35ce569d9d70eec431e5623f387c82f"
verify_model \
    "ggml-base.bin" \
    "147951465" \
    "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
verify_model \
    "ggml-silero-v6.2.0.bin" \
    "885098" \
    "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

print "7/10 Bundle permissions"
check_mode "$executable" "755"
check_mode "$info_plist" "644"

while IFS= read -r -d $'\0' resource_directory; do
    check_mode "$resource_directory" "755"
done < <(/usr/bin/find "$resources" -type d -print0)

while IFS= read -r -d $'\0' resource_file; do
    check_mode "$resource_file" "644"
done < <(/usr/bin/find "$resources" -type f -print0)

print "8/10 Bundled-only runtime self-test"
default_speech_pcm="${project_root}/Validation/Fixtures/pcm/ru04-ru-16k-mono-f32le.raw"
default_nonspeech_pcm="${project_root}/Validation/Fixtures/control-pink-noise-10s-16k-mono-f32le.raw"
default_auto_en_pcm="${project_root}/Validation/Fixtures/pcm/en04-en-16k-mono-f32le.raw"
default_corpus_manifest="${project_root}/Validation/Fixtures/corpus-manifest.tsv"
default_auto_manifest="${project_root}/Validation/Fixtures/auto-manifest.tsv"
fixture_root="${project_root}/Validation/Fixtures"
expected_fixture_digest="9a2bb3733fd2c06119a9a55f76a78f264fbb17c354fa484922bfc482b0f4531e"

speech_pcm="$default_speech_pcm"
nonspeech_pcm="$default_nonspeech_pcm"
auto_en_pcm="$default_auto_en_pcm"
corpus_manifest="$default_corpus_manifest"
auto_manifest="$default_auto_manifest"

speech_pcm="${speech_pcm:A}"
nonspeech_pcm="${nonspeech_pcm:A}"
auto_en_pcm="${auto_en_pcm:A}"
corpus_manifest="${corpus_manifest:A}"
auto_manifest="${auto_manifest:A}"

validate_pcm "$speech_pcm" "speech"
validate_pcm "$nonspeech_pcm" "non-speech"
validate_pcm "$auto_en_pcm" "Auto English"
[[ -f "$corpus_manifest" && ! -L "$corpus_manifest" \
    && -r "$corpus_manifest" ]] \
    || die "corpus manifest is not a readable regular file: $corpus_manifest"
[[ -f "$auto_manifest" && ! -L "$auto_manifest" \
    && -r "$auto_manifest" ]] \
    || die "Auto manifest is not a readable regular file: $auto_manifest"

fixture_file_count="$(
    /usr/bin/find "$fixture_root" -type f -print \
        | /usr/bin/wc -l \
        | /usr/bin/awk '{ print $1 }'
)"
[[ "$fixture_file_count" == "19" ]] \
    || die "expected exactly 19 validation fixture files"
fixture_symlink="$(
    /usr/bin/find "$fixture_root" -type l -print -quit
)"
[[ -z "$fixture_symlink" ]] \
    || die "validation fixtures contain a symlink: $fixture_symlink"
actual_fixture_digest="$(
    (
        cd "$fixture_root"
        /usr/bin/find . -type f -print \
            | LC_ALL=C /usr/bin/sort \
            | while IFS= read -r fixture_path; do
                /usr/bin/shasum -a 256 "$fixture_path"
            done
    ) | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
)"
[[ "$actual_fixture_digest" == "$expected_fixture_digest" ]] \
    || die "validation fixture corpus SHA-256 mismatch"

selftest_command=(
    /usr/bin/env
    -u LOCALFLOW_SMALL_MODEL
    -u LOCALFLOW_BASE_MODEL
    -u LOCALFLOW_VAD_MODEL
    -u DYLD_LIBRARY_PATH
    -u DYLD_FRAMEWORK_PATH
    -u DYLD_INSERT_LIBRARIES
    -u DYLD_FALLBACK_LIBRARY_PATH
    -u DYLD_FALLBACK_FRAMEWORK_PATH
    "LOCALFLOW_SELFTEST_PCM_F32=$speech_pcm"
    "LOCALFLOW_SELFTEST_NONSPEECH_PCM_F32=$nonspeech_pcm"
    "LOCALFLOW_SELFTEST_AUTO_EN_PCM_F32=$auto_en_pcm"
    "LOCALFLOW_SELFTEST_INCLUDE_BASE=1"
    "$executable"
    "--self-test"
)

if ! "${selftest_command[@]}" > "$selftest_log" 2>&1; then
    /bin/cat "$selftest_log"
    die "bundled self-test failed; see $selftest_log"
fi
/bin/cat "$selftest_log"

require_output_line "$selftest_log" "LocalFlow self-test: PASS"
require_output_line "$selftest_log" "small model: ggml-small-q5_1.bin"
require_output_line "$selftest_log" "base model: ggml-base.bin"
require_output_line "$selftest_log" "VAD silence gate: PASS"
require_output_line "$selftest_log" "VAD noise gate: PASS"
require_output_line "$selftest_log" "speech VAD gate: PASS"
require_output_line "$selftest_log" "synthetic transcript:"
require_output_line "$selftest_log" "inference cancellation: PASS"
require_output_line "$selftest_log" "post-cancellation inference: PASS"
require_output_line "$selftest_log" "base inference: PASS"
require_output_line "$selftest_log" "auto RU inference: PASS"
require_output_line "$selftest_log" "auto EN inference: PASS"

run_strict_corpus() {
    local manifest="$1"
    local report="$2"
    local error_log="$3"
    local label="$4"

    if ! /usr/bin/env \
        -u LOCALFLOW_SMALL_MODEL \
        -u LOCALFLOW_BASE_MODEL \
        -u LOCALFLOW_VAD_MODEL \
        -u DYLD_LIBRARY_PATH \
        -u DYLD_FRAMEWORK_PATH \
        -u DYLD_INSERT_LIBRARIES \
        -u DYLD_FALLBACK_LIBRARY_PATH \
        -u DYLD_FALLBACK_FRAMEWORK_PATH \
        "$executable" \
        --bridge-corpus-strict \
        "$manifest" \
        > "$report" \
        2> "$error_log"
    then
        /bin/cat "$error_log"
        /bin/cat "$report"
        die "$label strict corpus failed"
    fi

    /usr/bin/python3 - "$report" "$label" <<'PY'
import json
import sys
from collections import Counter

path, label = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as stream:
    report = json.load(stream)
if report.get("status") != "PASS":
    raise SystemExit(f"{label}: report status is not PASS")
if not report.get("samples"):
    raise SystemExit(f"{label}: report contains no samples")
if not report.get("summaries"):
    raise SystemExit(f"{label}: report contains no summaries")
samples = report["samples"]
languages = Counter(sample.get("language") for sample in samples)
if label == "RU/EN":
    if len(samples) != 16 or languages != Counter({"ru": 8, "en": 8}):
        raise SystemExit(
            f"{label}: expected 8 RU + 8 EN samples, got {languages}"
        )
elif label == "Auto":
    detected = Counter(
        sample.get("detected_language", "").lower() for sample in samples
    )
    detected_by_id = {
        sample.get("id"): sample.get("detected_language", "").lower()
        for sample in samples
    }
    if (
        len(samples) != 2
        or languages != Counter({"auto": 2})
        or detected != Counter({"ru": 1, "en": 1})
        or detected_by_id
        != {"auto-ru04": "ru", "auto-en04": "en"}
    ):
        raise SystemExit(
            f"{label}: expected per-sample Auto ru+en, got {detected_by_id}"
        )
PY
}

print "9/10 Strict bundled RU/EN product corpus"
run_strict_corpus \
    "$corpus_manifest" \
    "$corpus_report" \
    "$corpus_error_log" \
    "RU/EN"

print "10/10 Strict bundled Auto RU/EN product corpus"
run_strict_corpus \
    "$auto_manifest" \
    "$auto_report" \
    "$auto_error_log" \
    "Auto"

print "LocalFlow release gate: PASS"
print "Verified ZIP: $destination"
print "Evidence directory: $gate_root"
