import Foundation

/// A minimal aligned-text table: two spaces between columns, first
/// column left-aligned by default, the rest right-aligned. Deterministic
/// (no locale-dependent measurement) so the same summary always renders
/// the same way.
public enum Table {
    public static func render(headers: [String], rows: [[String]], leftColumns: Set<Int> = [0]) -> [String] {
        let columns = headers.count
        let widths = (0..<columns).map { column in
            ([headers[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0
        }
        func format(_ cells: [String]) -> String {
            (0..<columns).map { column in
                let cell = cells[column]
                let pad = String(repeating: " ", count: widths[column] - cell.count)
                return leftColumns.contains(column) ? cell + pad : pad + cell
            }
            .joined(separator: "  ")
        }
        var lines = [format(headers)]
        lines.append(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
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

    private static let moneyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let sharesFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 4
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateStyle = .medium
        f.timeStyle = .short
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

        // --- Header + grand totals -----------------------------------
        lines.append("Portfolio summary — \(dateFormatter.string(from: date))  (display: \(display))")
        lines.append("")
        lines.append("  Total value      \(money(summary.totalValue, display))")
        lines.append("  Cash             \(money(summary.cash, display))")
        lines.append("  Positions        \(money(summary.positionValue, display))")
        lines.append("  GICs (at par)    \(money(summary.gicValue, display))")
        lines.append("")
        lines.append("  Unrealized P&L   \(money(summary.unrealizedPnL, display))")
        lines.append("  Realized P&L     \(money(summary.realizedPnL, display))")
        lines.append("  Dividends        \(money(summary.dividends, display))")

        // --- Per-currency breakdown (exact, conversion-free) ----------
        lines.append("")
        lines.append("By currency:")
        let byCurrency = summary.valueByCurrency.keys.sorted()
        if byCurrency.isEmpty {
            lines.append("  —")
        } else {
            let rows = byCurrency.map { currency in
                let cash = summary.cashByCurrency[currency] ?? 0
                let positions = summary.positionValueByCurrency[currency] ?? 0
                let gic = summary.gicValueByCurrency[currency] ?? 0
                let total = summary.valueByCurrency[currency] ?? 0
                return [
                    currency.rawValue,
                    money2(cash), money2(positions), money2(gic), money2(total)
                ]
            }
            lines.append(contentsOf: Table.render(
                headers: ["Ccy", "Cash", "Positions", "GIC", "Total"],
                rows: rows
            ))
        }

        // --- Per-account table ----------------------------------------
        lines.append("")
        lines.append("Accounts:")
        if summary.accounts.isEmpty {
            lines.append("  —")
        } else {
            let rows = summary.accounts.map { balance in
                [
                    accountName(balance.account),
                    balance.account.reportingCurrency.rawValue,
                    money2(balance.cash),
                    money2(positionValueOf(balance)),
                    money2(balance.gicValue),
                    money2(balance.totalValue),
                    money2(balance.unrealizedPnL)
                ]
            }
            lines.append(contentsOf: Table.render(
                headers: ["Name", "Ccy", "Cash", "Positions", "GIC", "Total", "Unrealized"],
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
            let rows = summary.holdings.map { holding in
                let last: String
                if holding.unrealizedPnL != nil, holding.shares != 0 {
                    last = money2(holding.value / holding.shares)
                } else {
                    last = "—"
                }
                return [
                    holding.symbol,
                    holding.name ?? "",
                    holding.currency.rawValue,
                    shares(holding.shares),
                    money2(holding.averageCostPerShare),
                    last,
                    money2(holding.value),
                    money2(holding.unrealizedPnL),
                    holding.accountNames.joined(separator: ", ")
                ]
            }
            lines.append(contentsOf: Table.render(
                headers: ["Symbol", "Name", "Ccy", "Shares", "Avg cost", "Last", "Value", "P&L", "Where"],
                rows: rows,
                leftColumns: [0, 1]
            ))
        }

        // --- Footnotes ---------------------------------------------------
        var allNotes = notes
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
        return moneyFormatter.string(from: NSDecimalNumber(decimal: value)) ?? String(describing: value)
    }

    private static func shares(_ value: Decimal) -> String {
        sharesFormatter.string(from: NSDecimalNumber(decimal: value)) ?? String(describing: value)
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