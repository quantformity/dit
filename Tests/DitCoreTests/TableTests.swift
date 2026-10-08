@testable import DitCore
import Testing

@Suite("Table headers")
struct TableTests {
    @Test func plainRenderingPreservesTheGrid() {
        let lines = Table.render(headers: ["Name", "Qty"], rows: [["A", "12"]], boldHeaders: false)
        #expect(lines == [
            "┌──────┬─────┐",
            "│ Name │ Qty │",
            "├──────┼─────┤",
            "│ A    │  12 │",
            "└──────┴─────┘",
        ])
    }

    @Test func onlyHeaderLabelsAreBold() {
        let lines = Table.render(headers: ["Name", "Qty"], rows: [["A", "12"]], boldHeaders: true)
        #expect(lines == [
            "┌──────┬─────┐",
            "│ \u{1B}[1mName\u{1B}[22m │ \u{1B}[1mQty\u{1B}[22m │",
            "├──────┼─────┤",
            "│ A    │  12 │",
            "└──────┴─────┘",
        ])
    }

    @Test func stylingPreservesSanitizationAndAlignment() {
        let headers = ["A|B", "C│D", "é"]
        let rows = [["Long label", "123456", "42"], ["x│y", "9", "7"]]
        let plain = Table.render(headers: headers, rows: rows, leftColumns: [0, 2], boldHeaders: false)
        let styled = Table.render(headers: headers, rows: rows, leftColumns: [0, 2], boldHeaders: true)
        #expect(styled[1] == "│ \u{1B}[1mA¦B\u{1B}[22m        │    \u{1B}[1mC¦D\u{1B}[22m │ \u{1B}[1mé\u{1B}[22m  │")
        let stripped = styled.map {
            $0.replacingOccurrences(of: "\u{1B}[1m", with: "")
                .replacingOccurrences(of: "\u{1B}[22m", with: "")
        }
        #expect(stripped == plain)
        #expect(Set(stripped.map(\.count)).count == 1)
        for index in styled.indices where index != 1 {
            #expect(styled[index] == plain[index])
            #expect(!styled[index].contains("\u{1B}"))
        }
    }

    @Test func emptyTableStillStylesItsHeaderAndSkipsBlankLabels() {
        let lines = Table.render(headers: ["Name", ""], rows: [], boldHeaders: true)
        #expect(lines == [
            "┌──────┬──┐",
            "│ \u{1B}[1mName\u{1B}[22m │  │",
            "└──────┴──┘",
        ])
    }

    @Test func terminalEnablesBold() {
        #expect(TerminalStyle.supportsBold(isTerminal: true, environment: ["TERM": "xterm-256color"]))
        #expect(TerminalStyle.supportsBold(isTerminal: true, environment: [:]))
    }

    @Test func pipedOutputNeverEnablesBold() {
        #expect(!TerminalStyle.supportsBold(isTerminal: false, environment: ["TERM": "xterm-256color"]))
    }

    @Test func dumbTerminalAndNoColorDisableBold() {
        #expect(!TerminalStyle.supportsBold(isTerminal: true, environment: ["TERM": "dumb"]))
        #expect(!TerminalStyle.supportsBold(isTerminal: true, environment: ["NO_COLOR": "1"]))
        #expect(!TerminalStyle.supportsBold(isTerminal: true, environment: ["NO_COLOR": "0"]))
        // NO_COLOR follows the convention: only a non-empty value disables styling.
        #expect(TerminalStyle.supportsBold(isTerminal: true, environment: ["NO_COLOR": ""]))
    }
}
