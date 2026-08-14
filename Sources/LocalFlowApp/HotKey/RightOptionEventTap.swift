import AppKit
import ApplicationServices
import Foundation

private let rightOptionKeyCode = CGKeyCode(61)

enum RightOptionFlagDecoder {
    private static let leftOptionDeviceFlag = CGEventFlags(
        rawValue: 0x00000020
    )
    private static let rightOptionDeviceFlag = CGEventFlags(
        rawValue: 0x00000040
    )

    static func isPressed(flags: CGEventFlags) -> Bool {
        let hasDeviceSpecificOptionFlag =
            flags.contains(leftOptionDeviceFlag)
            || flags.contains(rightOptionDeviceFlag)
        if hasDeviceSpecificOptionFlag {
            return flags.contains(rightOptionDeviceFlag)
        }

        // Programmatically generated events may omit the device-specific
        // flags. The key code is checked by the caller, so the aggregate
        // Option flag is the correct fallback.
        return flags.contains(.maskAlternate)
    }
}

enum RightOptionEnvironmentChange {
    case suspended
    case resumed
}

private func rightOptionEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<RightOptionEventTap>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return monitor.receive(type: type, event: event)
}

final class RightOptionEventTap {
    private let stateChanged: @MainActor (Bool) -> Void
    private let environmentChanged:
        @MainActor (RightOptionEnvironmentChange) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRightOptionPressed = false
    private var ignoreUntilRightOptionRelease = false
    private var eventGeneration: UInt64 = 0
    private var transitionSequence: UInt64 = 0
    private var environmentSequence: UInt64 = 0
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        stateChanged: @escaping @MainActor (Bool) -> Void,
        environmentChanged:
            @escaping @MainActor (RightOptionEnvironmentChange) -> Void
            = { _ in }
    ) {
        self.stateChanged = stateChanged
        self.environmentChanged = environmentChanged
    }

    @discardableResult
    func start() -> Bool {
        installWorkspaceObserversIfNeeded()
        guard eventTap == nil else { return true }

        let eventMask = CGEventMask(
            1 << CGEventType.flagsChanged.rawValue
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: rightOptionEventTapCallback,
            userInfo: pointer
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        )
        self.eventTap = eventTap
        runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        synchronizePhysicalState()
        return true
    }

    func stop() {
        if CGEventSource.keyState(
            .combinedSessionState,
            key: rightOptionKeyCode
        ) {
            ignoreUntilRightOptionRelease = true
        }
        tearDownEventTap()
    }

    func shutdown() {
        environmentSequence &+= 1
        stop()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
    }

    fileprivate func receive(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            synchronizePhysicalState()
            return Unmanaged.passUnretained(event)
        }

        guard
            type == .flagsChanged,
            event.getIntegerValueField(.keyboardEventKeycode)
                == Int64(rightOptionKeyCode)
        else {
            return Unmanaged.passUnretained(event)
        }

        // At a head-insert event tap, CGEventSource.keyState still describes
        // the state *before* this flagsChanged event. Reading it here drops
        // the Right Option press. The event flags describe the new state.
        let currentlyPressed = RightOptionFlagDecoder.isPressed(
            flags: event.flags
        )
        if ignoreUntilRightOptionRelease {
            if !currentlyPressed {
                ignoreUntilRightOptionRelease = false
            }
            isRightOptionPressed = false
            return Unmanaged.passUnretained(event)
        }
        guard currentlyPressed != isRightOptionPressed else {
            return Unmanaged.passUnretained(event)
        }

        isRightOptionPressed = currentlyPressed
        let generation = eventGeneration
        transitionSequence &+= 1
        let sequence = transitionSequence
        Task { @MainActor [weak self] in
            guard
                let self,
                eventGeneration == generation,
                transitionSequence == sequence,
                isRightOptionPressed == currentlyPressed,
                !ignoreUntilRightOptionRelease
            else {
                return
            }
            stateChanged(currentlyPressed)
        }

        // Observe without swallowing the modifier, so Option keeps working in
        // the currently focused application.
        return Unmanaged.passUnretained(event)
    }

    private func installWorkspaceObserversIfNeeded() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let suspensionNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        let resumeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]

        workspaceObservers = suspensionNames.map { name in
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.suspendForEnvironmentChange()
            }
        } + resumeNames.map { name in
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.resumeAfterEnvironmentChange()
            }
        }
    }

    private func suspendForEnvironmentChange() {
        ignoreUntilRightOptionRelease = true
        tearDownEventTap()
        environmentSequence &+= 1
        let sequence = environmentSequence
        Task { @MainActor [weak self] in
            guard
                let self,
                environmentSequence == sequence
            else {
                return
            }
            environmentChanged(.suspended)
        }
    }

    private func resumeAfterEnvironmentChange() {
        environmentSequence &+= 1
        let sequence = environmentSequence
        Task { @MainActor [weak self] in
            guard
                let self,
                environmentSequence == sequence
            else {
                return
            }
            environmentChanged(.resumed)
        }
    }

    private func tearDownEventTap() {
        eventGeneration &+= 1
        transitionSequence &+= 1
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(
                    CFRunLoopGetMain(),
                    runLoopSource,
                    .commonModes
                )
            }
            CFMachPortInvalidate(eventTap)
        }

        eventTap = nil
        runLoopSource = nil
        isRightOptionPressed = false
    }

    private func synchronizePhysicalState() {
        let currentlyPressed = CGEventSource.keyState(
            .combinedSessionState,
            key: rightOptionKeyCode
        )
        if ignoreUntilRightOptionRelease {
            if currentlyPressed {
                isRightOptionPressed = false
                return
            }
            ignoreUntilRightOptionRelease = false
        }
        guard currentlyPressed != isRightOptionPressed else { return }
        isRightOptionPressed = currentlyPressed
        let generation = eventGeneration
        transitionSequence &+= 1
        let sequence = transitionSequence
        Task { @MainActor [weak self] in
            guard
                let self,
                eventGeneration == generation,
                transitionSequence == sequence,
                isRightOptionPressed == currentlyPressed,
                !ignoreUntilRightOptionRelease
            else {
                return
            }
            stateChanged(currentlyPressed)
        }
    }

    deinit {
        shutdown()
    }
}
