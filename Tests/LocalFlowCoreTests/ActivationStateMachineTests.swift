import XCTest
@testable import LocalFlowCore

final class ActivationStateMachineTests: XCTestCase {
    private let sessionID = DictationSessionID(rawValue: 1)
    private let staleID = DictationSessionID(rawValue: 2)

    func testHappyPathTransitionsAndCommands() {
        var machine = ActivationStateMachine()

        XCTAssertEqual(
            machine.handle(.rightOptionPressed(sessionID)),
            [.showOverlay, .beginCapture(sessionID)]
        )
        XCTAssertEqual(machine.state, .recording(sessionID))

        XCTAssertEqual(
            machine.handle(.rightOptionReleased(sessionID)),
            [
                .showFinalizing,
                .stopCaptureAndTranscribe(sessionID)
            ]
        )
        XCTAssertEqual(machine.state, .finalizing(sessionID))

        XCTAssertEqual(
            machine.handle(
                .transcriptionCompleted(
                    sessionID,
                    text: "  Проверка текста  "
                )
            ),
            [
                .showFinalText("Проверка текста"),
                .insertText(sessionID, text: "Проверка текста")
            ]
        )
        XCTAssertEqual(machine.state, .inserting(sessionID))

        XCTAssertEqual(
            machine.handle(.insertionCompleted(sessionID)),
            [.hideOverlay]
        )
        XCTAssertEqual(machine.state, .idle)
    }

    func testRepeatedPressAndStaleCallbacksAreIgnored() {
        var machine = ActivationStateMachine()
        _ = machine.handle(.rightOptionPressed(sessionID))

        XCTAssertEqual(
            machine.handle(.rightOptionPressed(staleID)),
            []
        )
        XCTAssertEqual(
            machine.handle(.rightOptionReleased(staleID)),
            []
        )
        XCTAssertEqual(
            machine.handle(
                .transcriptionCompleted(staleID, text: "stale")
            ),
            []
        )
        XCTAssertEqual(machine.state, .recording(sessionID))
    }

    func testEmptyTranscriptFinishesWithoutInsertion() {
        var machine = ActivationStateMachine()
        _ = machine.handle(.rightOptionPressed(sessionID))
        _ = machine.handle(.rightOptionReleased(sessionID))

        XCTAssertEqual(
            machine.handle(
                .transcriptionCompleted(sessionID, text: " \n ")
            ),
            [.hideOverlay]
        )
        XCTAssertEqual(machine.state, .idle)
    }

    func testCancelAbortsOnlyMatchingActiveSession() {
        var machine = ActivationStateMachine()
        _ = machine.handle(.rightOptionPressed(sessionID))

        XCTAssertEqual(machine.handle(.cancel(staleID)), [])
        XCTAssertEqual(machine.state, .recording(sessionID))

        XCTAssertEqual(
            machine.handle(.cancel(nil)),
            [.abortCapture(sessionID), .hideOverlay]
        )
        XCTAssertEqual(machine.state, .idle)
    }

    func testCancelRejectsLateDecodeAndInsertionCompletion() {
        var finalizing = ActivationStateMachine()
        _ = finalizing.handle(.rightOptionPressed(sessionID))
        _ = finalizing.handle(.rightOptionReleased(sessionID))

        XCTAssertEqual(
            finalizing.handle(.cancel(nil)),
            [.abortCapture(sessionID), .hideOverlay]
        )
        XCTAssertEqual(
            finalizing.handle(
                .transcriptionCompleted(sessionID, text: "late")
            ),
            []
        )
        XCTAssertEqual(finalizing.state, .idle)

        var inserting = ActivationStateMachine()
        _ = inserting.handle(.rightOptionPressed(sessionID))
        _ = inserting.handle(.rightOptionReleased(sessionID))
        _ = inserting.handle(
            .transcriptionCompleted(sessionID, text: "ready")
        )

        XCTAssertEqual(
            inserting.handle(.cancel(nil)),
            [.abortCapture(sessionID), .hideOverlay]
        )
        XCTAssertEqual(
            inserting.handle(.insertionCompleted(sessionID)),
            []
        )
        XCTAssertEqual(inserting.state, .idle)
    }

    func testFailureRejectsLateCompletion() {
        var machine = ActivationStateMachine()
        _ = machine.handle(.rightOptionPressed(sessionID))
        _ = machine.handle(.rightOptionReleased(sessionID))

        XCTAssertEqual(
            machine.handle(
                .failure(sessionID, message: "Runtime error")
            ),
            [
                .abortCapture(sessionID),
                .presentError("Runtime error"),
                .hideOverlay
            ]
        )
        XCTAssertEqual(machine.state, .idle)

        XCTAssertEqual(
            machine.handle(
                .transcriptionCompleted(sessionID, text: "late")
            ),
            []
        )
    }
}
