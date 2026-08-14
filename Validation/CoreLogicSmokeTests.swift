import LocalFlowCore

@main
struct CoreLogicSmokeTests {
    static func main() async {
        testStateMachineHappyPath()
        testStaleEvents()
        testEmptyCancelAndFailurePaths()
        testTranscriptReconciliation()
        testTextRules()
        await testSessionActor()
        print("CoreLogicSmokeTests: PASS")
    }

    private static func testTextRules() {
        let parsed = TextRuleCodec.parse(
            "опен эй ай => OpenAI\nподпись => Строка 1\\nСтрока 2"
        )
        expect(parsed.issues.isEmpty, "valid text rules must parse")
        expect(parsed.rules.count == 2, "text rule count mismatch")

        let processor = TextPostProcessor(
            replacements: [parsed.rules[0]],
            snippets: [parsed.rules[1]]
        )
        expect(
            processor.process("ОПЕН ЭЙ АЙ , подпись")
                == "OpenAI, Строка 1\nСтрока 2",
            "text post-processing mismatch"
        )

        let invalid = TextRuleCodec.parse(
            "без разделителя\nповтор => один\nПОВТОР => два"
        )
        expect(invalid.issues.count == 2, "invalid rules must be reported")

        let boundaryProcessor = TextPostProcessor(
            replacements: [
                TextRule(trigger: "кот", replacement: "пёс")
            ]
        )
        expect(
            boundaryProcessor.process("кот и котик") == "пёс и котик",
            "Unicode word boundary replacement mismatch"
        )
    }

    private static func testStateMachineHappyPath() {
        let id = DictationSessionID(rawValue: 10)
        var machine = ActivationStateMachine()

        expect(
            machine.handle(.rightOptionPressed(id))
                == [.showOverlay, .beginCapture(id)],
            "press should start capture"
        )
        expect(
            machine.handle(.rightOptionReleased(id))
                == [.showFinalizing, .stopCaptureAndTranscribe(id)],
            "release should finalize"
        )
        expect(
            machine.handle(.transcriptionCompleted(id, text: "  готово  "))
                == [
                    .showFinalText("готово"),
                    .insertText(id, text: "готово")
                ],
            "final text should be trimmed and inserted once"
        )
        expect(
            machine.handle(.insertionCompleted(id)) == [.hideOverlay],
            "completion should hide overlay"
        )
        expect(machine.state == .idle, "happy path should finish idle")
    }

    private static func testStaleEvents() {
        let active = DictationSessionID(rawValue: 20)
        let stale = DictationSessionID(rawValue: 21)
        var machine = ActivationStateMachine()
        _ = machine.handle(.rightOptionPressed(active))

        expect(
            machine.handle(.rightOptionReleased(stale)).isEmpty,
            "stale release must be ignored"
        )
        expect(
            machine.state == .recording(active),
            "stale event must not mutate state"
        )
        expect(
            machine.handle(.rightOptionPressed(stale)).isEmpty,
            "repeated press must be ignored"
        )
        expect(
            machine.handle(
                .transcriptionCompleted(stale, text: "stale")
            ).isEmpty,
            "stale transcription must be ignored"
        )
    }

    private static func testEmptyCancelAndFailurePaths() {
        let id = DictationSessionID(rawValue: 30)
        var emptyMachine = ActivationStateMachine()
        _ = emptyMachine.handle(.rightOptionPressed(id))
        _ = emptyMachine.handle(.rightOptionReleased(id))
        expect(
            emptyMachine.handle(
                .transcriptionCompleted(id, text: " \n ")
            ) == [.hideOverlay],
            "empty transcript must not insert"
        )
        expect(emptyMachine.state == .idle, "empty path must end idle")

        var cancelMachine = ActivationStateMachine()
        _ = cancelMachine.handle(.rightOptionPressed(id))
        expect(
            cancelMachine.handle(.cancel(nil))
                == [.abortCapture(id), .hideOverlay],
            "cancel must abort active capture"
        )
        expect(
            cancelMachine.handle(
                .transcriptionCompleted(id, text: "late")
            ).isEmpty,
            "decode completion after cancel must not insert"
        )

        var insertingCancelMachine = ActivationStateMachine()
        _ = insertingCancelMachine.handle(.rightOptionPressed(id))
        _ = insertingCancelMachine.handle(.rightOptionReleased(id))
        _ = insertingCancelMachine.handle(
            .transcriptionCompleted(id, text: "ready")
        )
        expect(
            insertingCancelMachine.handle(.cancel(nil))
                == [.abortCapture(id), .hideOverlay],
            "cancel while inserting must invalidate the session"
        )
        expect(
            insertingCancelMachine.handle(.insertionCompleted(id)).isEmpty,
            "late insertion completion after cancel must be ignored"
        )

        var failureMachine = ActivationStateMachine()
        _ = failureMachine.handle(.rightOptionPressed(id))
        expect(
            failureMachine.handle(
                .failure(id, message: "failure")
            ) == [
                .abortCapture(id),
                .presentError("failure"),
                .hideOverlay
            ],
            "failure command sequence mismatch"
        )
        expect(
            failureMachine.handle(
                .transcriptionCompleted(id, text: "late")
            ).isEmpty,
            "late completion after failure must be ignored"
        )
    }

    private static func testTranscriptReconciliation() {
        var reconciler = TranscriptReconciler(
            tentativeTailTokenCount: 1
        )
        _ = reconciler.update(candidate: "Привет это тест")
        let second = reconciler.update(
            candidate: "Привет это тестовая фраза"
        )

        expect(second.confirmed == "Привет", "stable prefix mismatch")
        expect(
            second.tentative == "это тестовая фраза",
            "tentative suffix mismatch"
        )
        expect(
            reconciler.finalize(text: " один\nдва ").confirmed
                == "один два",
            "final whitespace normalization mismatch"
        )

        var rolling = TranscriptReconciler(tentativeTailTokenCount: 0)
        _ = rolling.update(candidate: "один два три четыре")
        _ = rolling.update(candidate: "один два три четыре пять")
        expect(
            rolling.update(candidate: "четыре пять шесть семь")
                .combined == "один два три четыре пять шесть семь",
            "rolling suffix/prefix alignment mismatch"
        )

        rolling.reset()
        expect(
            rolling.update(candidate: "новая сессия").confirmed.isEmpty,
            "reset must clear stable context"
        )
    }

    private static func testSessionActor() async {
        let session = DictationSession()
        let started = await session.rightOptionPressed()
        guard case let .recording(id) = started.state else {
            fatalError("session actor did not enter recording")
        }

        let released = await session.rightOptionReleased()
        expect(
            released.state == .finalizing(id),
            "session actor did not enter finalizing"
        )

        let completed = await session.completeTranscription(
            "actor test",
            for: id
        )
        expect(
            completed.state == .inserting(id),
            "session actor did not enter inserting"
        )

        let stale = await session.completeTranscription(
            "late",
            for: DictationSessionID(rawValue: id.rawValue + 1)
        )
        expect(
            stale.state == .inserting(id),
            "stale actor callback must not mutate state"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() {
            fatalError(message)
        }
    }
}
