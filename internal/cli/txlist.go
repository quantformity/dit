package cli

import (
	"fmt"
	"strconv"
	"strings"
	"unicode"

	"dit/internal/decimal"
	"dit/internal/ledger"
	"dit/internal/model"
	"dit/internal/text"
)

var txListSpecs = Registry{
	"tx list": {Run: txList, ValueOptions: setOf("account", "kind", "ticker", "since", "until", "limit"), FlagOptions: setOf()},
	"tx ls":   {Run: txList, ValueOptions: setOf("account", "kind", "ticker", "since", "until", "limit"), FlagOptions: setOf()},
	"tx show": {Run: txShow, ValueOptions: setOf(), FlagOptions: setOf()},
}

func txList(c Context, args []string) error {
	o, err := ParseOptions(args, setOf("account", "kind", "ticker", "since", "until", "limit"), nil)
	if err != nil {
		return err
	}
	if len(o.Positionals) > 0 {
		return usage(fmt.Sprintf("unexpected argument '%s' — filter with --account/--kind/--ticker (or 'dit tx show <id>')", o.Positionals[0]))
	}
	p, err := c.Ledger()
	if err != nil {
		return err
	}
	if p == nil {
		c.printf("No portfolio found (store: %s at %s).\n", c.Layout.Backend, c.Layout.PortfolioDir)
		return nil
	}
	v := ledger.ViewOptions{}
	scope := "all accounts"
	if raw, ok := o.Values["account"]; ok {
		account, err := txListAccount(raw, p)
		if err != nil {
			return err
		}
		v.AccountID = &account.ID
		scope = "'" + DisplayName(account) + "'"
	}
	if raw, ok := o.Values["kind"]; ok {
		aliases := map[string]model.KindType{
			"deposit": model.KindDeposit, "withdraw": model.KindWithdrawal, "withdrawal": model.KindWithdrawal,
			"buy": model.KindStockPurchase, "purchase": model.KindStockPurchase, "stockpurchase": model.KindStockPurchase,
			"sell": model.KindStockSale, "stocksale": model.KindStockSale, "dividend": model.KindDividend,
			"gic": model.KindGICPurchase, "gicpurchase": model.KindGICPurchase, "gicredeem": model.KindGICRedemption,
			"gicredemption": model.KindGICRedemption, "fx": model.KindFXConversion, "fxconversion": model.KindFXConversion,
		}
		normalized := strings.NewReplacer("-", "", "_", "").Replace(strings.ToLower(raw))
		kind, found := aliases[normalized]
		if !found {
			return usage(fmt.Sprintf("unknown kind '%s' — one of: deposit, withdrawal, buy, sell, dividend, gic, gic-redeem, fx (or the canonical names)", raw))
		}
		v.Kind = &kind
	}
	if raw, ok := o.Values["ticker"]; ok {
		symbol := strings.ToUpper(txListTrim(raw))
		v.Ticker = &symbol
	}
	for _, key := range []string{"since", "until"} {
		if raw, ok := o.Values[key]; ok {
			day, err := model.ParseDay(raw)
			if err != nil || len(raw) != 10 || day.String() != raw {
				return usage(fmt.Sprintf("invalid date '%s' — expected YYYY-MM-DD", raw))
			}
			if key == "since" {
				v.Since = &day
			} else {
				day += 86399 // Inclusive through the specified UTC day, as in Swift.
				v.Until = &day
			}
		}
	}
	if raw, ok := o.Values["limit"]; ok {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 {
			return usage(fmt.Sprintf("--limit needs a positive number (got '%s')", raw))
		}
		v.Limit = &n
	}
	if ledger.StatementMode(v) {
		return txStatement(c, p, v, scope)
	}
	transactions := ledger.PlainTransactions(p, v)
	c.printf("Transactions — %s (%d shown)\n", scope, len(transactions))
	if len(transactions) == 0 {
		return nil
	}
	var rows [][]string
	for _, tx := range transactions {
		rows = append(rows, []string{ledger.ShortID(tx.ID), tx.Date.String(), txListAccountName(p, tx.AccountID), string(tx.Kind.Type), ledger.SummaryLine(tx)})
	}
	txListTable(c, []string{"ID", "Date", "Account", "Kind", "Detail"}, rows, 5)
	return nil
}

func txStatement(c Context, p *model.Portfolio, v ledger.ViewOptions, scope string) error {
	statement := ledger.Rows(p, v)
	c.printf("Transactions — %s (%d shown — statement view)\n", scope, len(statement))
	if len(statement) == 0 {
		return nil
	}
	currencies := ledger.Currencies(statement)
	split := len(currencies) >= 2 && len(currencies) <= 4
	headers := []string{"ID", "Date", "Account", "Detail", "Debit", "Credit"}
	if split {
		for _, currency := range currencies {
			headers = append(headers, "Bal "+string(currency))
		}
	} else {
		headers = append(headers, "Balance after")
	}
	var rows [][]string
	for _, row := range statement {
		tx := row.Transaction
		cells := []string{ledger.ShortID(tx.ID), tx.Date.String(), txListAccountName(p, tx.AccountID), ledger.SummaryLine(tx), txListMoneyEntries(row.Debits, true), txListMoneyEntries(row.Credits, false)}
		if split {
			for _, currency := range currencies {
				balance := "—"
				for _, entry := range row.CashAfter {
					if entry.Currency == currency {
						balance = txListAmount(entry.Amount)
						break
					}
				}
				cells = append(cells, balance)
			}
		} else {
			balance := txListMoneyEntries(row.CashAfter, false)
			if balance == "" {
				balance = "—"
			}
			cells = append(cells, balance)
		}
		rows = append(rows, cells)
	}
	txListTable(c, headers, rows, 4)
	c.printf("\n")
	if split {
		c.printf("  Debit/Credit/Bal columns are cash, derived on the fly — nothing is\n  stored, and positions or GICs never appear in a cash column. Each\n  'Bal CCY' column is THAT account's running cash in that currency\n  (never summed across accounts); '—' means no cash in that currency at\n  that point. Any filter (--kind/--ticker/--since/--until/--limit)\n  gives the plain list instead.\n")
	} else {
		c.printf("  Debit/Credit/Balance are cash, derived on the fly — nothing is\n  stored, and positions or GICs never appear in a cash column. Balance =\n  cash left in THAT account (per currency) after the event. Any filter\n  (--kind/--ticker/--since/--until/--limit) gives the plain list instead.\n")
	}
	return nil
}

func txListMoney(amount decimal.Decimal, currency model.Currency) string {
	return string(currency) + " " + txListAmount(amount)
}

// Foundation's display formatter uses ties-to-even, while decimal.Round is
// intentionally half-away for arithmetic. Only exact half-cent ties differ.
func txListAmount(amount decimal.Decimal) string {
	_, fraction, _ := strings.Cut(amount.String(), ".")
	if len(fraction) > 2 && fraction[2] == '5' && strings.Trim(fraction[3:], "0") == "" && (fraction[1]-'0')%2 == 0 {
		rounded := amount.Round(2)
		cent := decimal.MustParse("0.01")
		if amount.Sign() < 0 {
			rounded = rounded.Add(cent)
		} else {
			rounded = rounded.Sub(cent)
		}
		result := text.Money(rounded)
		if amount.Sign() < 0 && rounded.Sign() == 0 {
			result = "-" + result
		}
		return result
	}
	return text.Money(amount)
}

func txListMoneyEntries(entries []ledger.Money, debit bool) string {
	parts := make([]string, 0, len(entries))
	for _, entry := range entries {
		value := txListMoney(entry.Amount, entry.Currency)
		if debit {
			value = "-" + value
		}
		parts = append(parts, value)
	}
	return strings.Join(parts, " ")
}

// The statement and plain listings left-align their label columns, exactly
// as the reference passes leftColumns to the shared table renderer; numeric
// columns keep Table's native right alignment. Header bold follows the
// reference's terminal policy (bold on a terminal, plain when piped).
func txListTable(c Context, headers []string, rows [][]string, leftCount int) {
	left := map[int]bool{}
	for col := 0; col < leftCount; col++ {
		left[col] = true
	}
	for _, line := range text.Table(headers, rows, left, boldHeaders(c)) {
		c.printf("  %s\n", line)
	}
}

func txShow(c Context, args []string) error {
	o, err := ParseOptions(args, nil, nil)
	if err != nil {
		return err
	}
	if len(o.Positionals) == 0 {
		return usage("usage: dit tx show <id>")
	}
	p, err := c.Ledger()
	if err != nil {
		return err
	}
	if p == nil {
		return Runtime("no portfolio found at " + c.Layout.PortfolioDir)
	}
	tx, err := txListResolve(o.Positionals[0], p)
	if err != nil {
		return err
	}
	c.printf("Transaction:\n  ID:        %s\n  Date:      %s\n  Account:   %s\n  Currency:  %s\n  Details:   %s\n", strings.ToUpper(tx.ID), tx.Date, txListAccountName(p, tx.AccountID), tx.Currency, ledger.SummaryLine(tx))
	if d := tx.Kind.GIC; tx.Kind.Type == model.KindGICPurchase && d != nil {
		redemption := "not permitted"
		if d.Redeemable {
			redemption = "allowed"
		}
		c.printf("  Terms:     compounds %s, early redemption %s\n", d.Compounding, redemption)
	}
	fee := "—"
	if tx.Fee != nil {
		fee = txListMoney(*tx.Fee, tx.Currency)
	}
	c.printf("  Fee:       %s\n", fee)
	return nil
}

func txListTrim(raw string) string {
	return strings.TrimFunc(raw, func(r rune) bool { return unicode.IsSpace(r) && r != '\n' && r != '\r' })
}
func txListHex(raw string) string { return strings.ToUpper(strings.ReplaceAll(raw, "-", "")) }
func txListLooksHex(raw string) bool {
	if len(raw) < 4 {
		return false
	}
	for _, r := range raw {
		if !(r >= '0' && r <= '9' || r >= 'A' && r <= 'F') {
			return false
		}
	}
	return true
}
func txListResolve(raw string, p *model.Portfolio) (model.Transaction, error) {
	query := txListTrim(raw)
	if query == "" {
		return model.Transaction{}, Runtime("empty transaction reference")
	}
	hex := txListHex(query)
	var matches []model.Transaction
	if txListLooksHex(hex) {
		for _, tx := range p.Transactions {
			id := txListHex(tx.ID)
			if id == hex {
				return tx, nil
			}
			if strings.HasPrefix(id, hex) {
				matches = append(matches, tx)
			}
		}
	}
	if len(matches) == 1 {
		return matches[0], nil
	}
	if len(matches) == 0 {
		return model.Transaction{}, Runtime(fmt.Sprintf("no transaction matches '%s' — use the ID shown by 'dit tx list' (full UUID or unique prefix)", query))
	}
	var labels []string
	for i, tx := range matches {
		if i == 4 {
			break
		}
		labels = append(labels, ledger.SummaryLine(tx)+" ["+ledger.ShortID(tx.ID)+"]")
	}
	return model.Transaction{}, Runtime(fmt.Sprintf("'%s' is ambiguous — it matches: %s", query, strings.Join(labels, " | ")))
}
func txListAccountName(p *model.Portfolio, id string) string {
	if account := p.AccountByID(id); account != nil {
		return DisplayName(*account)
	}
	return "—"
}
func txListAccount(raw string, p *model.Portfolio) (model.Account, error) {
	query := txListTrim(raw)
	if query == "" {
		return model.Account{}, Runtime("empty account reference")
	}
	hex := txListHex(query)
	var matches []model.Account
	if txListLooksHex(hex) {
		for _, account := range p.Accounts {
			id := txListHex(account.ID)
			if id == hex {
				return account, nil
			}
			if strings.HasPrefix(id, hex) {
				matches = append(matches, account)
			}
		}
	}
	if len(matches) == 0 {
		for _, account := range p.Accounts {
			if account.Name != nil && strings.EqualFold(txListTrim(*account.Name), query) {
				matches = append(matches, account)
			}
		}
	}
	if len(matches) == 1 {
		return matches[0], nil
	}
	if len(matches) == 0 {
		return model.Account{}, Runtime(fmt.Sprintf("no account matches '%s' — use the exact account name (see 'dit accounts') or a UUID prefix", query))
	}
	var names []string
	for _, account := range matches {
		names = append(names, DisplayName(account))
	}
	return model.Account{}, Runtime(fmt.Sprintf("'%s' is ambiguous — it matches: %s. Use a longer name or the full UUID.", query, strings.Join(names, ", ")))
}
