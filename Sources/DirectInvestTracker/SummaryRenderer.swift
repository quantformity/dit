import Foundation

/// A Markdown pipe table: `| cell | cell |` lines with a `---`
/// separator (right-aligned columns use `---:`). Cells are padded to
/// the widest value so the table reads aligned in a raw terminal AND
/// renders as a table in Markdown viewers — one renderer, both jobs.
/// Pipes inside data are escaped (`\|`) so account names cannot tear
/// a row apart. Deterministic (no locale-dependent measurement) so
/// the same summary always renders the same way.
public enum Table {
    /// Render a full table (header + separator rule included) with
    /// columns aligned to the widest cell per column.
    public static func render(headers: [String], rows: [[String]], leftColumns: Set<Int> = [0]) -> [String] {
        let columns = headers.count
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|")
        }
        let widths = (0..<columns).map { column in
            ([headers[column]] + rows.map { $0[column] }).map { escape($0).count }.max() ?? 0
        }
        func format(_ cells: [String]) -> String {
            let body = (0..<columns).map { column -> String in
                let cell = escape(cells[column])
                let pad = String(repeating: " ", count: widths[column] - cell.count)
                return " " + (leftColumns.contains(column) ? cell + pad : pad + cell) + " "
            }
            .joined(separator: "|")
            return "|" + body + "|"
        }
        var lines = [format(headers)]
        // The separator carries the alignment: `---:` marks the columns
        // that read right-aligned, so viewers and raw text agree on
        // which figures are money and which are labels.
        let separator = (0..<columns).map { column -> String in
            let dashes = max(3, widths[column])
            let rule = leftColumns.contains(column)
                ? String(repeating: "-", count: dashes)
                : String(repeating: "-", count: max(2, dashes - 1)) + ":"
            return " " + rule + " "
        }
        .joined(separator: "|")
        lines.append("|" + separator + "|")
        for row in rows { lines.append(format(row)) }
        return lines
    }
}

/// Renders a ``PortfolioSummary`` as a plain-text report for terminals.
///
/// Numbers use fixed `en_US`-style grouping (thousands separators) so
/// output is deterministic across machines; localizing formatting is a
/// future concern.
public enum SummaryRenderer {

    /// Percent RETURN for holdings: input is a fraction (0.123 renders
    /// "+12.3%"). Positive values carry an explicit "+" so a column of
    /// mixed results is readable at a glance.
    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    /// Render the summary report.
    ///
    /// - Parameters:
    ///   - summary: the snapshot to render.
    ///   - date: timestamp shown in the header (default now).
    ///   - notes: caller-provided footnotes (e.g. "offline mode",
    ///     fetch failures). Derived notes (unquoted positions,
    ///     unconverted totals) are appended automatically.
    public static func render(
        _ summary: PortfolioSummary,
        date: Date = Date.now,
        notes: [String] = []
    ) -> String {
        let display = summary.displayCurrency.rawValue
        var lines: [String] = []

        // Daily-change columns appear only where a real pair exists
        // (a quote and an earlier stored close). Without market data —
        // offline runs, fresh stores — the tables keep their old shape
        // instead of showing a column of meaningless dashes.
        let showDay = summary.holdings.contains { $0.dayChange != nil }
        // A "value in display currency" column only says something when
        // at least one holding is priced in another currency.
        let showConverted = summary.holdings.contains { $0.currency != summary.displayCurrency }

        // --- Header + grand totals -----------------------------------
        lines.append("Portfolio summary — \(TextFormat.clock(date))  (display: \(display))")
        lines.append("")
        lines.append("  Total value      \(money(summary.totalValue, display))")
        lines.append("  Cash             \(money(summary.cash, display))")
        lines.append("  Positions        \(money(summary.positionValue, display))")
        lines.append("  GICs (at par)    \(money(summary.gicValue, display))")
        lines.append("")
        lines.append("  Unrealized P&L   \(money(summary.unrealizedPnL, display))")
        if showDay {
            lines.append("  Day change       \(money(summary.dayChange, display))   (vs previous close)")
        }
        lines.append("  Realized P&L     \(money(summary.realizedPnL, display))")
        lines.append("  Dividends        \(money(summary.dividends, display))")

        // --- Per-currency breakdown (exact, conversion-free) ----------
        lines.append("")
        lines.append("By currency:")
        let byCurrency = summary.valueByCurrency.keys.sorted()
        if byCurrency.isEmpty {
            lines.append("  —")
        } else {
            let rows = byCurrency.map { currency -> [String] in
                let cash = summary.cashByCurrency[currency] ?? 0
                let positions = summary.positionValueByCurrency[currency] ?? 0
                let gic = summary.gicValueByCurrency[currency] ?? 0
                let total = summary.valueByCurrency[currency] ?? 0
                var row = [
                    currency.rawValue,
                    money2(cash), money2(positions), money2(gic), money2(total)
                ]
                if showDay { row.append(money2(summary.dayChangeByCurrency[currency])) }
                return row
            }
            var headers = ["Ccy", "Cash", "Positions", "GIC", "Total"]
            if showDay { headers.append("Day") }
            lines.append(contentsOf: Table.render(headers: headers, rows: rows))
        }

        // --- Per-account table ----------------------------------------
        lines.append("")
        lines.append("Accounts:")
        if summary.accounts.isEmpty {
            lines.append("  —")
        } else {
            let rows = summary.accounts.map { balance -> [String] in
                var row = [
                    accountName(balance.account),
                    balance.account.reportingCurrency.rawValue,
                    money2(balance.cash),
                    money2(positionValueOf(balance)),
                    money2(balance.gicValue),
                    money2(balance.totalValue),
                    money2(balance.unrealizedPnL)
                ]
                if showDay { row.append(money2(balance.dayChange)) }
                return row
            }
            var headers = ["Name", "Ccy", "Cash", "Positions", "GIC", "Total", "Unrealized"]
            if showDay { headers.append("Day") }
            lines.append(contentsOf: Table.render(
                headers: headers,
                rows: rows,
                leftColumns: [0]
            ))
        }

        // --- Holdings table --------------------------------------------
        lines.append("")
        lines.append("Holdings:")
        if summary.holdings.isEmpty {
            lines.append("  —")
        } else {
            let rows = summary.holdings.map { holding -> [String] in
                let last: String
                if holding.unrealizedPnL != nil, holding.shares != 0 {
                    last = money2(holding.value / holding.shares)
                } else {
                    last = "—"
                }
                // Percent RETURN, not a price ratio: P&L ÷ cost basis,
                // computed in the position's own currency (the same
                // currency P&L and cost were accumulated in), so FX
                // movement cannot masquerade as trading gain. Dashed —
                // never guessed — when there is no real quote (P&L was
                // cost-basis fiction), or the cost basis is zero or
                // negative (untracked shorts), where a percentage
                // would be meaningless.
                let pnlPct: String
                if let pnl = holding.unrealizedPnL, holding.shares > 0, holding.costBasis > 0 {
                    pnlPct = percent(pnl / holding.costBasis)
                } else {
                    pnlPct = "—"
                }
                var row: [String] = [
                    holding.symbol,
                    holding.name ?? "",
                    holding.currency.rawValue,
                    shares(holding.shares),
                    money2(holding.averageCostPerShare),
                    last,
                    // Native value carries its currency code: in a
                    // mixed-currency table an unmarked number is not
                    // self-describing.
                    "\(holding.currency.rawValue) \(money2(holding.value))"
                ]
                if showConverted {
                    row.append(money2(holding.valueInDisplayCurrency))
                }
                if showDay {
                    // Money columns in this table speak the display
                    // currency (the % right beside them is a native-
                    // currency ratio — see the footnote); unconvertible
                    // → dashed, never a silent native-currency leak.
                    row.append(money2(holding.dayChangeInDisplayCurrency))
                    row.append(holding.dayChangeFraction.map(percent) ?? "—")
                }
                row.append(contentsOf: [money2(holding.unrealizedPnLInDisplayCurrency), pnlPct,
                                        holding.accountNames.joined(separator: ", ")])
                return row
            }
            var headers = ["Symbol", "Name", "Ccy", "Shares", "Avg cost", "Last", "Value"]
            if showConverted { headers.append("Value (\(display))") }
            if showDay { headers.append(contentsOf: ["Day (\(display))", "Day%"]) }
            headers.append(contentsOf: ["P&L (\(display))", "P&L%", "Where"])
            lines.append(contentsOf: Table.render(
                headers: headers,
                rows: rows,
                leftColumns: [0, 1]
            ))
        }

        // --- Footnotes ---------------------------------------------------
        var allNotes = notes
        if showConverted {
            allNotes.append("Value (\(display)), Day (\(display)) and P&L (\(display)) are converted at the current FX rate; Day% and P&L% stay native-currency ratios so FX movement cannot masquerade as trading gain")
        }
        if showDay {
            allNotes.append("day change = latest quote vs the previous stored close of the same ticker (a model comparison where history is derived)")
        }
        let modelDaySymbols = summary.holdings
            .filter { $0.dayChange != nil && $0.dayChangeModelBaseline }
            .map(\.symbol).sorted()
        if !modelDaySymbols.isEmpty {
            allNotes.append("day change for \(modelDaySymbols.joined(separator: ", ")) mirrors the underlying's move through a derived proxy — it is not a real quote of these tickers")
        }
        for holding in summary.holdings where holding.unrealizedPnL == nil {
            allNotes.append("\(holding.symbol) (\(holding.currency.rawValue)) valued at cost basis — no fresh quote")
        }
        if [summary.totalValue, summary.cash, summary.positionValue, summary.gicValue]
            .contains(where: { $0 == nil }) {
            allNotes.append("some totals are unconverted — see the per-currency breakdown")
        }
        if !allNotes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            for note in allNotes { lines.append("  - \(note)") }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: Formatting

    /// A combined (display-currency) amount, or a dash when `nil`
    /// (unconvertible / no data).
    private static func money(_ value: Decimal?, _ display: String) -> String {
        value.map { String(format: "%@ %@", money2($0), display) } ?? "—"
    }

    private static func money2(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        return TextFormat.money(value)
    }

    /// "+12.3%" / "-4.0%" / "+0.0%" from a fraction; the sign is always
    /// explicit so zeros and negatives never look alike.
    private static func percent(_ fraction: Decimal) -> String {
        let text = percentFormatter.string(from: NSDecimalNumber(decimal: fraction))
            ?? String(describing: fraction)
        return fraction >= 0 ? "+" + text : text
    }

    private static func shares(_ value: Decimal) -> String {
        TextFormat.quantity(value)
    }

    private static func accountName(_ account: Account) -> String {
        if let name = account.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return "Account \(account.id.uuidString.prefix(4))"
    }

    /// Position value in the account's reporting currency: `nil` when
    /// the account's own balance could not combine (unconvertible).
    private static func positionValueOf(_ balance: AccountBalances) -> Decimal? {
        // totalValue = cash + positions + gic — recover the position
        // component; if any part is missing so is the whole value.
        guard let total = balance.totalValue, let cash = balance.cash, let gic = balance.gicValue else {
            return nil
        }
        return total - cash - gic
    }
}