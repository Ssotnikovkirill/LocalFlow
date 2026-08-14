# Сборка и проверка

## Требования

- Apple Silicon Mac;
- macOS 13.3+;
- Xcode Command Line Tools;
- `swiftc`, `clang++`, `codesign`, `zip`, `unzip` из macOS toolchain.

Homebrew, Python runtime, ffmpeg и отдельный whisper executable для работы
готового приложения не нужны.

## Быстрая проверка исходников

```sh
./scripts/verify.sh
```

Скрипт создаёт новый уникальный каталог, собирает Release с warnings-as-errors,
трижды запускает CoreLogicSmokeTests и проверяет plist/entitlements. Системный
toolchain не изменяется.

## Диагностика готового приложения

```sh
/path/LocalFlow.app/Contents/MacOS/LocalFlow --self-test
/path/LocalFlow.app/Contents/MacOS/LocalFlow --history-store-test
/path/LocalFlow.app/Contents/MacOS/LocalFlow --settings-ui-test
```

- `--self-test` проверяет модели, VAD, Right Option decoder, Codex policy,
  Settings layout и лимит истории.
- `--history-store-test` проверяет пять записей, порядок, timestamps,
  disabled mode, migration pruning и безопасную область очистки.
- `--settings-ui-test` строит реальное AppKit-окно и проверяет ввод в трёх
  editors и вкладку History.

## Полный release gate

```sh
LOCALFLOW_RELEASE_ID=unique-id \
./scripts/release-gate.sh /absolute/new/LocalFlow.zip
```

Gate выполняет:

1. Core smoke tests 3×.
2. Release build и ad-hoc hardened-runtime signing.
3. Упаковку и CRC-проверку ZIP.
4. Распаковку в новый каталог и deep/strict codesign.
5. Проверку arm64, minimum macOS и системных dynamic dependencies.
6. Проверку размеров и SHA-256 моделей.
7. Проверку прав файлов.
8. Self-test с VAD, small/base, cancellation/recovery и Auto RU/EN.
9. Строгий корпус 8 RU + 8 EN с WER/RTF limits.
10. Строгий Auto-корпус RU + EN.

## Подтверждённые показатели v1.0.6

- strict RU/EN: 16/16 обработано, 13 normalized exact, WER 5,8824%;
- strict Auto: 2/2 exact, WER 0;
- history retention/order/clear scope: PASS;
- Settings editors и History UI diagnostic: PASS;
- реальный Right Option → microphone → Whisper → TextEdit → History: PASS.

Корпус небольшой и синтетический, поэтому это regression baseline, а не
гарантия идеального распознавания любого голоса и шума.
