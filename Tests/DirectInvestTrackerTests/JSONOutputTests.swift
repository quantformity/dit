import Foundation
import Testing
@testable import DirectInvestTracker

/// Pins the MACHINE-READABLE contract (`--json`). These are not
/// formatting trivia: agents parse these documents, so key names,
/// decimal-string money, null-vs-zero semantics and provenance fields
/// are load-bearing. If one of these tests breaks, the schema changed —
/// update docs/json.md and bump the schema version, never silently.
/// File-scope UTC calendar + day helper shared by fixtures and tests.
private let machineIso = Calendar(identifier: .gregorian)
private func machineDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
    machineIso.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("JSONOutput")
struct JSONOutputTests {

    private static func parse(_ text: String) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    // MARK: Fixtures — one mixed-currency portfolio, exact numbers

    /// TD (CAD): 100 ENB.TO @ 40, quoted 40.8 (real prior close 40.0).
    /// QT (USD): 60 NVDA @ 180, quoted 178 (DERIVED prior close 180).
    /// Rate USD→CAD 1.40.
    private struct Fixture {
        let now = machineDay(2026, 9, 29).addingTimeInterval(3600)
        let yesterday = machineDay(2026, 9, 28)

        var portfolio: Portfolio {
            let td = Account(reportingCurrency: .cad, name: "TD")
            let qt = Account(reportingCurrency: .usd, name: "QT")
            func dep(_ a: Account, _ amount: Decimal) -> Transaction {
                Transaction(date: machineDay(2026, 6, 1), accountID: a.id,
                            currency: a.reportingCurrency, kind: .deposit(amount: amount))
            }
            func buy(_ a: Account, _ sym: String, _ shares: Decimal, _ price: Decimal) -> Transaction {
                Transaction(date: machineDay(2026, 6, 2), accountID: a.id,
                            currency: a.reportingCurrency,
                            kind: .stockPurchase(StockDetails(ticker: sym, shares: shares, price: price)))
            }
            return Portfolio(accounts: [td, qt],
                             transactions: [dep(td, 10_000), buy(td, "ENB.TO", 100, 40),
                                            dep(qt, 12_000), buy(qt, "NVDA", 60, 180)],
                             tickers: [EquityTicker(symbol: "ENB.TO", name: "Enbridge")])
        }

        func cache(withRates: Bool = true) -> MarketDataCache {
            let cache = MarketDataCache()
            cache.upsert(MarketQuote(symbol: "ENB.TO", currency: .cad, price: Decimal(string: "40.8")!,
                                     asOf: now, source: "test"))
            cache.upsert(MarketQuote(symbol: "NVDA", currency: .usd, price: 178, asOf: now, source: "test"))
            if withRates {
                cache.upsert(ExchangeRate(base: .usd, quote: .cad, rate: Decimal(string: "1.40")!,
                                          asOf: now, source: "test"))
            }
            return cache
        }

        var market: MarketData {
            var data = MarketData()
            data.series["ENB.TO"] = PriceSeries(symbol: "ENB.TO", currency: .cad,
                                                 points: [DailyPrice(day: yesterday, price: 40)])
            data.series["NVDA"] = PriceSeries(symbol: "NVDA", currency: .usd,
                                               points: [DailyPrice(day: yesterday, price: 180,
                                                                    via: "derived via TSLA ÷ 16.2645")])
            return data
        }
    }

    // MARK: summary/1

    @Test func summaryDocumentIsValidJsonWithExactNumbers() throws {
        let f = Fixture()
        let summary = f.portfolio.summary(from: f.cache(), market: f.market,
                                           maxAge: 3 * 86_400, now: f.now)
        let text = JSONOutput.summaryJSON(summary, cache: f.cache(), market: f.market,
                                          maxAge: 3 * 86_400, now: f.now,
                                          storePath: "/tmp/store", warnings: [],
                                          offline: false, degraded: false)
        let doc = try #require(try JSONOutputTests.parse(text))
        #expect(doc["ok"] as? Bool == true)
        #expect(doc["schema"] as? String == "summary/1")
        let data = try #require(doc["data"] as? [String: Any])
        let totals = try #require(data["totals"] as? [String: Any])
        // −120 USD × 1.40 + 80 CAD = −88 CAD, as a decimal STRING.
        #expect(totals["dayChange"] as? String == "-88.00")
        let holdings = try #require(data["holdings"] as? [[String: Any]])
        #expect(holdings.count == 2)
        let nvda = try #require(holdings.first { ($0["symbol"] as? String) == "NVDA" })
        #expect(nvda["pnlDisplay"] as? String == "-168.00")   // converted to CAD
        #expect(nvda["dayChangeDisplay"] as? String == "-168.00")
        #expect(nvda["pnl"] as? String == "-120.00")          // native kept, labeled by ccy
        #expect(nvda["ccy"] as? String == "USD")
        let quote = try #require(nvda["quote"] as? [String: Any])
        let previous = try #require(quote["previousClose"] as? [String: Any])
        // Provenance as data: this baseline was DERIVED, and the doc says so.
        #expect(previous["via"] as? String == "derived via TSLA ÷ 16.2645")
        #expect(previous["date"] as? String == "2026-09-28")
        let enb = try #require(holdings.first { ($0["symbol"] as? String) == "ENB.TO" })
        let enbQuote = try #require(enb["quote"] as? [String: Any])
        let enbPrev = try #require(enbQuote["previousClose"] as? [String: Any])
        #expect(enbPrev["via"] is NSNull)                     // nil == OBSERVED
    }

    @Test func unconvertibleValuesAreNullAndNeverAReformattedNativeAmount() throws {
        let f = Fixture()
        // No FX rate at all: the USD holding cannot be shown in CAD —
        // the display fields must be null, not the native number.
        let summary = f.portfolio.summary(from: f.cache(withRates: false), maxAge: 3 * 86_400, now: f.now)
        let text = JSONOutput.summaryJSON(summary, cache: f.cache(withRates: false), market: nil,
                                          maxAge: 3 * 86_400, now: f.now,
                                          storePath: "/tmp/store", warnings: [],
                                          offline: false, degraded: false)
        let doc = try #require(try JSONOutputTests.parse(text))
        let data = try #require(doc["data"] as? [String: Any])
        let holdings = try #require(data["holdings"] as? [[String: Any]])
        let nvda = try #require(holdings.first { ($0["symbol"] as? String) == "NVDA" })
        #expect(nvda["valueDisplay"] is NSNull)
        #expect(nvda["pnlDisplay"] is NSNull)
        #expect(nvda["dayChangeDisplay"] is NSNull)
        #expect(nvda["dayChange"] is NSNull)                   // no market data → no day figures
        #expect(nvda["value"] as? String == "10680.00")           // native, no grouping marks
        let totals = try #require(data["totals"] as? [String: Any])
        #expect(totals["totalValue"] is NSNull)                // unconvertible, not a fake total
        let byCurrency = try #require(totals["byCurrency"] as? [String: Any])
        #expect(byCurrency["USD"] != nil)                      // exact per-currency layer survives
    }

    @Test func outputIsByteStableAndSingleLine() {
        let f = Fixture()
        let summary = f.portfolio.summary(from: f.cache(), market: f.market,
                                           maxAge: 3 * 86_400, now: f.now)
        let a = JSONOutput.summaryJSON(summary, cache: f.cache(), market: f.market,
                                       maxAge: 3 * 86_400, now: f.now,
                                       storePath: "/tmp/store", warnings: [],
                                       offline: false, degraded: false)
        let b = JSONOutput.summaryJSON(summary, cache: f.cache(), market: f.market,
                                       maxAge: 3 * 86_400, now: f.now,
                                       storePath: "/tmp/store", warnings: [],
                                       offline: false, degraded: false)
        #expect(a == b)
        #expect(!a.contains("\n"))
    }

    // MARK: account/1

    @Test func accountDocumentCarriesFullTxIdsAndCostBasisLabel() throws {
        let account = Account(reportingCurrency: .cad, name: "TD Direct")
        let deposit = Transaction(date: machineDay(2026, 1, 2), accountID: account.id,
                                  currency: .cad, kind: .deposit(amount: 10_000))
        let buy = Transaction(date: machineDay(2026, 1, 9), accountID: account.id, currency: .cad,
                              kind: .stockPurchase(StockDetails(ticker: "SHOP.TO", shares: 100,
                                                                 price: Decimal(string: "60")!)))
        let portfolio = Portfolio(accounts: [account], transactions: [deposit, buy])
        let balances = AccountBalances.compute(account: account,
                                               transactions: portfolio.transactions(in: account.id))
        let history = portfolio.transactions(in: account.id)
            .map { ($0.id.uuidString, $0.date, $0.kindName, $0.summaryLine, $0.currency.rawValue) }
        let text = JSONOutput.accountJSON(account: account, balances: balances, history: history)
        let doc = try #require(try JSONOutputTests.parse(text))
        let data = try #require(doc["data"] as? [String: Any])
        let positions = try #require(data["positions"] as? [[String: Any]])
        #expect(positions.first?["costBasis"] as? String == "6000.00")
        #expect(positions.first?["ccy"] as? String == "CAD")
        let rows = try #require(data["history"] as? [[String: Any]])
        #expect(rows.count == 2)
        // FULL uuids — table output truncates, machine output must not.
        #expect(rows.allSatisfy { (($0["id"] as? String)?.count == 36) ?? false })
    }

    // MARK: quote/1 + envelopes

    @Test func storedQuoteDocumentSeparatesObservedDerivedAndMissing() throws {
        let text = JSONOutput.storedQuotesJSON(asOf: "2026-03-11", storePath: "/tmp/market", rows: [
            ("TSLA.NE", "34.06", "CAD", "2026-03-11", 0, "derived", "derived via TSLA ÷ 16.2645"),
            ("TSLA", "341.07", "USD", "2026-03-11", 0, "observed", nil),
            ("GHOST", nil, nil, nil, nil, "none", nil),
        ])
        let doc = try #require(try JSONOutputTests.parse(text))
        let data = try #require(doc["data"] as? [String: Any])
        let quotes = try #require(data["quotes"] as? [[String: Any]])
        #expect(quotes.count == 3)
        #expect(quotes[0]["basis"] as? String == "derived")
        #expect(quotes[1]["via"] is NSNull)
        #expect(quotes[2]["price"] is NSNull)
    }

    @Test func seriesQuoteDocumentCarriesPointsAndMarkers() throws {
        let text = JSONOutput.seriesQuotesJSON(
            from: "2026-09-23", to: "2026-09-26", storePath: "/tmp/market",
            rows: [
                ("TSLA", "2026-09-23", "380.12", "USD", "observed", nil),
                ("TSLA", "2026-09-25", "372.11", "USD", "observed", nil),
                ("TSLA.NE", "2026-09-23", "32.7002", "CAD", "derived", "derived via TSLA ÷ 16.396"),
                ("GHOST", nil, nil, nil, "none", nil),
            ], pointCount: 3)
        let doc = try #require(try JSONOutputTests.parse(text))
        #expect(doc["schema"] as? String == "quote/1")
        let data = try #require(doc["data"] as? [String: Any])
        #expect(data["mode"] as? String == "series")
        #expect(data["count"] as? Int == 3)
        #expect(data["from"] as? String == "2026-09-23")
        let quotes = try #require(data["quotes"] as? [[String: Any]])
        #expect(quotes.count == 4)  // three points + one missing marker
        #expect(quotes[0]["via"] is NSNull)
        #expect(quotes[2]["basis"] as? String == "derived")
        // Missing symbol is a parsed value, never a fabricated 0.00.
        #expect(quotes[3]["price"] is NSNull)
        #expect(quotes[3]["basis"] as? String == "none")
    }

    @Test func errorEnvelopeKeepsTheSingleParsePath() throws {
        let text = JSONOutput.errorEnvelope(kind: "usage", message: "unknown option --nope")
        let doc = try #require(try JSONOutputTests.parse(text))
        #expect(doc["ok"] as? Bool == false)
        #expect(doc["kind"] as? String == "usage")
        #expect(doc["error"] as? String == "unknown option --nope")
    }

    // MARK: Formatters

    @Test func moneyKeepsDecimalsExactAndUnmarkedByGrouping() {
        #expect(JSONOutput.money(Decimal(string: "1067011.4")!) == "1067011.40")
        #expect(JSONOutput.money(Decimal(string: "-6179.004")!) == "-6179.00")
        #expect(JSONOutput.fraction(Decimal(string: "0.015325")!) == "0.0153")
        #expect(JSONOutput.quantity(Decimal(string: "96.7")!) == "96.7")
        #expect(JSONOutput.quantity(1260) == "1260")
        #expect(JSONOutput.rate(Decimal(string: "1.4187")!) == "1.418700")
    }
}
