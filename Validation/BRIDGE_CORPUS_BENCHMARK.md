# Packaged bridge corpus benchmark

`LocalFlow --bridge-corpus MANIFEST.tsv` проверяет именно product C bridge:

- запускается только из packaged `.app`;
- запрещает `LOCALFLOW_SMALL_MODEL`, `LOCALFLOW_BASE_MODEL` и
  `LOCALFLOW_VAD_MODEL`;
- проверяет размер и SHA-256 bundled `small-q5_1` и Silero VAD;
- подтверждает, что обе модели разрешились из
  `Contents/Resources/Models`;
- загружает ровно один `WhisperRuntime` с `small-q5_1` и один
  `VoiceActivityRuntime`;
- последовательно обрабатывает все строки одним resident runtime;
- сначала применяет VAD; при отсутствии речи Whisper не вызывается;
- использует тот же финальный decoder, что рабочее приложение: beam search 5,
  четыре потока, temperature 0 и fallback-инкремент 0,2;
- печатает один JSON-объект в stdout. Внутренние логи whisper.cpp остаются в
  stderr.

## TSV contract

UTF-8 файл содержит четыре поля, разделённые символом TAB:

```text
id	language	pcm_f32_path	reference
ru01	ru	/absolute/path/ru01-ru-16k-mono-f32le.raw	Эталонный текст
en01	en	pcm/en01-en-16k-mono-f32le.raw	Reference text
```

Заголовок необязателен. Пустые строки и строки, начинающиеся с `#`,
игнорируются. `id` должен быть уникальным. Допустимые языки: `ru`, `en`,
`auto` и их полные английские названия. Относительный PCM-путь разрешается
относительно каталога manifest.

PCM должен быть headerless little-endian Float32, 16 kHz, mono. NaN,
бесконечные значения, пустой PCM, неизвестный язык, пустой эталон и
повторяющийся `id` завершают процесс с ненулевым кодом.

## Подготовка текущего корпуса

Скрипт требует существующий родительский каталог и полностью новый
`NEW_OUTPUT_DIRECTORY`. Он отказывается использовать уже существующий путь.
`ffmpeg` нужен только для подготовки тестовых raw PCM и не является
runtime-зависимостью LocalFlow.

Из корня `app-shell`:

```sh
./Validation/prepare-bridge-corpus.sh \
  ../benchmark-report/run-20260730T000247Z-m1-8gb-whispercpp-v1.9.1/speech-corpus.tsv \
  /Volumes/KINGSTON/Codex-LocalFlow-2026-07-29/benchmarks/run-20260730T000247Z-m1-8gb-whispercpp-v1.9.1/audio/wav \
  /Volumes/KINGSTON/Codex-LocalFlow-2026-07-29/benchmarks/run-20260730T000247Z-m1-8gb-whispercpp-v1.9.1/audio/bridge-corpus-f32-UNIQUE-ID
```

Скрипт напечатает абсолютный `BRIDGE_CORPUS_MANIFEST=...`.

## Запуск packaged benchmark

Сначала создать новый пакет с уникальным ID. Не переиспользовать существующие
stage, build или ZIP:

```sh
LOCALFLOW_PACKAGE_ID=bridge-corpus-UNIQUE-ID \
  ./scripts/package-app.sh \
  "$PWD/dist/LocalFlow-bridge-corpus-UNIQUE-ID.zip"
```

Packaging script напечатает `Signed app stage`. Запустить binary именно из
этого нового stage:

```sh
env \
  -u LOCALFLOW_SMALL_MODEL \
  -u LOCALFLOW_BASE_MODEL \
  -u LOCALFLOW_VAD_MODEL \
  /private/tmp/LocalFlow-stage-bridge-corpus-UNIQUE-ID/LocalFlow.app/Contents/MacOS/LocalFlow \
  --bridge-corpus \
  /absolute/path/to/manifest.tsv \
  > /absolute/new/path/bridge-corpus-result.json \
  2> /absolute/new/path/bridge-corpus-engine.log
```

Оба output-пути должны быть новыми. Проверка результата:

```sh
python3 -m json.tool /absolute/new/path/bridge-corpus-result.json
```

JSON содержит setup timing, разрешённые bundle paths, transcript и
VAD/inference/pipeline timing для каждой строки, RTF, normalized exact match,
WER/CER и micro-average summaries для всего корпуса и каждого языка.
