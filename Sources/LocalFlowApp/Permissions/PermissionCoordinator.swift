import ApplicationServices
import AVFoundation
import Foundation

enum PermissionState: String, Sendable {
    case granted
    case denied
    case notDetermined
}

struct PermissionSnapshot: Sendable {
    let microphone: PermissionState
    let accessibility: PermissionState
    let inputMonitoring: PermissionState
    let eventPosting: PermissionState

    var isReadyForDictation: Bool {
        microphone == .granted
            && accessibility == .granted
            && inputMonitoring == .granted
            && eventPosting == .granted
    }

    var summary: String {
        """
        Микрофон: \(microphone.title)
        Accessibility: \(accessibility.title)
        Наблюдение клавиатуры: \(inputMonitoring.title)
        Вставка событий: \(eventPosting.title)
        """
    }
}

@MainActor
final class PermissionCoordinator {
    func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphoneState(),
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            inputMonitoring: CGPreflightListenEventAccess()
                ? .granted
                : .denied,
            eventPosting: CGPreflightPostEventAccess()
                ? .granted
                : .denied
        )
    }

    func requestRequiredPermissions() async -> PermissionSnapshot {
        _ = await requestMicrophone()
        requestAccessibility()

        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }

        return snapshot()
    }

    private func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    private func requestMicrophone() async -> Bool {
        let currentState = AVCaptureDevice.authorizationStatus(for: .audio)
        guard currentState == .notDetermined else {
            return currentState == .authorized
        }

        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

private extension PermissionState {
    var title: String {
        switch self {
        case .granted:
            return "разрешено"
        case .denied:
            return "не разрешено"
        case .notDetermined:
            return "не запрашивалось"
        }
    }
}
