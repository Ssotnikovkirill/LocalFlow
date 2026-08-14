import AppKit
import ApplicationServices
import Carbon
import Foundation
import LocalFlowCore

enum UnobservablePasteTargetPolicy {
    static let codexBundleIdentifier = "com.openai.codex"

    static func permits(
        bundleIdentifier: String?,
        focusedElementWasCaptured: Bool,
        focusedWindowWasCaptured: Bool
    ) -> Bool {
        bundleIdentifier == codexBundleIdentifier
            && !focusedElementWasCaptured
            && focusedWindowWasCaptured
    }
}

enum TextInsertionError: LocalizedError {
    case accessibilityDenied
    case secureField
    case targetChangedTextCopied
    case unableToInsert
    case pasteboardRestoreFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Нужен доступ Accessibility для вставки текста"
        case .secureField:
            return "Диктовка в защищённое поле отключена"
        case .targetChangedTextCopied:
            return "Поле ввода изменилось — текст оставлен в буфере обмена"
        case .unableToInsert:
            return "Не удалось вставить текст в активное поле"
        case .pasteboardRestoreFailed:
            return "Текст вставлен, но буфер обмена не удалось восстановить"
        }
    }
}

actor MacTextInsertionService: TextInsertionService {
    private struct TargetSnapshot {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let element: AXUIElement?
        let focusedWindow: AXUIElement?
        let role: String?
        let subrole: String?

        var isSecure: Bool {
            subrole == (kAXSecureTextFieldSubrole as String)
        }
    }

    private struct PasteboardRepresentation: Sendable {
        let type: String
        let data: Data
    }

    private struct PasteboardItemSnapshot: Sendable {
        let representations: [PasteboardRepresentation]
    }

    private struct PasteboardSnapshot: Sendable {
        let items: [PasteboardItemSnapshot]
    }

    private var targets: [DictationSessionID: TargetSnapshot] = [:]

    func captureTarget(for id: DictationSessionID) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else {
            throw TextInsertionError.accessibilityDenied
        }
        guard !IsSecureEventInputEnabled() else {
            throw TextInsertionError.secureField
        }

        let applicationIdentity = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
                (
                    processIdentifier: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier
                )
            }
        }
        try Task.checkCancellation()
        guard let applicationIdentity else {
            throw TextInsertionError.unableToInsert
        }

        let element = Self.focusedElement()
        let focusedWindow = Self.focusedWindow(
            for: applicationIdentity.processIdentifier
        )
        try Task.checkCancellation()
        if let element {
            AXUIElementSetMessagingTimeout(element, 0.6)
        }
        if let focusedWindow {
            AXUIElementSetMessagingTimeout(focusedWindow, 0.6)
        }
        let snapshot = TargetSnapshot(
            processIdentifier: applicationIdentity.processIdentifier,
            bundleIdentifier: applicationIdentity.bundleIdentifier,
            element: element,
            focusedWindow: focusedWindow,
            role: element.flatMap {
                Self.stringAttribute($0, kAXRoleAttribute)
            },
            subrole: element.flatMap {
                Self.stringAttribute($0, kAXSubroleAttribute)
            }
        )
        guard !snapshot.isSecure else {
            throw TextInsertionError.secureField
        }
        targets[id] = snapshot
    }

    func insert(
        _ text: String,
        for id: DictationSessionID
    ) async throws -> TextInsertionOutcome {
        try Task.checkCancellation()
        guard let target = targets.removeValue(forKey: id) else {
            throw AppServiceError.missingSession
        }
        guard !target.isSecure, !IsSecureEventInputEnabled() else {
            throw TextInsertionError.secureField
        }

        let currentApplicationIdentity = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
                (
                    processIdentifier: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier
                )
            }
        }
        try Task.checkCancellation()
        guard
            currentApplicationIdentity?.processIdentifier
                == target.processIdentifier,
            currentApplicationIdentity?.bundleIdentifier
                == target.bundleIdentifier
        else {
            await Self.copyForRecovery(text)
            throw TextInsertionError.targetChangedTextCopied
        }

        guard let originalElement = target.element else {
            if UnobservablePasteTargetPolicy.permits(
                bundleIdentifier: target.bundleIdentifier,
                focusedElementWasCaptured: false,
                focusedWindowWasCaptured: target.focusedWindow != nil
            ) {
                do {
                    return try await Self.insertIntoKnownUnobservableTarget(
                        text,
                        target: target
                    )
                } catch TextInsertionError.targetChangedTextCopied {
                    await Self.copyForRecovery(text)
                    throw TextInsertionError.targetChangedTextCopied
                }
            }
            await Self.copyForRecovery(text)
            return .copied
        }

        guard
            let currentElement = Self.focusedElement(),
            CFEqual(currentElement, originalElement)
        else {
            await Self.copyForRecovery(text)
            throw TextInsertionError.targetChangedTextCopied
        }
        let currentSubrole = Self.stringAttribute(
            currentElement,
            kAXSubroleAttribute
        )
        guard
            currentSubrole != (kAXSecureTextFieldSubrole as String),
            !IsSecureEventInputEnabled()
        else {
            throw TextInsertionError.secureField
        }

        try Task.checkCancellation()
        do {
            try await Self.validateTarget(
                target,
                originalElement: originalElement
            )
        } catch TextInsertionError.targetChangedTextCopied {
            await Self.copyForRecovery(text)
            throw TextInsertionError.targetChangedTextCopied
        }
        if Self.setSelectedText(text, on: originalElement) {
            return .accessibility
        }

        let valueBeforePaste = Self.stringAttribute(
            originalElement,
            kAXValueAttribute
        )
        if let pasteboardSnapshot = await Self.capturePasteboard() {
            try Task.checkCancellation()
            do {
                try await Self.validateTarget(
                    target,
                    originalElement: originalElement
                )
            } catch TextInsertionError.targetChangedTextCopied {
                await Self.copyForRecovery(text)
                throw TextInsertionError.targetChangedTextCopied
            }
            guard CGPreflightPostEventAccess() else {
                await Self.copyForRecovery(text)
                return .copied
            }

            let insertionChangeCount = await Self.writeTemporaryText(text)
            if Task.isCancelled {
                _ = await Self.restorePasteboard(
                    pasteboardSnapshot,
                    ifChangeCountIs: insertionChangeCount
                )
                throw CancellationError()
            }
            do {
                try await Self.validateTarget(
                    target,
                    originalElement: originalElement
                )
            } catch is CancellationError {
                _ = await Self.restorePasteboard(
                    pasteboardSnapshot,
                    ifChangeCountIs: insertionChangeCount
                )
                throw CancellationError()
            } catch TextInsertionError.secureField {
                _ = await Self.restorePasteboard(
                    pasteboardSnapshot,
                    ifChangeCountIs: insertionChangeCount
                )
                throw TextInsertionError.secureField
            } catch {
                // The temporary clipboard already contains the dictated text,
                // the documented recovery path after a focus change.
                throw error
            }
            guard Self.postCommandV() else {
                _ = await Self.restorePasteboard(
                    pasteboardSnapshot,
                    ifChangeCountIs: insertionChangeCount
                )
                throw TextInsertionError.unableToInsert
            }

            // Once Command-V has been posted, do not let cancellation restore
            // the old pasteboard before the target process has had a chance
            // to consume the promised string.
            await Self.waitForPasteConsumption()
            let insertionObserved = Self.insertionWasObserved(
                text,
                previousValue: valueBeforePaste,
                on: originalElement
            )
            if Task.isCancelled {
                if insertionObserved {
                    _ = await Self.restorePasteboard(
                        pasteboardSnapshot,
                        ifChangeCountIs: insertionChangeCount
                    )
                }
                throw CancellationError()
            }

            guard insertionObserved else {
                // Keep our temporary text on the pasteboard. This is a
                // recoverable outcome and is safer than claiming that an
                // unobservable synthetic key event succeeded.
                return .copied
            }

            let restored = await Self.restorePasteboard(
                pasteboardSnapshot,
                ifChangeCountIs: insertionChangeCount
            )
            guard restored else {
                throw TextInsertionError.pasteboardRestoreFailed
            }
            return .pasteboard
        }

        do {
            try await Self.validateTarget(
                target,
                originalElement: originalElement
            )
        } catch TextInsertionError.targetChangedTextCopied {
            await Self.copyForRecovery(text)
            throw TextInsertionError.targetChangedTextCopied
        }
        guard CGPreflightPostEventAccess(), Self.postUnicode(text) else {
            await Self.copyForRecovery(text)
            return .copied
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        try Task.checkCancellation()
        guard Self.insertionWasObserved(
            text,
            previousValue: valueBeforePaste,
            on: originalElement
        ) else {
            await Self.copyForRecovery(text)
            return .copied
        }
        return .unicodeEvents
    }

    private static func validateTarget(
        _ target: TargetSnapshot,
        originalElement: AXUIElement
    ) async throws {
        let currentPID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        try Task.checkCancellation()
        guard
            currentPID == target.processIdentifier,
            let currentElement = focusedElement(),
            CFEqual(currentElement, originalElement)
        else {
            throw TextInsertionError.targetChangedTextCopied
        }

        let currentSubrole = stringAttribute(
            currentElement,
            kAXSubroleAttribute
        )
        guard
            currentSubrole != (kAXSecureTextFieldSubrole as String),
            !IsSecureEventInputEnabled()
        else {
            throw TextInsertionError.secureField
        }

        let finalPID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        try Task.checkCancellation()
        guard
            finalPID == target.processIdentifier,
            let finalElement = focusedElement(),
            CFEqual(finalElement, originalElement)
        else {
            throw TextInsertionError.targetChangedTextCopied
        }
    }

    private static func insertIntoKnownUnobservableTarget(
        _ text: String,
        target: TargetSnapshot
    ) async throws -> TextInsertionOutcome {
        try Task.checkCancellation()
        try await validateUnobservableTarget(target)
        guard CGPreflightPostEventAccess() else {
            await copyForRecovery(text)
            return .copied
        }

        let pasteboardSnapshot = await capturePasteboard()
        let insertionChangeCount = await writeTemporaryText(text)
        if Task.isCancelled {
            if let pasteboardSnapshot {
                _ = await restorePasteboard(
                    pasteboardSnapshot,
                    ifChangeCountIs: insertionChangeCount
                )
            }
            throw CancellationError()
        }
        try await validateUnobservableTarget(target)
        guard postCommandV() else {
            await copyForRecovery(text)
            return .copied
        }

        // Codex exposes its window but not the focused prompt through AX.
        // Direct testing confirms that it consumes Command-V normally within
        // this delay. Restore only if the pasteboard change count is still
        // ours; a concurrent user/application write always wins.
        await waitForPasteConsumption()
        if let pasteboardSnapshot {
            let restored = await restorePasteboard(
                pasteboardSnapshot,
                ifChangeCountIs: insertionChangeCount
            )
            guard restored else {
                throw TextInsertionError.pasteboardRestoreFailed
            }
        }
        return .unobservablePaste
    }

    private static func validateUnobservableTarget(
        _ target: TargetSnapshot
    ) async throws {
        guard
            UnobservablePasteTargetPolicy.permits(
                bundleIdentifier: target.bundleIdentifier,
                focusedElementWasCaptured: target.element != nil,
                focusedWindowWasCaptured: target.focusedWindow != nil
            ),
            !IsSecureEventInputEnabled()
        else {
            throw TextInsertionError.secureField
        }

        let currentApplicationIdentity = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
                (
                    processIdentifier: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier
                )
            }
        }
        try Task.checkCancellation()
        guard
            currentApplicationIdentity?.processIdentifier
                == target.processIdentifier,
            currentApplicationIdentity?.bundleIdentifier
                == target.bundleIdentifier,
            let originalWindow = target.focusedWindow,
            let currentWindow = focusedWindow(
                for: target.processIdentifier
            ),
            CFEqual(currentWindow, originalWindow)
        else {
            throw TextInsertionError.targetChangedTextCopied
        }
    }

    func discardTarget(for id: DictationSessionID) async {
        targets[id] = nil
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard error == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func focusedWindow(
        for processIdentifier: pid_t
    ) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard error == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func insertionWasObserved(
        _ insertedText: String,
        previousValue: String?,
        on element: AXUIElement
    ) -> Bool {
        guard
            let currentValue = stringAttribute(
                element,
                kAXValueAttribute
            ),
            currentValue != previousValue
        else {
            return false
        }
        return currentValue.contains(insertedText)
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        guard error == .success else { return nil }
        return value as? String
    }

    private static func setSelectedText(
        _ text: String,
        on element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                element,
                kAXSelectedTextAttribute as CFString,
                &settable
            ) == .success,
            settable.boolValue
        else {
            return false
        }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    @MainActor
    private static func capturePasteboard() -> PasteboardSnapshot? {
        let pasteboard = NSPasteboard.general
        var totalBytes = 0
        var items: [PasteboardItemSnapshot] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [PasteboardRepresentation] = []
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    return nil
                }
                totalBytes += data.count
                guard totalBytes <= 128 * 1_024 * 1_024 else {
                    return nil
                }
                representations.append(
                    PasteboardRepresentation(
                        type: type.rawValue,
                        data: data
                    )
                )
            }
            items.append(
                PasteboardItemSnapshot(
                    representations: representations
                )
            )
        }
        return PasteboardSnapshot(items: items)
    }

    @MainActor
    private static func writeTemporaryText(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    @MainActor
    private static func copyForRecovery(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @MainActor
    private static func restorePasteboard(
        _ snapshot: PasteboardSnapshot,
        ifChangeCountIs expectedChangeCount: Int
    ) -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expectedChangeCount else {
            return true
        }

        var restoredItems: [NSPasteboardItem] = []
        restoredItems.reserveCapacity(snapshot.items.count)
        for snapshotItem in snapshot.items {
            let item = NSPasteboardItem()
            for representation in snapshotItem.representations {
                guard item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(
                        representation.type
                    )
                ) else {
                    return false
                }
            }
            restoredItems.append(item)
        }

        pasteboard.clearContents()
        if restoredItems.isEmpty {
            return true
        }
        if pasteboard.writeObjects(restoredItems) {
            return true
        }

        // A transient pasteboard-server failure must not leave the clipboard
        // empty after we already cleared it. Retry the in-memory snapshot once.
        pasteboard.clearContents()
        return pasteboard.writeObjects(restoredItems)
    }

    private static func waitForPasteConsumption() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(650)
            ) {
                continuation.resume()
            }
        }
    }

    private static func postCommandV() -> Bool {
        guard
            CGPreflightPostEventAccess(),
            let source = CGEventSource(stateID: .privateState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: false
            )
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func postUnicode(_ text: String) -> Bool {
        guard
            CGPreflightPostEventAccess(),
            let source = CGEventSource(stateID: .privateState)
        else {
            return false
        }

        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(
                start,
                offsetBy: 16,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            let chunk = String(text[start..<end])
            let codeUnits = Array(chunk.utf16)
            guard
                let keyDown = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: true
                ),
                let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: false
                )
            else {
                return false
            }

            codeUnits.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                keyUp.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            start = end
        }
        return true
    }
}
