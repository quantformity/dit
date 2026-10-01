import Foundation
import DitCore

// dit-chart — ASCII bar charts from machine documents (a pipe tool).
//
//   dit --json | dit-chart              Unicode block glyphs (default)
//   dit --json | dit-chart --ascii      plain glyph tier
//   dit --json | dit-chart --svg x.svg  refused (not implemented)
//
// Reads EXACTLY ONE JSON document from stdin, dispatches on its
// "schema", and either charts it or says why not. No network, no
// store, no numbers of its own: it renders what the document says,
// with provenance markers intact. Unknown schemas are refused — a
// chart that guesses what a number means is a lying chart.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("dit-chart: \(message)\n".utf8))
    exit(code)
}

// MARK: Options — unknown options are usage errors (exit 2), like dit.

var ascii = false
var width: Int? = nil
let arguments = Array(CommandLine.arguments.dropFirst())
var cursor = arguments.startIndex
while cursor < arguments.endIndex {
    let argument = arguments[cursor]
    switch argument {
    case "--ascii":
        ascii = true
        cursor += 1
    case "--width":
        guard cursor + 1 < arguments.endIndex, let value = Int(arguments[cursor + 1]),
              (40...400).contains(value)
        else { fail("--width needs a number between 40 and 400", code: 2) }
        width = value
        cursor += 2
    case "--svg":
        fail("svg output is not implemented yet — this build draws ASCII/Unicode only", code: 2)
    case "--help", "-h":
        print("""
              USAGE: dit [--json …] | dit-chart [--ascii] [--width N]

                Reads one JSON document from stdin (typically the output
                of 'dit … --json') and prints bar charts.

                --ascii      plain glyph tier (#, ^, ?) instead of the
                             default Unicode blocks (█ ✕ ▲)
                --width N    drawing width in columns (default: COLUMNS
                             environment, else 80)
                --svg PATH   not implemented yet — refuses instead of
                             silently ignoring

                Exit codes: 0 charted, 1 nothing chartable (bad input,
                unsupported schema, failed source), 2 usage error.
              """)
        exit(0)
    default:
        if argument.hasPrefix("-") {
            fail("unknown option '\(argument)' — see dit-chart --help", code: 2)
        }
        fail("unexpected argument '\(argument)' — chart data comes from stdin", code: 2)
    }
}

var finalWidth = width
if finalWidth == nil, let columns = ProcessInfo.processInfo.environment["COLUMNS"],
   let value = Int(columns), (40...400).contains(value) {
    finalWidth = value
}
let drawingWidth = finalWidth ?? 80

// MARK: Read stdin (one document, however it ends)

var stdinData = Data()
let handle = FileHandle.standardInput
while true {
    let chunk = handle.availableData
    if chunk.isEmpty { break }
    stdinData.append(chunk)
}
if stdinData.isEmpty || String(data: stdinData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
    fail(ChartRenderer.ChartError.noInput.description, code: 1)
}

// MARK: Chart it — or say precisely why not.

do {
    let (header, charts) = try ChartRenderer.charts(fromJSON: stdinData)
    // The ASCII tier means ALL of the output, header included.
    let headerLines = ascii
        ? header.map { $0.replacingOccurrences(of: "\u{2014}", with: "-").replacingOccurrences(of: "\u{00B7}", with: ".") }
        : header
    var lines = headerLines
    if charts.isEmpty || charts.allSatisfy({ $0.rows.allSatisfy { $0.value == nil } }) {
        lines.append("")
        lines.append("(nothing to chart — the document carries no plottable values)")
    } else {
        lines.append("")
        lines.append(contentsOf: ChartRenderer.render(charts: charts, width: drawingWidth, ascii: ascii))
    }
    print(lines.joined(separator: "\n"))
} catch let error as ChartRenderer.ChartError {
    fail(error.description, code: 1)
} catch {
    fail("cannot read the document: \(error)", code: 1)
}