import XCTest
@testable import LocalFlowCore

final class TranscriptReconcilerTests: XCTestCase {
    func testFirstHypothesisIsEntirelyTentative() {
        var reconciler = TranscriptReconciler(tentativeTailTokenCount: 1)

        XCTAssertEqual(
            reconciler.update(candidate: "Привет это тест"),
            TranscriptPresentation(
                confirmed: "",
                tentative: "Привет это тест"
            )
        )
    }

    func testSharedPrefixBecomesConfirmedExceptTail() {
        var reconciler = TranscriptReconciler(tentativeTailTokenCount: 1)
        _ = reconciler.update(candidate: "Привет это тест")

        XCTAssertEqual(
            reconciler.update(candidate: "Привет это тестовая фраза"),
            TranscriptPresentation(
                confirmed: "Привет",
                tentative: "это тестовая фраза"
            )
        )
    }

    func testCorrectionRemainsTentative() {
        var reconciler = TranscriptReconciler(tentativeTailTokenCount: 0)
        _ = reconciler.update(candidate: "I want two apples")

        XCTAssertEqual(
            reconciler.update(candidate: "I want to apply"),
            TranscriptPresentation(
                confirmed: "I want",
                tentative: "to apply"
            )
        )
    }

    func testWhitespaceIsNormalized() {
        var reconciler = TranscriptReconciler()

        XCTAssertEqual(
            reconciler.finalize(text: "  один \n два\tтри  "),
            TranscriptPresentation(
                confirmed: "один два три",
                tentative: ""
            )
        )
    }

    func testResetPreventsPreviousSessionFromConfirmingText() {
        var reconciler = TranscriptReconciler(tentativeTailTokenCount: 0)
        _ = reconciler.update(candidate: "same words")
        reconciler.reset()

        XCTAssertEqual(
            reconciler.update(candidate: "same words"),
            TranscriptPresentation(
                confirmed: "",
                tentative: "same words"
            )
        )
    }

    func testCombinedJoinsOnlyNonemptyParts() {
        XCTAssertEqual(
            TranscriptPresentation(
                confirmed: "готово",
                tentative: "почти"
            ).combined,
            "готово почти"
        )
        XCTAssertEqual(
            TranscriptPresentation(
                confirmed: "",
                tentative: "черновик"
            ).combined,
            "черновик"
        )
    }

    func testRollingWindowUsesSuffixPrefixOverlap() {
        var reconciler = TranscriptReconciler(tentativeTailTokenCount: 0)
        _ = reconciler.update(
            candidate: "один два три четыре"
        )
        _ = reconciler.update(
            candidate: "один два три четыре пять"
        )

        let rolling = reconciler.update(
            candidate: "четыре пять шесть семь"
        )

        XCTAssertEqual(
            rolling.combined,
            "один два три четыре пять шесть семь"
        )
    }
}
