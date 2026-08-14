# Архитектура LocalFlow 1.0.6

LocalFlow — menu-bar приложение на Swift/AppKit. Runtime распознавания
статически связан с whisper.cpp и использует Metal/Accelerate на Apple Silicon.

## Основной поток

```text
Right Option CGEventTap
        │
        ▼
Dictation session + сохранённая цель ввода
        ├── non-activating overlay и waveform
        ├── AVAudioEngine capture
        │      └── downmix/resample → 16 kHz mono Float PCM
        ├── Silero VAD
        ├── whisper.cpp
        │      ├── rolling provisional decode
        │      └── final beam-search decode
        ├── Dictionary/Replacements/Snippets
        ├── Accessibility или guarded Command-V insertion
        └── optional final-text history, maximum 5
```

## Модули

- `LocalFlowCore` — state machine, session model, reconciliation и обработка
  текста без зависимости от AppKit.
- `CWhisperBridge` — узкий C ABI над whisper.cpp и Silero VAD.
- `LocalFlowApp` — AppKit shell, permissions, hotkey, audio, overlay, settings,
  вставка, история и diagnostics.

## Конкурентность

- Сессии имеют уникальные ID и generation guards.
- Stale callbacks не могут обновить новую сессию.
- Cancel обрабатывается вне очереди и блокирует поздний final/insert.
- Whisper model switch выполняется single-flight.
- PCM buffers обнуляются после завершения, отмены, сна и выхода.
- История сериализована Swift actor и ограничена пятью валидными записями.

## Вставка

Сначала используется сохранённая Accessibility-цель. Перед вставкой повторно
проверяются PID, focused element/window и Secure Event Input. При невозможности
надёжной AX-вставки используется контролируемый pasteboard/Command-V путь с
change-count guard. Для AX-невидимого prompt Codex существует узкая политика
по точному bundle ID `com.openai.codex`.

## История

Каждая успешная запись — отдельный JSON с ISO-8601 датой, языком, моделью и
финальным текстом. Новые записи сортируются сверху. После шестой валидной
записи удаляется самая старая. Старый формат даты читается для совместимости.
Аудио в историю не попадает.

