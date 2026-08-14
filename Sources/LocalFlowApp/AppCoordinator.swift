import AppKit
import LocalFlowCore

@MainActor
final class AppCoordinator {
    private let session = DictationSession()
    private let overlay = OverlayPanelController()
    private let permissionCoordinator = PermissionCoordinator()
    private let settingsStore = SettingsStore()
    private let speechEngine: SpeechEngine = WhisperSpeechEngine()
    private let insertionService: TextInsertionService =
        MacTextInsertionService()
    private let historyStore = TranscriptHistoryStore()
    private let launchAtLogin = LaunchAtLoginController()
    private var commandTail: Task<Void, Never>?
    private var commandTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellationTask: Task<Void, Never>?
    private var currentSessionID: DictationSessionID?
    private var sessionSettings: [
        DictationSessionID: LocalFlowSettings
    ] = [:]
    private var targetCaptureTasks: [
        DictationSessionID: Task<Void, Error>
    ] = [:]
    private var cancelledSessionIDs = Set<DictationSessionID>()
    private var delayNextOverlayHide = false
    private var engineReady = false
    private var prewarmTask: Task<Void, Never>?
    private var prewarmGeneration: UInt64 = 0
    private var settingsApplicationGeneration: UInt64 = 0
    private var commandGeneration: UInt64 = 0
    private var isEnvironmentSuspended = false
    private var refreshAfterCancellation = true

    private lazy var hotKeyMonitor = RightOptionEventTap(
        stateChanged: { [weak self] isPressed in
            self?.enqueue { coordinator in
                await coordinator.processRightOption(isPressed: isPressed)
            }
        },
        environmentChanged: { [weak self] change in
            switch change {
            case .suspended:
                self?.isEnvironmentSuspended = true
                self?.cancelCurrentSession()
            case .resumed:
                self?.isEnvironmentSuspended = false
                self?.refreshReadiness()
            }
        }
    )

    private lazy var settingsWindow = SettingsWindowController(
        settingsStore: settingsStore,
        permissionCoordinator: permissionCoordinator,
        launchAtLoginController: launchAtLogin,
        historyStore: historyStore,
        settingsChanged: { [weak self] settings in
            self?.applySettings(settings)
        },
        permissionsRequested: { [weak self] in
            await self?.cancelThenRequestPermissions()
        }
    )

    private lazy var statusBar = StatusBarController(
        openSettings: { [weak self] in
            self?.settingsWindow.show()
        },
        requestPermissions: { [weak self] in
            self?.requestPermissions()
        },
        cancelSession: { [weak self] in
            self?.cancelCurrentSession()
        }
    )

    func start() {
        statusBar.updateStatus("Загружаю локальную модель…")

        let permissions = permissionCoordinator.snapshot()
        if !permissions.isReadyForDictation {
            settingsWindow.show()
        }

        let settings = settingsStore.settings
        applyLaunchAtLogin(settings.launchAtLogin)
        prepareEngine(settings: settings)
    }

    func stop() {
        hotKeyMonitor.shutdown()
        commandGeneration &+= 1
        for task in commandTasks.values {
            task.cancel()
        }
        commandTasks.removeAll(keepingCapacity: false)
        commandTail = nil
        cancellationTask?.cancel()
        prewarmTask?.cancel()
        speechEngine.shutdown()
        overlay.hide()
    }

    func applicationDidBecomeActive() {
        settingsWindow.refreshPermissionSummary()
        settingsWindow.refreshLaunchAtLoginSummary()
        refreshReadiness()
    }

    private func enqueue(
        _ operation: @escaping @MainActor (AppCoordinator) async -> Void
    ) {
        guard cancellationTask == nil else { return }
        let previous = commandTail
        let generation = commandGeneration
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                self?.commandTasks[taskID] = nil
            }
            if let previous {
                await previous.value
            }
            guard
                let self,
                !Task.isCancelled,
                commandGeneration == generation
            else {
                return
            }
            await operation(self)
        }
        commandTasks[taskID] = task
        commandTail = task
    }

    private func processRightOption(isPressed: Bool) async {
        guard
            engineReady,
            cancellationTask == nil,
            permissionCoordinator.snapshot().isReadyForDictation
        else {
            refreshReadiness()
            return
        }
        let update: DictationSessionUpdate
        if isPressed {
            update = await session.rightOptionPressed()
        } else {
            update = await session.rightOptionReleased()
        }
        await apply(update)
    }

    private func apply(_ update: DictationSessionUpdate) async {
        overlay.updateTranscript(update.transcript)

        for command in update.commands {
            switch command {
            case .showOverlay:
                overlay.showListening()

            case let .beginCapture(id):
                do {
                    try Task.checkCancellation()
                    guard !cancelledSessionIDs.contains(id) else { return }
                    let settings = settingsStore.settings
                    currentSessionID = id
                    sessionSettings[id] = settings

                    // Audio starts before any cross-process Accessibility
                    // query, so a slow target application cannot eat the
                    // beginning of the utterance.
                    try await speechEngine.beginSession(
                        id: id,
                        settings: settings,
                        onLevel: { [weak self] level in
                            Task { @MainActor in
                                guard self?.currentSessionID == id else {
                                    return
                                }
                                self?.overlay.updateAudioLevel(level)
                            }
                        },
                        onPartial: { [weak self] text in
                            Task { @MainActor in
                                await self?.acceptPartial(
                                    text,
                                    sessionID: id
                                )
                            }
                        },
                        onFailure: { [weak self] error in
                            Task { @MainActor in
                                self?.enqueue { coordinator in
                                    await coordinator.fail(
                                        id: id,
                                        error: error
                                    )
                                }
                            }
                        }
                    )
                    try Task.checkCancellation()

                    guard !cancelledSessionIDs.contains(id) else {
                        await speechEngine.cancelSession(id: id)
                        return
                    }

                    let targetTask = Task {
                        try Task.checkCancellation()
                        try await insertionService.captureTarget(for: id)
                    }
                    targetCaptureTasks[id] = targetTask
                    observeTargetCapture(targetTask, sessionID: id)
                    statusBar.updateStatus("Слушаю…")
                } catch is CancellationError {
                    await insertionService.discardTarget(for: id)
                    await speechEngine.cancelSession(id: id)
                } catch {
                    await fail(id: id, error: error)
                }

            case .showFinalizing:
                overlay.showFinalizing()
                statusBar.updateStatus("Распознаю…")

            case let .stopCaptureAndTranscribe(id):
                do {
                    try Task.checkCancellation()
                    guard !cancelledSessionIDs.contains(id) else { return }
                    let finalText = try await speechEngine.finishSession(id: id)
                    try Task.checkCancellation()
                    guard !cancelledSessionIDs.contains(id) else { return }
                    let completion = await session.completeTranscription(
                        finalText,
                        for: id
                    )
                    try Task.checkCancellation()
                    guard
                        !cancelledSessionIDs.contains(id),
                        currentSessionID == id
                    else {
                        return
                    }
                    await apply(completion)
                } catch is CancellationError {
                    if !cancelledSessionIDs.contains(id) {
                        await fail(id: id, error: CancellationError())
                    }
                } catch {
                    await fail(id: id, error: error)
                }

            case let .showFinalText(text):
                overlay.showFinalText(text)

            case let .insertText(id, text):
                do {
                    try Task.checkCancellation()
                    guard !cancelledSessionIDs.contains(id) else { return }
                    if let targetTask = targetCaptureTasks.removeValue(
                        forKey: id
                    ) {
                        try await targetTask.value
                    }
                    try Task.checkCancellation()
                    guard !cancelledSessionIDs.contains(id) else { return }
                    let outcome = try await insertionService.insert(
                        text,
                        for: id
                    )
                    try Task.checkCancellation()
                    guard !cancelledSessionIDs.contains(id) else { return }
                    if let settings = sessionSettings[id] {
                        try? await historyStore.record(
                            text,
                            settings: settings
                        )
                    }
                    let completion = await session.completeInsertion(for: id)
                    try Task.checkCancellation()
                    guard
                        !cancelledSessionIDs.contains(id),
                        currentSessionID == id
                    else {
                        return
                    }
                    await apply(completion)
                    if outcome == .copied {
                        statusBar.updateStatus(
                            "Поле не найдено — текст скопирован"
                        )
                    }
                } catch is CancellationError {
                    if !cancelledSessionIDs.contains(id) {
                        await fail(id: id, error: CancellationError())
                    }
                } catch {
                    await fail(id: id, error: error)
                }

            case let .abortCapture(id):
                if let targetTask = targetCaptureTasks.removeValue(
                    forKey: id
                ) {
                    targetTask.cancel()
                    _ = try? await targetTask.value
                }
                await speechEngine.cancelSession(id: id)
                await insertionService.discardTarget(for: id)
                sessionSettings[id] = nil

            case let .presentError(message):
                statusBar.updateStatus(message)
                delayNextOverlayHide = true

            case .hideOverlay:
                if delayNextOverlayHide {
                    delayNextOverlayHide = false
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                }
                overlay.hide()
                if update.state == .idle {
                    if let id = currentSessionID {
                        if let targetTask = targetCaptureTasks.removeValue(
                            forKey: id
                        ) {
                            targetTask.cancel()
                            _ = try? await targetTask.value
                        }
                        await insertionService.discardTarget(for: id)
                        sessionSettings[id] = nil
                    }
                    currentSessionID = nil
                    statusBar.updateStatus("Готов")
                }
            }
        }
    }

    private func fail(id: DictationSessionID, error: Error) async {
        let snapshot = await session.snapshot()
        guard
            !Task.isCancelled,
            !cancelledSessionIDs.contains(id),
            currentSessionID == id,
            snapshot.state.sessionID == id
        else {
            return
        }

        let message = Self.message(for: error)
        overlay.showError(message)

        let update = await session.fail(
            sessionID: id,
            message: message
        )
        guard
            !Task.isCancelled,
            !cancelledSessionIDs.contains(id),
            currentSessionID == id
        else {
            return
        }
        await apply(update)
    }

    private func requestPermissions() {
        Task { @MainActor [weak self] in
            await self?.cancelThenRequestPermissions()
        }
    }

    private func cancelCurrentSession() {
        _ = beginImmediateCancellation()
    }

    @discardableResult
    private func beginImmediateCancellation(
        restartWhenDone: Bool = true
    ) -> Task<Void, Never> {
        if let cancellationTask {
            if !restartWhenDone {
                refreshAfterCancellation = false
            }
            return cancellationTask
        }

        refreshAfterCancellation = restartWhenDone
        commandGeneration &+= 1
        let tasksToDrain = Array(commandTasks.values)
        for task in commandTasks.values {
            task.cancel()
        }
        commandTasks.removeAll(keepingCapacity: true)
        commandTail = nil
        hotKeyMonitor.stop()
        statusBar.updateStatus("Отменяю…")

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await cancelSessionState()
            for taskToDrain in tasksToDrain {
                await taskToDrain.value
            }
            // A task can cross an actor suspension after the first snapshot.
            // Cancel once more after every pre-cancellation command has
            // drained, so no late press/beginCapture state can survive.
            await cancelSessionState()
            let shouldRefresh = refreshAfterCancellation
            refreshAfterCancellation = true
            cancellationTask = nil
            if shouldRefresh {
                refreshReadiness()
            }
        }
        cancellationTask = task
        return task
    }

    private func cancelSessionState() async {
        let snapshot = await session.snapshot()
        guard let id = snapshot.state.sessionID else { return }
        cancelledSessionIDs.insert(id)
        let update = await session.cancel()
        await apply(update)
    }

    private func acceptPartial(
        _ text: String,
        sessionID: DictationSessionID
    ) async {
        guard
            currentSessionID == sessionID,
            sessionSettings[sessionID]?.showLiveTranscript == true
        else {
            return
        }
        let update = await session.acceptPartial(text, for: sessionID)
        guard
            currentSessionID == sessionID,
            !cancelledSessionIDs.contains(sessionID)
        else {
            return
        }
        overlay.updateTranscript(update.transcript)
    }

    private func observeTargetCapture(
        _ task: Task<Void, Error>,
        sessionID: DictationSessionID
    ) {
        Task { @MainActor [weak self] in
            do {
                try await task.value
            } catch is CancellationError {
                return
            } catch {
                guard
                    let self,
                    targetCaptureTasks[sessionID] != nil,
                    currentSessionID == sessionID
                else {
                    return
                }
                enqueue { coordinator in
                    await coordinator.fail(id: sessionID, error: error)
                }
            }
        }
    }

    private func requestPermissionsAndRestartHotKey() async {
        _ = await permissionCoordinator.requestRequiredPermissions()
        hotKeyMonitor.stop()
        settingsWindow.refreshPermissionSummary()
        refreshReadiness()
    }

    private func cancelThenRequestPermissions() async {
        let cancellation = beginImmediateCancellation(
            restartWhenDone: false
        )
        await cancellation.value
        await requestPermissionsAndRestartHotKey()
    }

    private func applySettings(_ settings: LocalFlowSettings) {
        applyLaunchAtLogin(settings.launchAtLogin)
        settingsApplicationGeneration &+= 1
        let generation = settingsApplicationGeneration
        let cancellation = beginImmediateCancellation(
            restartWhenDone: false
        )
        Task { @MainActor [weak self] in
            await cancellation.value
            guard
                let self,
                settingsApplicationGeneration == generation
            else {
                return
            }
            prepareEngine(settings: settings)
        }
    }

    private func prepareEngine(settings: LocalFlowSettings) {
        prewarmGeneration &+= 1
        let generation = prewarmGeneration
        prewarmTask?.cancel()
        engineReady = false
        hotKeyMonitor.stop()
        statusBar.updateStatus("Загружаю локальную модель…")

        prewarmTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await speechEngine.prewarm(settings: settings)
                try Task.checkCancellation()
                guard prewarmGeneration == generation else { return }
                engineReady = true
                prewarmTask = nil
                refreshReadiness()
            } catch is CancellationError {
                guard prewarmGeneration == generation else { return }
                prewarmTask = nil
            } catch {
                guard prewarmGeneration == generation else { return }
                engineReady = false
                prewarmTask = nil
                statusBar.updateStatus(Self.message(for: error))
            }
        }
    }

    private func refreshReadiness() {
        let permissions = permissionCoordinator.snapshot()
        settingsWindow.refreshPermissionSummary()

        guard !isEnvironmentSuspended else {
            hotKeyMonitor.stop()
            statusBar.updateStatus("Системная сессия приостановлена")
            return
        }

        guard cancellationTask == nil else {
            hotKeyMonitor.stop()
            statusBar.updateStatus("Отменяю…")
            return
        }

        guard engineReady else {
            hotKeyMonitor.stop()
            statusBar.updateStatus("Загружаю локальную модель…")
            return
        }

        guard permissions.isReadyForDictation else {
            if currentSessionID != nil {
                _ = beginImmediateCancellation()
                return
            }
            hotKeyMonitor.stop()
            statusBar.updateStatus("Нужны системные разрешения")
            return
        }

        let listening = hotKeyMonitor.start()
        statusBar.updateStatus(
            listening ? "Готов" : "Нужен доступ к вводу"
        )
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            let state = try launchAtLogin.apply(enabled: enabled)
            settingsWindow.refreshLaunchAtLoginSummary()
            if state == .requiresApproval {
                statusBar.updateStatus(
                    "Автозапуск ждёт подтверждения"
                )
            }
        } catch {
            statusBar.updateStatus(
                "Автозапуск: \(Self.message(for: error))"
            )
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }
}
