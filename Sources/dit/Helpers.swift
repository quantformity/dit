import DirectInvestTracker
import Foundation
#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Shared CLI helpers
//
// Parsing and lookup rules shared across command groups: account
// resolution (with did-you-mean), store opening, scalar parsing.

// MARK: - Account reference resolution (with did-you-mean)

/// Resolve an account reference, softening a misspelled name with a
/// did-you-mean hint when the portfolio contains a close match.
func resolveAccount(_ raw: String, in portfolio: Portfolio) throws -> Account {
    do {
        return try AccountRef(raw).resolve(in: portfolio)
    } catch let error as AccountRef.ResolutionError {
        switch error {
        case .empty:
            throw ParseError("an account name or UUID is required")
        case .notFound(let query):
            let candidates = portfolio.accounts.map(\.displayName)
            if let hint = didYouMean(query, among: candidates) {
                throw LookupError("no account matches '\(query)' — \(hint) — use the exact name (see 'dit accounts') or a UUID prefix")
            }
            throw LookupError("no account matches '\(query)' — use the exact name (see 'dit accounts') "
                + "or a UUID prefix; if this portfolio should have one, start with 'dit account add'")
        case .ambiguous(let query, let matches):
            throw LookupError("'\(query)' is ambiguous — it matches: \(matches.joined(separator: ", ")). "
                + "Use a longer name or the full UUID.")
        }
    }
}

/// Cheap fuzzy match (equality, substring, two-letter prefix) —
/// enough for short account names, no dependencies. Returns nil when
/// nothing is plausibly close, instead of a useless guess.
func didYouMean(_ query: String, among candidates: [String]) -> String? {
    let lowercasedQuery = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard lowercasedQuery.count >= 2 else { return nil }
    var best: String? = nil
    var bestScore = 0
    for candidate in candidates {
        let lowered = candidate.lowercased()
        var score = 0
        if lowered == lowercasedQuery {
            return candidate
        }
        if lowered.contains(lowercasedQuery) || lowercasedQuery.contains(lowered) {
            score = (candidate.count <= 16) ? 3 : 2
        } else if lowered.hasPrefix(String(lowercasedQuery.prefix(2))) {
            score = 1
        }
        if score > bestScore {
            best = candidate
            bestScore = score
        }
    }
    guard bestScore > 0, let hit = best else { return nil }
    return "did you mean '\(hit)'?"
}

// MARK: - Helpers

/// The two-step storage read: the factory decides backend and
/// location (flags merged over environment variables), then the
/// middle layer loads the document.
func openStore(global: Global) throws
    -> (PortfolioStore, DataStoreFactory.Configuration)
{
    var environment = ProcessInfo.processInfo.environment
    if let backend = global.backend { environment[DataStoreFactory.backendKey] = backend }
    if let store = global.store { environment[DataStoreFactory.storeURLKey] = store }
    let factory = DataStoreFactory(environment: environment)
    let configuration = try factory.configuration()
    return (PortfolioStore(store: try factory.make()), configuration)
}

/// Mutations tolerate an empty store: a brand-new user must be able
/// to `account add` / `tx deposit` against nothing at all. Reads keep
/// the friendly "no portfolio yet" message instead.
func portfolioForMutation(global: Global) async throws
    -> (store: PortfolioStore, portfolio: Portfolio)
{
    let (store, configuration) = try openStore(global: global)
    guard let portfolio = try await store.load() else {
        _ = configuration
        return (store, Portfolio())
    }
    return (store, portfolio)
}

// MARK: Entry helpers

func rejectPositionals(_ options: Options, hint: String) throws {
    guard let first = options.positionals.first else { return }
    throw ParseError("unexpected argument '\(first)' — \(hint)")
}

func requireSymbol(_ raw: String) throws -> String {
    let symbol = raw.trimmingCharacters(in: .whitespaces).uppercased()
    guard !symbol.isEmpty else { throw ParseError("--ticker cannot be empty") }
    return symbol
}

/// The currency a new entry is recorded in: `--currency` (known
/// code, case-insensitive) overrides the command's own default.
func entryCurrency(_ options: Options, fallback: Currency) throws -> Currency {
    guard let raw = options["currency"] else { return fallback }
    return try parseCurrency(raw, option: "--currency")
}

func parseCurrency(_ raw: String, option: String) throws -> Currency {
    if let exact = Currency(rawValue: raw), exact != .unknown { return exact }
    if let match = Currency.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }),
       match != .unknown {
        return match
    }
    throw ParseError("unknown currency '\(raw)' for \(option) — use e.g. CAD, USD, JPY, or GBp")
}

/// Entry fee: zero means "no fee", negative is a usage error.
func entryFee(_ options: Options) throws -> Decimal? {
    guard let raw = options["fee"] else { return nil }
    let value = try parseDecimal(raw, option: "--fee")
    guard value >= 0 else { throw ParseError("--fee cannot be negative") }
    return value == 0 ? nil : value
}

/// --rate is a percentage: "4.1" means 4.1 %.
func parseRate(_ raw: String) throws -> Decimal {
    let cleaned = raw.hasSuffix("%") ? String(raw.dropLast()) : raw
    let percent = try parseDecimal(cleaned, option: "--rate")
    guard percent >= 0, percent <= 1000 else {
        throw ParseError("--rate must be a percentage between 0 and 1000 (got '\(raw)')")
    }
    return percent / 100
}

func quoteStamp(_ date: Date?) -> String {
    guard let date else { return "an unknown time" }
    return TextFormat.clock(date)
}

// MARK: - Helpers

/// Lowercased, dashes/underscores removed — so "gic-redeem",
/// "GICRedemption", and "gic_redemption" all match the same thing.
func normalizeToken(_ raw: String) -> String {
    raw.lowercased()
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")
}

let kindAliases: [String: String] = [
    "deposit": "deposit",
    "withdraw": "withdrawal", "withdrawal": "withdrawal",
    "buy": "stockPurchase", "purchase": "stockPurchase", "stockpurchase": "stockPurchase",
    "sell": "stockSale", "stocksale": "stockSale",
    "dividend": "dividend",
    "gic": "gicPurchase", "gicpurchase": "gicPurchase",
    "gicredeem": "gicRedemption", "gicredemption": "gicRedemption",
    "fx": "fxConversion", "fxconversion": "fxConversion",
]

func parseDecimal(_ raw: String, option: String) throws -> Decimal {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, let value = Decimal(string: trimmed) else {
        throw ParseError("invalid number for \(option): '\(raw)'")
    }
    return value
}

func taxableFlag(_ options: Options) throws -> Bool? {
    var answers: [Bool] = []
    if let taxable = options.flag("taxable") { answers.append(taxable) }
    if let nonTaxable = options.flag("non-taxable") { answers.append(!nonTaxable) }
    if Set(answers).count > 1 {
        throw ParseError("--taxable and --non-taxable contradict each other")
    }
    return answers.first
}

func parseDate(_ raw: String) throws -> Date {
    let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
          (1...12).contains(month), (1...31).contains(day),
          let date = utcDate(year: year, month: month, day: day)
    else {
        throw ParseError("invalid date '\(raw)' — expected YYYY-MM-DD")
    }
    return date
}

func utcDate(year: Int, month: Int, day: Int) -> Date? {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 0
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: components)
}

func shortDate(_ date: Date) -> String {
    TextFormat.day(date)
}

func money(_ amount: Decimal, _ currency: Currency) -> String {
    "\(currency.rawValue) \(TextFormat.money(amount))"
}

/// Money without the currency tag — for columns whose header already
/// names the currency.
func amountOnly(_ amount: Decimal) -> String {
    TextFormat.money(amount)
}

func trim(_ amount: Decimal) -> String {
    TextFormat.quantity(amount)
}

/// The strict 60 s freshness rule would blank out every price the
/// moment a market closes — but outside market hours the last
/// close *is* the best known price. So the summary tolerates
/// quotes up to three days old (weekends, holidays) and reports
/// their age here instead of pretending the data is live.
func stalenessNotes(cache: MarketDataCache, symbols: [String]) -> [String] {
    var newest: Date?
    for symbol in symbols {
        if let asOf = cache.quote(for: symbol)?.asOf {
            if newest == nil || asOf > newest! { newest = asOf }
        }
    }
    guard let newest, Date().timeIntervalSince(newest) > 60 else { return [] }
    return ["quote data as of \(TextFormat.clock(newest)) — market may be closed, prices may be stale"]
}

/// A sale below zero is recorded (the cash is a fact) but the short
/// liability it created is outside the model — so it gets stated in
/// the summary's footnotes, never quietly omitted from the totals.
func untrackedShortNotes(_ summary: PortfolioSummary) -> [String] {
    summary.untrackedShorts.map { flag in
        "untracked short: \(flag.accountName) sold \(trim(flag.shares)) \(flag.symbol) "
            + "(\(flag.currency.rawValue)) beyond its holding — cash shows the proceeds, "
            + "the short itself is not tracked, so totals here are incomplete"
    }
}

/// Destructive-operation gate: `--yes` passes; a terminal prompts
/// for the literal word "yes"; a non-interactive run refuses.
func confirm(_ message: String, yes: Bool) -> Bool {
    if yes { return true }
    guard isatty(fileno(stdin)) == 1 else {
        printErr(message)
        printErr("refusing to continue without --yes on a non-interactive terminal")
        exit(1)
    }
    print(message)
    print("Type 'yes' to confirm: ", terminator: "")
    guard let line = readLine() else { return false }
    return line.trimmingCharacters(in: .whitespaces).lowercased() == "yes"
}

func printErr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
