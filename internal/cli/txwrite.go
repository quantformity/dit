package cli

import (
	"bufio"
	"crypto/rand"
	"dit/internal/decimal"
	"dit/internal/ledger"
	"dit/internal/model"
	"dit/internal/mutate"
	"dit/internal/provider"
	"dit/internal/store"
	"dit/internal/text"
	"fmt"
	"github.com/mattn/go-isatty"
	"os"
	"strings"
	"time"
)

var txWriteSpecs = buildTxWriteSpecs()

func buildTxWriteSpecs() Registry {
	r := Registry{}
	for _, verb := range []string{"deposit", "withdraw", "buy", "sell", "dividend", "gic", "gic-redeem", "fx", "edit", "delete"} {
		verb := verb
		values, flags := txWriteOptions(verb)
		r["tx "+verb] = &Spec{Run: func(c Context, args []string) error { return txWrite(c, verb, args) }, ValueOptions: values, FlagOptions: flags, HelpText: txWriteHelp}
	}
	for alias, verb := range map[string]string{"withdrawal": "withdraw", "redeem": "gic-redeem", "remove": "delete"} {
		r["tx "+alias] = r["tx "+verb]
	}
	return r
}
func txWriteOptions(verb string) (map[string]bool, map[string]bool) {
	switch verb {
	case "deposit", "withdraw":
		return setOf("account", "amount", "currency", "date", "fee"), nil
	case "buy", "sell":
		return setOf("account", "ticker", "shares", "price", "currency", "date", "fee"), nil
	case "dividend":
		return setOf("account", "ticker", "amount", "currency", "date", "fee"), nil
	case "gic":
		return setOf("account", "product", "principal", "rate", "compounding", "maturity", "currency"), setOf("redeemable")
	case "gic-redeem":
		return setOf("account", "gic", "proceeds", "currency", "date", "fee"), nil
	case "fx":
		return setOf("account", "from", "to", "from-amount", "to-amount", "date", "fee"), nil
	case "edit":
		return setOf("date", "fee", "amount", "shares", "price", "principal", "rate", "maturity", "compounding", "product", "proceeds", "from-amount", "to-amount"), nil
	default:
		return nil, setOf("yes")
	}
}
func txNumber(raw, key string) (decimal.Decimal, error) {
	// Foundation Decimal(string:) consumes a numeric prefix, not necessarily
	// the whole input. Preserve that slightly surprising CLI contract.
	s := txListTrim(raw)
	end := 0
	if len(s) > 0 && (s[0] == '+' || s[0] == '-') {
		end++
	}
	digits := 0
	for end < len(s) && s[end] >= '0' && s[end] <= '9' {
		end++
		digits++
	}
	if end < len(s) && s[end] == '.' {
		end++
		for end < len(s) && s[end] >= '0' && s[end] <= '9' {
			end++
			digits++
		}
	}
	if digits > 0 && end < len(s) && (s[end] == 'e' || s[end] == 'E') {
		start := end
		end++
		if end < len(s) && (s[end] == '+' || s[end] == '-') {
			end++
		}
		n := end
		for end < len(s) && s[end] >= '0' && s[end] <= '9' {
			end++
		}
		if n == end {
			end = start
		}
	}
	if digits > 0 {
		if v, err := decimal.Parse(s[:end]); err == nil {
			return v, nil
		}
	}
	return decimal.Zero, usage(fmt.Sprintf("invalid number for --%s: '%s'", key, raw))
}
func txDate(raw string) (model.Day, error) {
	d, err := model.ParseDay(raw)
	if err != nil || len(raw) != 10 || d.String() != raw {
		return 0, usage(fmt.Sprintf("invalid date '%s' — expected YYYY-MM-DD", raw))
	}
	return d, nil
}
func txCurrency(raw, key string) (model.Currency, error) {
	for _, c := range model.KnownCurrencies() {
		if string(c) == raw {
			return c, nil
		}
	}
	for _, c := range model.KnownCurrencies() {
		if strings.EqualFold(string(c), raw) {
			return c, nil
		}
	}
	return "", usage(fmt.Sprintf("unknown currency '%s' for --%s — use e.g. CAD, USD, JPY, or GBp", raw, key))
}
func txRate(raw string) (decimal.Decimal, error) {
	v, err := txNumber(strings.TrimSuffix(raw, "%"), "rate")
	if err != nil {
		return v, err
	}
	if v.Sign() < 0 || v.Cmp(decimal.FromInt(1000)) > 0 {
		return v, usage(fmt.Sprintf("--rate must be a percentage between 0 and 1000 (got '%s')", raw))
	}
	return v.Div(decimal.FromInt(100), 38), nil
}
func txCompounding(raw string) (model.GICCompounding, error) {
	normalize := func(s string) string { return strings.NewReplacer("-", "", "_", "").Replace(strings.ToLower(s)) }
	for _, c := range []model.GICCompounding{model.Simple, model.Annual, model.SemiAnnual, model.Monthly, model.Daily} {
		if normalize(string(c)) == normalize(raw) {
			return c, nil
		}
	}
	return "", usage(fmt.Sprintf("unknown compounding '%s' — one of: simple, annual, semiAnnual, monthly, daily", raw))
}
func txHint(query string, candidates []string) string {
	q := strings.ToLower(txListTrim(query))
	if len([]rune(q)) < 2 {
		return ""
	}
	best, score := "", 0
	for _, c := range candidates {
		low := strings.ToLower(c)
		n := 0
		if low == q {
			return c
		}
		if strings.Contains(low, q) || strings.Contains(q, low) {
			n = 2
			if len([]rune(c)) <= 16 {
				n = 3
			}
		} else if strings.HasPrefix(low, string([]rune(q)[:2])) {
			n = 1
		}
		if n > score {
			best, score = c, n
		}
	}
	if score == 0 {
		return ""
	}
	return "did you mean '" + best + "'?"
}
func txWriteAccount(raw string, p *model.Portfolio) (model.Account, error) {
	a, err := txListAccount(raw, p)
	if err == nil {
		return a, nil
	}
	q := txListTrim(raw)
	if q == "" {
		return a, usage("an account name or UUID is required")
	}
	if strings.HasPrefix(err.Error(), "no account matches") {
		var names []string
		for _, a := range p.Accounts {
			names = append(names, DisplayName(a))
		}
		if hint := txHint(q, names); hint != "" {
			return a, Runtime(fmt.Sprintf("no account matches '%s' — %s — use the exact name (see 'dit accounts') or a UUID prefix", q, hint))
		}
		return a, Runtime(fmt.Sprintf("no account matches '%s' — use the exact name (see 'dit accounts') or a UUID prefix; if this portfolio should have one, start with 'dit account add'", q))
	}
	return a, err
}
func txWrite(c Context, verb string, args []string) error {
	values, flags := txWriteOptions(verb)
	o, err := ParseOptions(args, values, flags)
	if err != nil {
		return err
	}
	if verb == "edit" || verb == "delete" {
		return txCorrect(c, verb, o)
	}
	if len(o.Positionals) > 0 {
		hint := map[string]string{"deposit": "the account goes in --account", "withdraw": "the account goes in --account", "buy": "a trade takes only --options (see 'dit help tx')", "sell": "a trade takes only --options (see 'dit help tx')", "dividend": "a dividend takes only --options (see 'dit help tx')", "gic": "a GIC takes only --options (see 'dit help tx')", "gic-redeem": "name the GIC with --gic (see 'dit help tx')", "fx": "a currency conversion takes only --options (see 'dit help tx')"}[verb]
		return usage(fmt.Sprintf("unexpected argument '%s' — %s", o.Positionals[0], hint))
	}
	required := map[string][]string{"deposit": {"account", "amount"}, "withdraw": {"account", "amount"}, "buy": {"account", "ticker", "shares"}, "sell": {"account", "ticker", "shares"}, "dividend": {"account", "ticker", "amount"}, "gic": {"account", "product", "principal", "rate", "maturity"}, "gic-redeem": {"account", "gic", "proceeds"}, "fx": {"account", "from", "to", "from-amount", "to-amount"}}
	for _, key := range required[verb] {
		if _, err := o.Require(key); err != nil {
			return err
		}
	}
	p, err := c.Ledger()
	if err != nil {
		return err
	}
	if p == nil {
		p = &model.Portfolio{}
	}
	a, err := txWriteAccount(o.Value("account"), p)
	if err != nil {
		return err
	}
	id, err := txUUID()
	if err != nil {
		return err
	}
	tx := model.TransactionInstant(model.Transaction{ID: id, AccountID: a.ID, Currency: a.ReportingCurrency}, time.Now())
	var priceNote string
	var purchase model.Transaction
	number := func(key string) (decimal.Decimal, error) { return txNumber(o.Value(key), key) }
	positive := func(key string) (decimal.Decimal, error) {
		v, err := number(key)
		if err == nil && v.Sign() <= 0 {
			err = usage("--" + key + " must be greater than 0")
		}
		return v, err
	}
	symbol := ""
	if verb == "buy" || verb == "sell" || verb == "dividend" {
		symbol = strings.ToUpper(txListTrim(o.Value("ticker")))
		if symbol == "" {
			return usage("--ticker cannot be empty")
		}
		if t := p.TickerBySymbol(symbol); t != nil && t.Currency != model.Unknown {
			tx.Currency = t.Currency
		}
		if p.TickerBySymbol(symbol) == nil {
			var candidates []string
			for _, t := range p.Tickers {
				candidates = append(candidates, t.Symbol)
			}
			if hint := txHint(symbol, candidates); hint != "" {
				noun := "trade"
				if verb == "dividend" {
					noun = "entry"
				}
				fmt.Fprintf(c.Err, "hint: '%s' is not registered — %s; register it with 'dit ticker add %s' (the %s is recorded either way)\n", symbol, hint, symbol, noun)
			}
		}
	}
	switch verb {
	case "deposit", "withdraw":
		amount, e := number("amount")
		if e != nil {
			return e
		}
		kind := model.KindDeposit
		if verb == "withdraw" {
			kind = model.KindWithdrawal
		}
		tx.Kind = model.Kind{Type: kind, Amount: amount}
	case "buy", "sell":
		shares, e := positive("shares")
		if e != nil {
			return e
		}
		var price decimal.Decimal
		if raw, ok := o.Values["price"]; ok {
			price, e = txNumber(raw, "price")
			if e != nil {
				return e
			}
			if price.Sign() < 0 {
				return usage("--price cannot be negative")
			}
			priceNote = text.Quantity(price) + " recorded as entered"
		} else {
			if c.Offline {
				return usage("--price was omitted and --offline is set — prices are only fetched online; pass --price to record this trade")
			}
			backend := provider.Yahoo(provider.YahooConfig{})
			if pin := os.Getenv("DIT_PROVIDER_STUB"); pin != "" {
				backend, e = provider.LoadStub(pin)
				if e != nil {
					return e
				}
			}
			quotes, e := backend.Quotes([]string{symbol})
			if e != nil {
				return Runtime(fmt.Sprintf("price lookup for '%s' failed: %s — pass --price to record a price yourself", symbol, e))
			}
			if len(quotes) == 0 || quotes[0].Price.Sign() <= 0 {
				return Runtime(fmt.Sprintf("no price found for '%s' — check the symbol (Yahoo format: SHOP.TO, AAPL) or pass --price", symbol))
			}
			q := quotes[0]
			price = q.Price
			if q.Currency != model.Unknown {
				tx.Currency = q.Currency
			}
			source := q.Source
			if source == "" {
				source = "yahoo"
			}
			stamp := "an unknown time"
			if q.AsOf != nil {
				stamp = summaryClock(*q.AsOf)
			}
			priceNote = fmt.Sprintf("%s %s via %s as of %s", text.Quantity(price), q.Currency, source, stamp)
		}
		kind := model.KindStockPurchase
		if verb == "sell" {
			kind = model.KindStockSale
		}
		tx.Kind = model.Kind{Type: kind, Stock: &model.StockDetails{Ticker: symbol, Shares: shares, Price: price}}
	case "dividend":
		amount, e := positive("amount")
		if e != nil {
			return e
		}
		tx.Kind = model.Kind{Type: model.KindDividend, Dividend: &model.DividendDetails{Ticker: symbol, Amount: amount}}
	case "gic":
		principal, e := positive("principal")
		if e != nil {
			return e
		}
		comp := model.Annual
		if raw, ok := o.Values["compounding"]; ok {
			comp, e = txCompounding(raw)
			if e != nil {
				return e
			}
		}
		if raw, ok := o.Values["currency"]; ok {
			tx.Currency, e = txCurrency(raw, "currency")
			if e != nil {
				return e
			}
		}
		rate, e := txRate(o.Value("rate"))
		if e != nil {
			return e
		}
		maturity, e := txDate(o.Value("maturity"))
		if e != nil {
			return e
		}
		redeemable := o.Flag("redeemable") != nil && *o.Flag("redeemable")
		tx.Kind = model.Kind{Type: model.KindGICPurchase, GIC: &model.GICDetails{Product: o.Value("product"), Principal: principal, Rate: rate, Compounding: comp, MaturityDate: maturity, Redeemable: redeemable}}
	case "gic-redeem":
		purchase, err = mutate.FindGIC(*p, a.ID, o.Value("gic"))
		if err != nil {
			return err
		}
		proceeds, e := positive("proceeds")
		if e != nil {
			return e
		}
		tx.Currency = purchase.Currency
		tx.Kind = model.Kind{Type: model.KindGICRedemption, Redemption: &model.GICRedemptionDetails{PurchaseID: purchase.ID, Proceeds: proceeds}}
	case "fx":
		from, e := txCurrency(o.Value("from"), "from")
		if e != nil {
			return e
		}
		to, e := txCurrency(o.Value("to"), "to")
		if e != nil {
			return e
		}
		if from == to {
			return usage("--from and --to must differ — that is not a conversion")
		}
		fa, e := number("from-amount")
		if e != nil {
			return e
		}
		ta, e := number("to-amount")
		if e != nil {
			return e
		}
		if fa.Sign() <= 0 || ta.Sign() <= 0 {
			return usage("--from-amount and --to-amount must both be greater than 0 — both sides of a conversion are facts you know")
		}
		tx.Currency = to
		tx.Kind = model.Kind{Type: model.KindFXConversion, FX: &model.FXDetails{FromCurrency: from, FromAmount: fa, ToAmount: ta}}
	}
	// Swift evaluates date, currency, then fee for instrument entries;
	// cash entries evaluate currency and fee before their date.
	order := []string{"date", "currency", "fee"}
	if verb == "deposit" || verb == "withdraw" {
		order = []string{"currency", "fee", "date"}
	}
	for _, key := range order {
		raw, ok := o.Values[key]
		if !ok {
			continue
		}
		switch key {
		case "date":
			day, e := txDate(raw)
			if e != nil {
				return e
			}
			tx = model.TransactionDate(tx, day)
		case "currency":
			tx.Currency, err = txCurrency(raw, key)
			if err != nil {
				return err
			}
		case "fee":
			v, e := txNumber(raw, key)
			if e != nil {
				return e
			}
			if v.Sign() < 0 && verb != "deposit" && verb != "withdraw" {
				return usage("--fee cannot be negative")
			}
			if v.Sign() != 0 {
				tx.Fee = &v
			}
		}
	}
	updated, notes, err := mutate.Add(*p, tx)
	if err != nil {
		return err
	}
	if err = txSave(c, &updated); err != nil {
		return err
	}
	if priceNote != "" {
		c.printf("price: %s\n", priceNote)
	}
	for _, note := range notes {
		c.printf("%s\n", note)
	}
	if verb == "withdraw" {
		for _, note := range notes {
			if strings.HasPrefix(note, "warning") {
				c.printf("(recorded anyway — the ledger records what happened, not what should fit)\n")
				break
			}
		}
	}
	if verb == "sell" {
		short := tx.Kind.Stock.Shares.Sub(mutate.Shares(*p, a.ID, symbol, nil))
		if short.Sign() > 0 {
			c.printf("warning: '%s' ends up SHORT %s %s — double-check that this sale happened\n", DisplayName(a), text.Quantity(short), symbol)
		}
	}
	if verb == "gic" {
		d := tx.Kind.GIC
		early := "not permitted"
		if d.Redeemable {
			early = "allowed"
		}
		c.printf("recorded as compounding %s, early redemption %s — correct with 'dit tx edit <id>' if that is wrong\n", d.Compounding, early)
	}
	if verb == "gic-redeem" {
		c.printf("against '%s' [%s]\n", ledger.SummaryLine(purchase), ledger.ShortID(purchase.ID))
		remaining := purchase.Kind.GIC.Principal.Sub(tx.Kind.Redemption.Proceeds)
		if remaining.Sign() > 0 {
			c.printf("warning: a redemption ENDS the GIC here — the remaining %s %s of principal is booked as gone with this redemption (all-or-nothing model). If only part came back, delete this redemption and record what actually happened instead\n", text.Quantity(remaining), purchase.Currency)
		}
	}
	return nil
}
func txUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%X-%X-%X-%X-%X", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}
func txSave(c Context, p *model.Portfolio) error {
	s, _, err := c.Stores()
	if err != nil {
		return err
	}
	return store.SavePortfolio(s, p)
}

func txCorrect(c Context, verb string, o Options) error {
	if len(o.Positionals) == 0 {
		if verb == "delete" {
			return usage("usage: dit tx delete <id> [--yes]")
		}
		return usage("usage: dit tx edit <id> [value options] — see 'dit help tx'")
	}
	p, err := c.Ledger()
	if err != nil {
		return err
	}
	if p == nil {
		p = &model.Portfolio{}
	}
	tx, err := txListResolve(o.Positionals[0], p)
	if err != nil {
		return err
	}
	var updated model.Portfolio
	var notes []string
	if verb == "delete" {
		updated, notes, err = mutate.Delete(*p, tx)
		if err != nil {
			return err
		}
		if yes := o.Flag("yes"); yes == nil || !*yes {
			impact := fmt.Sprintf("This will remove '%s %s'.\n", tx.Date, ledger.SummaryLine(tx))
			var lines []string
			for _, note := range notes[1:] {
				lines = append(lines, "  "+note)
			}
			impact += strings.Join(lines, "\n")
			if !isatty.IsTerminal(os.Stdin.Fd()) {
				fmt.Fprintln(c.Err, impact)
				return confirmationRefusal("refusing to continue without --yes on a non-interactive terminal")
			}
			c.printf("%s\nType 'yes' to confirm: ", impact)
			line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
			if !strings.EqualFold(txListTrim(strings.TrimSuffix(line, "\n")), "yes") {
				c.printf("cancelled\n")
				return nil
			}
		}
	} else {
		if raw, ok := o.Values["date"]; ok {
			day, e := txDate(raw)
			if e != nil {
				return e
			}
			tx = model.TransactionDate(tx, day)
		}
		if raw, ok := o.Values["fee"]; ok {
			v, e := txNumber(raw, "fee")
			if e != nil {
				return e
			}
			tx.Fee = nil
			if v.Sign() != 0 {
				tx.Fee = &v
			}
		}
		changed, e := txEditedKind(&tx, o)
		if e != nil {
			return e
		}
		_, date := o.Values["date"]
		_, fee := o.Values["fee"]
		if !changed && !date && !fee {
			return usage(fmt.Sprintf("nothing to edit — pass --date, --fee, or a value option valid for kind '%s'", tx.Kind.Type))
		}
		updated, notes, err = mutate.Edit(*p, tx)
		if err != nil {
			return err
		}
	}
	if err = txSave(c, &updated); err != nil {
		return err
	}
	for _, note := range notes {
		c.printf("%s\n", note)
	}
	return nil
}
func txEditedKind(tx *model.Transaction, o Options) (bool, error) {
	all := []string{"amount", "shares", "price", "principal", "rate", "maturity", "compounding", "product", "proceeds", "from-amount", "to-amount"}
	allowed := map[model.KindType][]string{model.KindDeposit: {"amount"}, model.KindWithdrawal: {"amount"}, model.KindDividend: {"amount"}, model.KindStockPurchase: {"shares", "price"}, model.KindStockSale: {"shares", "price"}, model.KindGICPurchase: {"principal", "rate", "maturity", "compounding", "product"}, model.KindGICRedemption: {"proceeds"}, model.KindFXConversion: {"from-amount", "to-amount"}}
	keys := allowed[tx.Kind.Type]
	var rejected []string
	for _, key := range all {
		if _, used := o.Values[key]; !used {
			continue
		}
		valid := false
		for _, a := range keys {
			if a == key {
				valid = true
			}
		}
		if tx.Kind.Type == model.KindGICRedemption && (key == "shares" || key == "price" || key == "maturity" || key == "compounding" || key == "product") {
			valid = true
		}
		if !valid {
			rejected = append(rejected, "--"+key)
		}
	}
	if len(rejected) > 0 {
		return false, usage(fmt.Sprintf("%s does not apply to '%s' — edits change values within the same kind only; to record a different event, delete this one and add the right one", strings.Join(rejected, ", "), tx.Kind.Type))
	}
	// Payloads must be copied before an edit: the loaded portfolio is immutable.
	k := tx.Kind
	if k.Stock != nil {
		v := *k.Stock
		k.Stock = &v
	}
	if k.Dividend != nil {
		v := *k.Dividend
		k.Dividend = &v
	}
	if k.GIC != nil {
		v := *k.GIC
		k.GIC = &v
	}
	if k.Redemption != nil {
		v := *k.Redemption
		k.Redemption = &v
	}
	if k.FX != nil {
		v := *k.FX
		k.FX = &v
	}
	changed := false
	for _, key := range keys {
		raw, ok := o.Values[key]
		if !ok {
			continue
		}
		changed = true
		if key == "product" {
			k.GIC.Product = raw
			continue
		}
		if key == "maturity" {
			v, e := txDate(raw)
			if e != nil {
				return false, e
			}
			k.GIC.MaturityDate = v
			continue
		}
		if key == "compounding" {
			v, e := txCompounding(raw)
			if e != nil {
				return false, e
			}
			k.GIC.Compounding = v
			continue
		}
		var v decimal.Decimal
		var err error
		if key == "rate" {
			v, err = txRate(raw)
		} else {
			v, err = txNumber(raw, key)
		}
		if err != nil {
			return false, err
		}
		switch key {
		case "amount":
			if k.Dividend != nil {
				k.Dividend.Amount = v
			} else {
				k.Amount = v
			}
		case "shares":
			k.Stock.Shares = v
		case "price":
			k.Stock.Price = v
		case "principal":
			k.GIC.Principal = v
		case "rate":
			k.GIC.Rate = v
		case "proceeds":
			k.Redemption.Proceeds = v
		case "from-amount":
			k.FX.FromAmount = v
		case "to-amount":
			k.FX.ToAmount = v
		}
	}
	tx.Kind = k
	return changed, nil
}
