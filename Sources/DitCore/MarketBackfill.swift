import Foundation

// MARK: - Derived-history backfill
//
// Some instruments have no usable daily price source at all — the NEO
// `.NE` trackers in this portfolio are exact examples: Yahoo answers a
// live quote but serves no daily series for them. What they *do* have
// is an underlying: `TSLA.NE` is worth roughly one `TSLA` share divided
// by a fixed ratio, converted at the day's USD→CAD rate.
//
// This file implements that approximation, deliberately labelled as one:
//
//   observed on a day where BOTH prices exist:
//       ratio = sourcePrice × fx ÷ targetPrice
//   everywhere the target was NOT observed:
//       derivedPrice = sourcePrice(day) × fx(day) ÷ meanRatio
//
// Honesty rules the engine will not bend:
// - Calibration uses only *real* observations (points with no `via`
//   tag, plus today's live quote when it pairs); derived values never
//   calibrate themselves.
// - Real observations are never overwritten — fills happen only on
//   days the target has no real close.
// - Every synthesized point carries a `via` provenance tag; nothing
//   here pretends to be fetched data.
// - The result is a model, so its error is reported: calibration
//   spread and any de-coupling warning print with the fill.

/// A backfill run that refuses to guess. Thrown when there is nothing
/// honest to calibrate on, no source data, or the currencies cannot be
/// determined; the CLI reports these as failures (exit 1), never as a
/// silent partial answer.
public struct DerivationError: Error, CustomStringConvertible {
    /// The reason, phrased for the CLI (a refusal that does not
    /// explain itself reads as a crash).
    public let message: String
    /// Wraps a message; single-case style refusal type — the whole
    /// backfill feature refuses with exactly this error.
    public init(_ message: String) { self.message = message }
    /// Printed verbatim on exit 1 (no "Error: while…" wrapper).
    public var description: String { message }
}

extension MarketUpdater {

    /// Derive the missing daily history of `targetSymbol` from
    /// `sourceSymbol` (e.g. `TSLA.NE` from `TSLA`, converted through
    /// the daily USD/CAD series when the trading currencies differ).
    ///
    /// The run has three phases:
    /// 1. **Sources** — make sure the store holds a daily series for
    ///    the source (and the FX pair when needed), fetching from the
    ///    provider when missing (unless `allowNetwork` is false).
    /// 2. **Calibration** — average `sourcePrice × fx ÷ targetPrice`
    ///    over every day where the target itself was really observed
    ///    (stored real closes + today's live quote). `ratioOverride`
    ///    skips calibration and pins the ratio by hand.
    /// 3. **Fill** — for every weekday inside the target's holding
    ///    windows that has no real close, store
    ///    `sourcePrice × fx ÷ ratio` tagged `derived via …`; a rerun
    ///    recomputes those (they are model output, not data) but
    ///    leaves real points alone.
    public func backfillHistory(portfolio: Portfolio,
                                targetSymbol: String,
                                sourceSymbol: String,
                                ratioOverride: Decimal? = nil,
                                allowNetwork: Bool = true,
                                dryRun: Bool = false,
                                now: Date = .now) async throws -> MarketUpdateReport {
        var report = MarketUpdateReport()
        let target = targetSymbol.trimmingCharacters(in: .whitespaces).uppercased()
        let source = sourceSymbol.trimmingCharacters(in: .whitespaces).uppercased()

        guard target != source else {
            throw DerivationError("'\(target)' cannot be derived from itself")
        }
        guard portfolio[ticker: target] != nil else {
            throw DerivationError("no registry entry for '\(target)' — backfill takes the trading currency from the registry ('dit ticker add \(target) --currency …' first)")
        }
        guard portfolio[ticker: source] != nil else {
            throw DerivationError("no registry entry for '\(source)' — the source ticker needs a known trading currency ('dit ticker add \(source) --currency USD')")
        }
        let todayDay = DailyPrice.utcDay(now)
        guard let windows = portfolio.holdingWindows(through: now)[target],
              !windows.isEmpty else {
            throw DerivationError("'\(target)' was never held in any account — there is no holding window to backfill")
        }
        let windowStart = windows.map(\.start).min()!

        var data = try await store.load()
        var targetCcy = portfolio[ticker: target]!.currency
        if targetCcy == .unknown,
           let quote = data.latestQuotes.first(where: { $0.symbol == target }),
           quote.currency != .unknown {
            targetCcy = quote.currency
        }
        var sourceCcy = portfolio[ticker: source]!.currency
        if sourceCcy == .unknown, let series = data.series[source], series.currency != .unknown {
            sourceCcy = series.currency
        }
        guard targetCcy != .unknown, sourceCcy != .unknown else {
            throw DerivationError("cannot tell which currencies '\(target)' and '\(source)' trade in — set them with 'dit ticker edit … --currency …'")
        }

        // MARK: Phase 1 — the derivation sources must exist in the store

        func storedSeries(_ symbol: String) -> PriceSeries? { data.series[symbol] }

        if storedSeries(source) == nil {
            guard allowNetwork else {
                throw DerivationError("no stored daily history for '\(source)' and the network is off — run 'dit market history' (or drop --offline) first")
            }
            report.seriesFetched += 1
            let fetched = try await provider.dailySeries(source, from: windowStart, to: todayDay)
            guard !fetched.points.isEmpty else {
                throw DerivationError("the provider has no daily history for '\(source)' — nothing to derive '\(target)' from")
            }
            data.mergeSeries(symbol: source,
                             currency: fetched.currency == .unknown ? sourceCcy : fetched.currency,
                             points: fetched.points, through: todayDay)
            report.lines.append("fetched \(fetched.points.count) daily closes for '\(source)' (derivation source)")
        }
        guard let sourceSeries = storedSeries(source) else { return report }

        var fxSeries: PriceSeries?
        var fxLabel = ""
        if sourceCcy != targetCcy {
            guard let pairTicker = sourceCcy.quoteTicker(against: targetCcy) else {
                throw DerivationError("no exchange-rate key between \(sourceCcy.rawValue) and \(targetCcy.rawValue)")
            }
            let pairKey = "\(sourceCcy.rawValue)/\(targetCcy.rawValue)"
            fxLabel = pairKey
            fxSeries = storedSeries(pairKey)
            if fxSeries == nil {
                guard allowNetwork else {
                    throw DerivationError("no stored daily \(pairKey) rates and the network is off — run 'dit market history' (or drop --offline) first")
                }
                report.seriesFetched += 1
                let fetched = try await provider.dailySeries(pairTicker, from: windowStart, to: todayDay)
                guard !fetched.points.isEmpty else {
                    throw DerivationError("the provider has no daily \(pairKey) rates — cannot convert \(sourceCcy.rawValue) prices to \(targetCcy.rawValue)")
                }
                data.mergeSeries(symbol: pairKey, currency: targetCcy,
                                 points: fetched.points, through: todayDay)
                report.lines.append("fetched \(fetched.points.count) daily \(pairKey) rates (derivation source)")
                fxSeries = storedSeries(pairKey)
            }
        }

        // Same-day source close (no carry-forward: a stale model input
        // on a day the market was shut is worse than an honest gap).
        func sourceClose(on day: Date) -> Decimal? {
            sourceSeries.points.first { $0.day == day }?.price
        }
        // FX prefers the same day; a rate up to three days old still
        // converts (FX quotes on weekends; equity closes do not).
        func fxRate(on day: Date) -> Decimal? {
            guard sourceCcy != targetCcy else { return 1 }
            guard let fxSeries else { return nil }
            if let exact = fxSeries.points.first(where: { $0.day == day }) { return exact.price }
            guard let last = fxSeries.points.last(where: { $0.day <= day }),
                  day.timeIntervalSince(last.day) <= 3 * 86_400 else { return nil }
            return last.price
        }

        // MARK: Phase 2 — calibrate the ratio from real observations only

        var ratio: Decimal
        let ratioString: String
        let viaLabel: String

        if let override = ratioOverride {
            ratio = override
            ratioString = Self.trim(override)
            viaLabel = "derived via \(source) ÷ \(ratioString)"
            report.lines.append("ratio override: 1 '\(target)' unit ≈ 1 '\(source)' unit ÷ \(ratioString) (calibration skipped)")
        } else {
            var anchorRatios: [(label: String, ratio: Decimal)] = []
            var skippedReal = 0
            var usedDays: Set<Date> = []

            if let series = storedSeries(target) {
                for point in series.points where point.via == nil {
                    usedDays.insert(point.day)
                    guard point.price > 0,
                          let close = sourceClose(on: point.day),
                          let fx = fxRate(on: point.day) else {
                        skippedReal += 1
                        continue
                    }
                    anchorRatios.append((Self.stampDay(point.day), close * fx / point.price))
                }
            }
            // Today's live quote is a real observation too — count it
            // when its day is not already covered by a stored close.
            if let quote = data.latestQuotes.first(where: { $0.symbol == target }),
               quote.currency == targetCcy, let asOf = quote.asOf, quote.price > 0 {
                let day = DailyPrice.utcDay(asOf)
                if !usedDays.contains(day),
                   let close = sourceClose(on: day),
                   let fx = fxRate(on: day) {
                    anchorRatios.append((Self.stampDay(day) + " (live quote)", close * fx / quote.price))
                }
            }

            guard !anchorRatios.isEmpty else {
                throw DerivationError("no common days where '\(target)' was really quoted next to '\(source)' — seed real closes ('dit market import') or pass --ratio R")
            }
            let sum = anchorRatios.reduce(Decimal(0)) { $0 + $1.ratio }
            ratio = Self.rounded(sum / Decimal(anchorRatios.count), scale: 6)
            ratioString = Self.trim(ratio)
            viaLabel = "derived via \(source) ÷ \(ratioString)"

            let list = anchorRatios.map { "\($0.label) \(Self.trim($0.ratio))" }.joined(separator: ", ")
            report.lines.append("ratio calibrated on \(anchorRatios.count) common day(s): \(list)")
            report.lines.append("mean ratio = \(ratioString) ('\(target)' price = '\(source)' × \(fxLabel.isEmpty ? "1:1" : fxLabel) ÷ ratio)")
            if skippedReal > 0 {
                report.lines.append("(\(skippedReal) real observation(s) skipped — no same-day '\(source)' close or \(fxLabel.isEmpty ? "no" : fxLabel + " ")rate)")
            }
            if anchorRatios.count >= 2,
               let minR = anchorRatios.map(\.ratio).min(),
               let maxR = anchorRatios.map(\.ratio).max() {
                let spread = (maxR - minR) / (sum / Decimal(anchorRatios.count))
                if spread > 0.02 {
                    let pct = Self.rounded(spread * 100, scale: 1)
                    report.failures.append("calibration spread is \(pct)% of the mean — '\(target)' has been de-coupling from '\(source)'; the derived history will drift with it")
                }
            }
        }
        ratio = Self.rounded(ratio, scale: 6)

        // MARK: Phase 3 — fill the gaps, weekdays only

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var windowDays: [Date] = []
        for window in windows {
            var day = window.start
            let end = min(window.end, todayDay)
            while day <= end {
                let weekday = calendar.component(.weekday, from: day)
                if weekday != 1 && weekday != 7 { windowDays.append(day) }
                day = day.addingTimeInterval(86_400)
            }
        }

        // Real observations are kept verbatim; every other weekday of
        // the holding window gets the model's answer. Old derived
        // values are re-derived (a cheaper place to keep stale model
        // output than a current one).
        var byDay: [Date: DailyPrice] = [:]
        for point in (storedSeries(target)?.points ?? []) where point.via == nil {
            byDay[point.day] = point
        }
        let keptReal = byDay.count

        var filledNew = 0, unchanged = 0, emptyDays = 0
        for day in windowDays where byDay[day] == nil {
            guard let close = sourceClose(on: day), let fx = fxRate(on: day) else {
                emptyDays += 1
                continue
            }
            let price = Self.rounded(close * fx / ratio, scale: 4)
            let previous = storedSeries(target)?.points.first { $0.day == day && $0.via != nil }?.price
            if previous != price { filledNew += 1 } else { unchanged += 1 }
            byDay[day] = DailyPrice(day: day, price: price, via: viaLabel)
        }

        report.pointsStored = filledNew
        var newSeries = PriceSeries(symbol: target, currency: targetCcy,
                                    points: Array(byDay.values))
        newSeries.coveredThrough = storedSeries(target)?.coveredThrough
        data.series[target] = newSeries
        data.updatedAt = now

        var fillLine = "backfilled \(filledNew) day(s) of '\(target)' from '\(source)'"
        if !fxLabel.isEmpty { fillLine += " × \(fxLabel)" }
        fillLine += " ÷ \(ratioString) — \(keptReal) real close(s) kept"
        if unchanged > 0 { fillLine += ", \(unchanged) derived value(s) unchanged" }
        if emptyDays > 0 { fillLine += ", \(emptyDays) weekday(s) had no same-day source data (left empty)" }
        report.lines.append(fillLine)
        if dryRun {
            report.lines.append("dry run — nothing written")
        } else {
            try await store.save(data)
        }
        return report
    }

    // MARK: Helpers

    private static func rounded(_ value: Decimal, scale: Int) -> Decimal {
        let behavior = NSDecimalNumberHandler(roundingMode: .plain, scale: Int16(scale),
                                              raiseOnExactness: false, raiseOnOverflow: false,
                                              raiseOnUnderflow: false, raiseOnDivideByZero: false)
        return NSDecimalNumber(decimal: value).rounding(accordingToBehavior: behavior).decimalValue
    }
}

// MARK: - CSV series import (the seeding path)

extension MarketData {
    /// Parses `SYMBOL,YYYY-MM-DD,PRICE` lines (comments with `#` and
    /// header lines are skipped, blank lines ignored). One file may
    /// carry several series, including FX pairs keyed `"USD/CAD"`.
    /// Unparsable lines become reported problems, never failures.
    public static func parseSeriesCSV(_ text: String)
        -> (entries: [(symbol: String, day: Date, price: Decimal)], problems: [String])
    {
        var entries: [(symbol: String, day: Date, price: Decimal)] = []
        var problems: [String] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        for (index, rawLine) in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.count == 3, fields[1].lowercased() == "date" { continue } // header
            guard fields.count == 3 else {
                problems.append("line \(index + 1): expected 'SYMBOL,YYYY-MM-DD,PRICE', got '\(line)'")
                continue
            }
            let symbol = fields[0].uppercased()
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-/")
            guard symbol.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                problems.append("line \(index + 1): unreadable symbol '\(fields[0])'")
                continue
            }
            let dateParts = fields[1].split(separator: "-").compactMap { Int($0) }
            guard dateParts.count == 3, dateParts[1] >= 1, dateParts[1] <= 12, dateParts[2] >= 1, dateParts[2] <= 31,
                  let day = calendar.date(from: {
                      var components = DateComponents()
                      components.year = dateParts[0]; components.month = dateParts[1]; components.day = dateParts[2]
                      return components
                  }()) else {
                problems.append("line \(index + 1): bad date '\(fields[1])' (want YYYY-MM-DD)")
                continue
            }
            guard let price = Decimal(string: fields[2]), price > 0 else {
                problems.append("line \(index + 1): bad price '\(fields[2])'")
                continue
            }
            entries.append((symbol: symbol, day: day, price: price))
        }
        return (entries, problems)
    }
}