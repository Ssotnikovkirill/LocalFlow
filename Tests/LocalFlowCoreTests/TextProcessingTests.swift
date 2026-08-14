import XCTest
@testable import LocalFlowCore

final class TextProcessingTests: XCTestCase {
    func testRuleCodecParsesEscapesCommentsAndIssues() {
        let source = """
        # comment
        мой адрес => first@example.com
        подпись => С уважением,\\nКирилл
        invalid
        """

        let result = TextRuleCodec.parse(source)

        XCTAssertEqual(
            result.rules,
            [
                TextRule(
                    trigger: "мой адрес",
                    replacement: "first@example.com"
                ),
                TextRule(
                    trigger: "подпись",
                    replacement: "С уважением,\nКирилл"
                )
            ]
        )
        XCTAssertEqual(
            result.issues,
            [
                TextRuleCodec.ParseIssue(
                    line: 4,
                    message: "ожидается разделитель =>"
                )
            ]
        )
    }

    func testPostProcessorUsesUnicodeWordBoundaries() {
        let processor = TextPostProcessor(
            replacements: [
                TextRule(trigger: "опен эй ай", replacement: "OpenAI")
            ],
            snippets: []
        )

        XCTAssertEqual(
            processor.process("  ОПЕН ЭЙ АЙ создала модель.  "),
            "OpenAI создала модель."
        )
        XCTAssertEqual(
            processor.process("словоопен эй ай"),
            "словоопен эй ай"
        )
    }

    func testReplacementRunsBeforeSnippetExpansion() {
        let processor = TextPostProcessor(
            replacements: [
                TextRule(trigger: "мая почта", replacement: "моя почта")
            ],
            snippets: [
                TextRule(
                    trigger: "моя почта",
                    replacement: "kirill@example.com"
                )
            ]
        )

        XCTAssertEqual(
            processor.process("Мая почта"),
            "kirill@example.com"
        )
    }

    func testFormattingRemovesSpacesBeforePunctuation() {
        let processor = TextPostProcessor()

        XCTAssertEqual(
            processor.process("Привет  ,   мир  !"),
            "Привет, мир!"
        )
    }
}
