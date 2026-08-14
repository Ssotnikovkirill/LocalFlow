#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
    print -u2 \
        "Usage: $0 SPEECH_CORPUS_TSV WAV_DIRECTORY NEW_OUTPUT_DIRECTORY"
    exit 2
fi

corpus_tsv="${1:A}"
wav_directory="${2:A}"
output_directory="${3:A}"
output_parent="${output_directory:h}"
ffmpeg_binary="${FFMPEG_BINARY:-$(command -v ffmpeg || true)}"

if [[ ! -f "$corpus_tsv" ]]; then
    print -u2 "Corpus TSV not found: $corpus_tsv"
    exit 3
fi
if [[ ! -d "$wav_directory" ]]; then
    print -u2 "WAV directory not found: $wav_directory"
    exit 3
fi
if [[ -z "$ffmpeg_binary" || ! -x "$ffmpeg_binary" ]]; then
    print -u2 "ffmpeg is required only to prepare validation PCM files."
    exit 3
fi
if [[ ! -d "$output_parent" ]]; then
    print -u2 "Output parent must already exist: $output_parent"
    exit 3
fi
if [[ -e "$output_directory" ]]; then
    print -u2 "Refusing to reuse output directory: $output_directory"
    exit 4
fi

sample_count="$(
    awk -F $'\t' 'NR > 1 && NF >= 5 { count += 1 } END { print count + 0 }' \
        "$corpus_tsv"
)"
if [[ "$sample_count" -ne 16 ]]; then
    print -u2 "Expected exactly 16 corpus rows, found: $sample_count"
    exit 5
fi

while IFS=$'\t' read -r sample_id language _voice _rate _reference; do
    source_wav="${wav_directory}/${sample_id}-${language}-16k-mono-s16.wav"
    if [[ ! -f "$source_wav" ]]; then
        print -u2 "Source WAV not found: $source_wav"
        exit 6
    fi
done < <(/usr/bin/tail -n +2 "$corpus_tsv")

mkdir "$output_directory"
pcm_directory="${output_directory}/pcm"
mkdir "$pcm_directory"
manifest="${output_directory}/manifest.tsv"
printf 'id\tlanguage\tpcm_f32_path\treference\n' > "$manifest"

converted_count=0
while IFS=$'\t' read -r sample_id language _voice _rate reference; do
    source_wav="${wav_directory}/${sample_id}-${language}-16k-mono-s16.wav"
    raw_pcm="${pcm_directory}/${sample_id}-${language}-16k-mono-f32le.raw"
    if [[ -e "$raw_pcm" ]]; then
        print -u2 "Refusing to overwrite PCM: $raw_pcm"
        exit 7
    fi

    "$ffmpeg_binary" \
        -nostdin \
        -v error \
        -n \
        -i "$source_wav" \
        -map_metadata -1 \
        -ac 1 \
        -ar 16000 \
        -acodec pcm_f32le \
        -f f32le \
        "$raw_pcm"

    printf '%s\t%s\t%s\t%s\n' \
        "$sample_id" \
        "$language" \
        "$raw_pcm" \
        "$reference" \
        >> "$manifest"
    converted_count=$((converted_count + 1))
done < <(/usr/bin/tail -n +2 "$corpus_tsv")

if [[ "$converted_count" -ne 16 ]]; then
    print -u2 "Conversion count mismatch: $converted_count"
    exit 8
fi

print "BRIDGE_CORPUS_MANIFEST=$manifest"
