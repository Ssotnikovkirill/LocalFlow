import AppKit
import LocalFlowCore

enum SettingsEditorLayout {
    static func documentSize(
        current: NSSize,
        viewport: NSSize
    ) -> NSSize {
        NSSize(
            width: max(viewport.width, 1),
            height: max(current.height, viewport.height, 1)
        )
    }
}

private final class SettingsEditorScrollView: NSScrollView {
    override func layout() {
        super.layout()

        guard let editor = documentView as? NSTextView else { return }
        let targetSize = SettingsEditorLayout.documentSize(
            current: editor.frame.size,
            viewport: contentSize
        )
        guard editor.frame.size != targetSize else { return }

        editor.frame = NSRect(origin: .zero, size: targetSize)
    }
}

struct SettingsEditorDiagnosticResult {
    let name: String
    let viewportSize: NSSize
    let editorSize: NSSize
    let pointerHitEditor: Bool
    let acceptedText: Bool

    var passed: Bool {
        editorSize.width >= viewportSize.width - 1
            && editorSize.height >= viewportSize.height - 1
            && pointerHitEditor
            && acceptedText
    }
}

struct SettingsHistoryDiagnosticResult {
    let rowCount: Int
    let visibleRowHeight: CGFloat
    let timestampContainsDateAndTime: Bool
    let selectionCanBeCopied: Bool

    var passed: Bool {
        rowCount == TranscriptHistoryStore.maximumRecordCount
            && visibleRowHeight > 0
            && timestampContainsDateAndTime
            && selectionCanBeCopied
    }
}

@MainActor
final class SettingsWindowController: NSObject,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private let settingsStore: SettingsStore
    private let permissionCoordinator: PermissionCoordinator
    private let launchAtLoginController: LaunchAtLoginController
    private let historyStore: TranscriptHistoryStore
    private let settingsChanged: (LocalFlowSettings) -> Void
    private let permissionsRequested: () async -> Void

    private lazy var window: NSWindow = makeWindow()
    private let tabView = NSTabView()
    private let languagePopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "Запускать при входе",
        target: nil,
        action: nil
    )
    private let liveTranscriptCheckbox = NSButton(
        checkboxWithTitle: "Показывать предварительный текст",
        target: nil,
        action: nil
    )
    private let historyCheckbox = NSButton(
        checkboxWithTitle: "Хранить последние 5 транскрипций",
        target: nil,
        action: nil
    )
    private let permissionSummary = NSTextField(wrappingLabelWithString: "")
    private let launchAtLoginSummary = NSTextField(
        wrappingLabelWithString: ""
    )
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private let dictionaryTextView = NSTextView()
    private let replacementsTextView = NSTextView()
    private let snippetsTextView = NSTextView()
    private let historyTableView = NSTableView()
    private let historyStatusLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var copyHistoryButton = NSButton(
        title: "Копировать",
        target: self,
        action: #selector(copySelectedHistoryEntry)
    )
    private lazy var clearHistoryButton = NSButton(
        title: "Очистить историю…",
        target: self,
        action: #selector(confirmAndClearHistory)
    )
    private lazy var refreshHistoryButton = NSButton(
        title: "Обновить",
        target: self,
        action: #selector(refreshHistoryAction)
    )
    private lazy var historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = .current
        formatter.dateFormat = "dd.MM.yyyy, HH:mm:ss"
        return formatter
    }()
    private var historyEntries: [TranscriptHistoryEntry] = []
    private var historyRefreshGeneration: UInt64 = 0

    init(
        settingsStore: SettingsStore,
        permissionCoordinator: PermissionCoordinator,
        launchAtLoginController: LaunchAtLoginController,
        historyStore: TranscriptHistoryStore = TranscriptHistoryStore(),
        settingsChanged: @escaping (LocalFlowSettings) -> Void = { _ in },
        permissionsRequested: @escaping () async -> Void = {}
    ) {
        self.settingsStore = settingsStore
        self.permissionCoordinator = permissionCoordinator
        self.launchAtLoginController = launchAtLoginController
        self.historyStore = historyStore
        self.settingsChanged = settingsChanged
        self.permissionsRequested = permissionsRequested
        super.init()
    }

    func show() {
        loadValues()
        refreshPermissionSummary()
        refreshHistory()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refreshPermissionSummary() {
        permissionSummary.stringValue = permissionCoordinator
            .snapshot()
            .summary
    }

    func refreshLaunchAtLoginSummary() {
        let state = launchAtLoginController.state
        launchAtLoginSummary.stringValue = state.title
        launchAtLoginSummary.textColor = state == .requiresApproval
            ? .systemOrange
            : .secondaryLabelColor
    }

    func runEditorDiagnostics() -> [SettingsEditorDiagnosticResult] {
        loadValues()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        let originalTab = tabView.selectedTabViewItem
        defer {
            if let originalTab {
                tabView.selectTabViewItem(originalTab)
            }
            window.orderOut(nil)
        }

        let editors: [(String, String, NSTextView)] = [
            ("Словарь", "dictionary", dictionaryTextView),
            ("Замены", "replacements", replacementsTextView),
            ("Сниппеты", "snippets", snippetsTextView)
        ]

        return editors.map { name, identifier, editor in
            tabView.selectTabViewItem(withIdentifier: identifier)
            window.contentView?.layoutSubtreeIfNeeded()
            tabView.layoutSubtreeIfNeeded()

            guard let scroll = editor.enclosingScrollView else {
                return SettingsEditorDiagnosticResult(
                    name: name,
                    viewportSize: .zero,
                    editorSize: editor.frame.size,
                    pointerHitEditor: false,
                    acceptedText: false
                )
            }
            scroll.layoutSubtreeIfNeeded()

            let probePoint = NSPoint(
                x: min(20, max(scroll.contentSize.width - 1, 0)),
                y: min(20, max(scroll.contentSize.height - 1, 0))
            )
            let pointInRoot = scroll.contentView.convert(
                probePoint,
                to: window.contentView
            )
            let hit = window.contentView?.hitTest(pointInRoot)
            let pointerHitEditor = Self.isView(
                hit,
                inside: editor
            )

            let originalText = editor.string
            let originalSelection = editor.selectedRange()
            editor.string = ""
            let becameFirstResponder = window.makeFirstResponder(editor)
            editor.insertText(
                "123",
                replacementRange: NSRange(location: 0, length: 0)
            )
            let acceptedText = becameFirstResponder
                && editor.string == "123"
            editor.string = originalText
            editor.setSelectedRange(
                NSIntersectionRange(
                    originalSelection,
                    NSRange(location: 0, length: (originalText as NSString).length)
                )
            )

            return SettingsEditorDiagnosticResult(
                name: name,
                viewportSize: scroll.contentSize,
                editorSize: editor.frame.size,
                pointerHitEditor: pointerHitEditor,
                acceptedText: acceptedText
            )
        }
    }

    func runHistoryDiagnostics(
        entries: [TranscriptHistoryEntry]
    ) -> SettingsHistoryDiagnosticResult {
        loadValues()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let originalTab = tabView.selectedTabViewItem
        let originalEntries = historyEntries
        defer {
            historyEntries = originalEntries
            historyTableView.reloadData()
            if let originalTab {
                tabView.selectTabViewItem(originalTab)
            }
            window.orderOut(nil)
        }

        tabView.selectTabViewItem(withIdentifier: "history")
        historyEntries = Array(
            entries.prefix(TranscriptHistoryStore.maximumRecordCount)
        )
        updateHistoryPresentation()
        window.contentView?.layoutSubtreeIfNeeded()
        tabView.layoutSubtreeIfNeeded()
        historyTableView.layoutSubtreeIfNeeded()

        if !historyEntries.isEmpty {
            historyTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateHistoryButtons()

        let formattedTimestamp = historyEntries.first.map {
            historyDateFormatter.string(from: $0.createdAt)
        } ?? ""
        return SettingsHistoryDiagnosticResult(
            rowCount: historyTableView.numberOfRows,
            visibleRowHeight: historyEntries.isEmpty
                ? 0
                : historyTableView.rect(ofRow: 0).height,
            timestampContainsDateAndTime:
                formattedTimestamp.contains(".")
                && formattedTimestamp.contains(":"),
            selectionCanBeCopied: copyHistoryButton.isEnabled
        )
    }

    private static func isView(
        _ candidate: NSView?,
        inside ancestor: NSView
    ) -> Bool {
        var current = candidate
        while let view = current {
            if view === ancestor { return true }
            current = view.superview
        }
        return false
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки LocalFlow"
        window.isReleasedWhenClosed = false
        window.center()

        languagePopup.addItems(
            withTitles: RecognitionLanguage.allCases.map(\.title)
        )
        modelPopup.addItems(
            withTitles: LocalModelChoice.allCases.map(\.title)
        )

        let privacyNote = NSTextField(
            wrappingLabelWithString:
                "Аудио существует только в оперативной памяти и никогда не "
                + "сохраняется. Сеть для распознавания не используется."
        )
        privacyNote.textColor = .secondaryLabelColor

        permissionSummary.font = .monospacedSystemFont(
            ofSize: 11,
            weight: .regular
        )
        launchAtLoginSummary.font = .systemFont(
            ofSize: 11,
            weight: .regular
        )
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true

        let saveButton = NSButton(
            title: "Сохранить",
            target: self,
            action: #selector(save)
        )
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(
            title: "Отмена",
            target: self,
            action: #selector(cancel)
        )

        configureTabView(privacyNote: privacyNote)

        let buttonRow = NSStackView(
            views: [validationLabel, NSView(), cancelButton, saveButton]
        )
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        let stack = NSStackView(
            views: [
                tabView,
                buttonRow
            ]
        )
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            tabView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            validationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 390)
        ])

        return window
    }

    private func configureTabView(privacyNote: NSTextField) {
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let general = NSTabViewItem(identifier: "general")
        general.label = "Основное"
        general.view = makeGeneralView(privacyNote: privacyNote)
        tabView.addTabViewItem(general)

        let dictionary = NSTabViewItem(identifier: "dictionary")
        dictionary.label = "Словарь"
        dictionary.view = makeEditorView(
            title: "Слова и имена",
            description:
                "По одному термину на строку. Они передаются Whisper как "
                + "локальная подсказка и не отправляются в сеть.",
            example: "Пример: OpenAI, LocalFlow, фамилии и названия проектов",
            textView: dictionaryTextView
        )
        tabView.addTabViewItem(dictionary)

        let replacements = NSTabViewItem(identifier: "replacements")
        replacements.label = "Замены"
        replacements.view = makeEditorView(
            title: "Точные замены",
            description:
                "Одна строка: что распознано => что вставить. "
                + "Сопоставление нечувствительно к регистру.",
            example: "опен эй ай => OpenAI",
            textView: replacementsTextView
        )
        tabView.addTabViewItem(replacements)

        let snippets = NSTabViewItem(identifier: "snippets")
        snippets.label = "Сниппеты"
        snippets.view = makeEditorView(
            title: "Голосовые сниппеты",
            description:
                "Произнесите триггер, чтобы вставить готовый текст. "
                + "Используйте \\\\n для переноса строки.",
            example:
                "моя подпись => С уважением,\\\\nКирилл",
            textView: snippetsTextView
        )
        tabView.addTabViewItem(snippets)

        let history = NSTabViewItem(identifier: "history")
        history.label = "История"
        history.view = makeHistoryView()
        tabView.addTabViewItem(history)
    }

    private func makeGeneralView(privacyNote: NSTextField) -> NSView {
        let permissionButton = NSButton(
            title: "Запросить разрешения",
            target: self,
            action: #selector(requestPermissions)
        )
        let loginItemsButton = NSButton(
            title: "Открыть Login Items…",
            target: self,
            action: #selector(openLoginItems)
        )

        let stack = NSStackView(
            views: [
                labeledRow("Язык:", control: languagePopup),
                labeledRow("Модель:", control: modelPopup),
                liveTranscriptCheckbox,
                historyCheckbox,
                launchAtLoginCheckbox,
                launchAtLoginSummary,
                loginItemsButton,
                privacyNote,
                permissionSummary,
                permissionButton
            ]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18),
            privacyNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissionSummary.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return view
    }

    private func makeEditorView(
        title: String,
        description: String,
        example: String,
        textView: NSTextView
    ) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: description)
        detail.textColor = .secondaryLabelColor

        let exampleLabel = NSTextField(wrappingLabelWithString: example)
        exampleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        exampleLabel.textColor = .tertiaryLabelColor

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scroll = SettingsEditorScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(
            views: [heading, detail, exampleLabel, scroll]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            exampleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 330)
        ])
        return view
    }

    private func makeHistoryView() -> NSView {
        let heading = NSTextField(labelWithString: "Последние транскрипции")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let detail = NSTextField(
            wrappingLabelWithString:
                "Локально сохраняются только пять последних текстов с датой "
                + "и временем. Аудио не сохраняется. Новые записи находятся "
                + "сверху. Отключение истории останавливает новые записи, но "
                + "не удаляет уже сохранённые."
        )
        detail.textColor = .secondaryLabelColor

        let dateColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("historyDate")
        )
        dateColumn.title = "Дата и время"
        dateColumn.width = 155
        dateColumn.minWidth = 145
        dateColumn.maxWidth = 175

        let textColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("historyText")
        )
        textColumn.title = "Текст"
        textColumn.width = 390
        textColumn.minWidth = 220

        historyTableView.addTableColumn(dateColumn)
        historyTableView.addTableColumn(textColumn)
        historyTableView.delegate = self
        historyTableView.dataSource = self
        historyTableView.allowsMultipleSelection = false
        historyTableView.allowsEmptySelection = true
        historyTableView.usesAlternatingRowBackgroundColors = true
        historyTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        historyTableView.rowHeight = 58
        historyTableView.intercellSpacing = NSSize(width: 8, height: 4)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.documentView = historyTableView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        historyStatusLabel.textColor = .secondaryLabelColor
        historyStatusLabel.font = .systemFont(ofSize: 11)
        copyHistoryButton.isEnabled = false
        clearHistoryButton.isEnabled = false

        let actions = NSStackView(
            views: [
                copyHistoryButton,
                refreshHistoryButton,
                clearHistoryButton,
                NSView(),
                historyStatusLabel
            ]
        )
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10

        let stack = NSStackView(views: [heading, detail, scroll, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 355),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return view
    }

    private func labeledRow(
        _ title: String,
        control: NSView
    ) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func loadValues() {
        let settings = settingsStore.settings
        languagePopup.selectItem(
            at: RecognitionLanguage.allCases.firstIndex(
                of: settings.language
            ) ?? 0
        )
        modelPopup.selectItem(
            at: LocalModelChoice.allCases.firstIndex(
                of: settings.model
            ) ?? 0
        )
        launchAtLoginCheckbox.state = settings.launchAtLogin ? .on : .off
        refreshLaunchAtLoginSummary()
        liveTranscriptCheckbox.state = settings.showLiveTranscript ? .on : .off
        historyCheckbox.state = settings.keepTranscriptHistory ? .on : .off
        dictionaryTextView.string = settings.dictionaryEntries
            .joined(separator: "\n")
        replacementsTextView.string = TextRuleCodec.encode(
            settings.replacementRules
        )
        snippetsTextView.string = TextRuleCodec.encode(settings.snippets)
        validationLabel.isHidden = true
    }

    private func refreshHistory() {
        historyRefreshGeneration &+= 1
        let generation = historyRefreshGeneration
        historyStatusLabel.stringValue = "Загружаю историю…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await historyStore.entries()
                guard historyRefreshGeneration == generation else { return }
                historyEntries = entries
                updateHistoryPresentation()
            } catch {
                guard historyRefreshGeneration == generation else { return }
                historyEntries = []
                historyTableView.reloadData()
                updateHistoryButtons()
                historyStatusLabel.stringValue =
                    "Не удалось прочитать историю: \(error.localizedDescription)"
                historyStatusLabel.textColor = .systemRed
            }
        }
    }

    private func updateHistoryPresentation() {
        historyTableView.reloadData()
        historyTableView.deselectAll(nil)
        updateHistoryButtons()
        historyStatusLabel.textColor = .secondaryLabelColor

        if historyEntries.isEmpty {
            historyStatusLabel.stringValue = settingsStore.settings
                .keepTranscriptHistory
                ? "История пока пуста — продиктуйте первый текст."
                : "Хранение выключено. Включите его на вкладке «Основное»."
        } else {
            historyStatusLabel.stringValue =
                "Сохранено: \(historyEntries.count) из "
                + "\(TranscriptHistoryStore.maximumRecordCount)"
        }
    }

    private func updateHistoryButtons() {
        let row = historyTableView.selectedRow
        copyHistoryButton.isEnabled = historyEntries.indices.contains(row)
        clearHistoryButton.isEnabled = !historyEntries.isEmpty
    }

    @objc
    private func refreshHistoryAction() {
        refreshHistory()
    }

    @objc
    private func copySelectedHistoryEntry() {
        let row = historyTableView.selectedRow
        guard historyEntries.indices.contains(row) else {
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(historyEntries[row].text, forType: .string) else {
            historyStatusLabel.stringValue = "Не удалось скопировать текст."
            historyStatusLabel.textColor = .systemRed
            return
        }
        historyStatusLabel.stringValue = "Текст скопирован в буфер обмена."
        historyStatusLabel.textColor = .secondaryLabelColor
    }

    @objc
    private func confirmAndClearHistory() {
        guard !historyEntries.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Очистить историю транскрипций?"
        alert.informativeText =
            "Будут удалены только сохранённые тексты LocalFlow. "
            + "Настройки, словарь, замены и сниппеты не изменятся."
        alert.addButton(withTitle: "Очистить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        historyStatusLabel.stringValue = "Очищаю историю…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await historyStore.clear()
                refreshHistory()
            } catch {
                historyStatusLabel.stringValue =
                    "Не удалось очистить историю: \(error.localizedDescription)"
                historyStatusLabel.textColor = .systemRed
            }
        }
    }

    @objc
    private func save() {
        let replacementResult = TextRuleCodec.parse(
            replacementsTextView.string
        )
        let snippetResult = TextRuleCodec.parse(snippetsTextView.string)
        let issues = replacementResult.issues.map {
            "Замены, строка \($0.line): \($0.message)"
        } + snippetResult.issues.map {
            "Сниппеты, строка \($0.line): \($0.message)"
        }
        guard issues.isEmpty else {
            validationLabel.stringValue = issues.prefix(3)
                .joined(separator: "\n")
            validationLabel.isHidden = false
            return
        }

        var settings = settingsStore.settings
        settings.language = selectedLanguage()
        settings.model = selectedModel()
        settings.launchAtLogin = launchAtLoginCheckbox.state == .on
        settings.showLiveTranscript = liveTranscriptCheckbox.state == .on
        settings.keepTranscriptHistory = historyCheckbox.state == .on
        settings.dictionaryEntries = normalizedDictionaryEntries()
        settings.replacementRules = replacementResult.rules
        settings.snippets = snippetResult.rules
        settingsStore.settings = settings
        settingsChanged(settings)
        window.orderOut(nil)
    }

    @objc
    private func cancel() {
        window.orderOut(nil)
    }

    @objc
    private func requestPermissions() {
        Task { [weak self] in
            guard let self else { return }
            await permissionsRequested()
            refreshPermissionSummary()
        }
    }

    @objc
    private func openLoginItems() {
        launchAtLoginController.openSystemSettings()
    }

    private func selectedLanguage() -> RecognitionLanguage {
        let index = min(
            max(languagePopup.indexOfSelectedItem, 0),
            RecognitionLanguage.allCases.count - 1
        )
        return RecognitionLanguage.allCases[index]
    }

    private func selectedModel() -> LocalModelChoice {
        let index = min(
            max(modelPopup.indexOfSelectedItem, 0),
            LocalModelChoice.allCases.count - 1
        )
        return LocalModelChoice.allCases[index]
    }

    private func normalizedDictionaryEntries() -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rawLine in dictionaryTextView.string.components(
            separatedBy: .newlines
        ) {
            let entry = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !entry.isEmpty else { continue }
            let key = entry.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "ru_RU")
            )
            guard seen.insert(key).inserted else { continue }
            result.append(entry)
        }

        return result
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard tableView === historyTableView else { return 0 }
        return historyEntries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard
            tableView === historyTableView,
            historyEntries.indices.contains(row),
            let tableColumn
        else {
            return nil
        }

        let entry = historyEntries[row]
        let text: String
        if tableColumn.identifier.rawValue == "historyDate" {
            text = historyDateFormatter.string(from: entry.createdAt)
        } else {
            text = entry.text
        }

        let label = NSTextField(wrappingLabelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 3
        label.font = tableColumn.identifier.rawValue == "historyDate"
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 12)
        label.toolTip = text
        return label
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView === historyTableView ? 58 : tableView.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === historyTableView else {
            return
        }
        updateHistoryButtons()
    }
}
