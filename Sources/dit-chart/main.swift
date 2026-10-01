import Foundation
import DitCore

// dit-chart — chart renderer for machine documents (a pipe tool).
//
//   dit --json | dit-chart                    ASCII/Unicode bar charts
//   dit --json | dit-chart --ascii            plain glyph tier
//   dit --json | dit-chart --html out.html    interactive page (self-contained)
//   dit --json | dit-chart --html out.html --open   … and open it
//   dit --json | dit-chart --svg x.svg        refused (use --html)
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
var htmlPath: String? = nil
var openAfter = false
let arguments = Array(CommandLine.arguments.dropFirst())
var cursor = arguments.startIndex
while cursor < arguments.endIndex {
    let argument = arguments[cursor]
    switch argument {
    case "--ascii":
        ascii = true
        cursor += 1
    case "--html":
        guard cursor + 1 < arguments.endIndex, !arguments[cursor + 1].hasPrefix("--")
        else { fail("--html needs an output file path (use --html - to print the page)", code: 2) }
        htmlPath = arguments[cursor + 1]
        cursor += 2
    case "--open":
        openAfter = true
        cursor += 1
    case "--width":
        guard cursor + 1 < arguments.endIndex, let value = Int(arguments[cursor + 1]),
              (40...400).contains(value)
        else { fail("--width needs a number between 40 and 400", code: 2) }
        width = value
        cursor += 2
    case "--svg":
        fail("svg output is not implemented — interactive charts use --html PATH (one self-contained file, any browser)", code: 2)
    case "--help", "-h":
        print("""
              USAGE: dit [--json …] | dit-chart [--ascii] [--width N]
                                                    [--html PATH] [--open]

                Reads one JSON document from stdin (typically the output
                of 'dit … --json') and charts it as terminal text or as
                one self-contained HTML file.

                --ascii      plain glyph tier (#, ^, ?) instead of the
                             default Unicode blocks (█ ✕ ▲); terminal
                             mode only
                --width N    terminal drawing width (default: COLUMNS
                             environment, else 80); ignored by --html
                --html PATH  write an interactive page (hover tooltips,
                             line charts for quote series) instead of
                             printing; PATH "-" prints the page instead
                --open       after --html, open the page in the system
                             viewer (open/xdg-open)
                --svg PATH   not implemented — refuses instead of
                             silently ignoring (use --html)

                Chartable: summary/1 (bars, all modes); quote/1 series
                (line charts) in --html. Everything else is refused.
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

if openAfter && htmlPath == nil {
    fail("--open needs --html PATH (nothing to open without a written page)", code: 2)
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

if let path = htmlPath {
    do {
        let page = try ChartHTML.document(fromJSON: stdinData)
        let url = path == "-"
            ? nil
            : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if let url {
            do {
                try page.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                fail("cannot write \(url.path): \(error)", code: 1)
            }
            print("wrote \(url.path)")
            if openAfter {
                // System viewer; a missing viewer is reported, not fatal
                // — the page exists and prints its own path above.
                let launcher: (String, [String]) -> Void = { exe, args in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: exe)
                    process.arguments = args
                    try? process.run()
                }
                #if os(macOS)
                launcher("/usr/bin/open", [url.path])
                #elseif os(Linux)
                launcher("/usr/bin/xdg-open", [url.path])
                #else
                FileHandle.standardError.write(Data("dit-chart: no system opener here — open \(url.path) manually\n".utf8))
                #endif
            }
        } else {
            print(page)
        }
        exit(0)
    } catch let error as ChartRenderer.ChartError {
        fail(error.description, code: 1)
    } catch {
        fail("cannot read the document: \(error)", code: 1)
    }
}

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