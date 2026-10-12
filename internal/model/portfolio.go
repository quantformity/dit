package model

import (
	"encoding/json"
	"strings"

	"dit/internal/decimal"
)

// Portfolio is the root of the persisted portfolio document: everything the
// tool knows about accounts, events and instruments. It is the unit of
// storage, and the transaction log inside it is the source of truth.
type Portfolio struct {
	// Accounts in creation order; display sorts by name.
	Accounts []Account
	// Transactions is the event log, appended or edited only via mutations.
	Transactions []Transaction
	// Tickers is the instrument registry (optional display metadata).
	Tickers []EquityTicker
}

// portfolioWire mirrors the Swift decoder's leniency: a section that is simply
// absent means "empty", so a document saved before a section existed still
// loads. A section that is present but malformed is still an error.
type portfolioWire struct {
	Accounts     []Account      `json:"accounts"`
	Transactions []Transaction  `json:"transactions"`
	Tickers      []EquityTicker `json:"tickers"`
}

// UnmarshalJSON accepts a stored document with any subset of sections.
func (p *Portfolio) UnmarshalJSON(data []byte) error {
	var wire portfolioWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	p.Accounts = wire.Accounts
	if p.Accounts == nil {
		p.Accounts = []Account{}
	}
	p.Transactions = wire.Transactions
	if p.Transactions == nil {
		p.Transactions = []Transaction{}
	}
	p.Tickers = wire.Tickers
	if p.Tickers == nil {
		p.Tickers = []EquityTicker{}
	}
	return nil
}

// MarshalJSON writes the three sections, each as an array even when empty,
// which is what the Swift encoder does.
func (p Portfolio) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		Accounts     []Account      `json:"accounts"`
		Transactions []Transaction  `json:"transactions"`
		Tickers      []EquityTicker `json:"tickers"`
	}{orEmptyAccounts(p.Accounts), orEmptyTransactions(p.Transactions), orEmptyTickers(p.Tickers)})
}

func orEmptyAccounts(in []Account) []Account {
	if in == nil {
		return []Account{}
	}
	return in
}

func orEmptyTransactions(in []Transaction) []Transaction {
	if in == nil {
		return []Transaction{}
	}
	return in
}

func orEmptyTickers(in []EquityTicker) []EquityTicker {
	if in == nil {
		return []EquityTicker{}
	}
	return in
}

// AccountByID finds an account by exact id. A missing account returns nil so
// that dangling references stay reportable instead of crashing.
func (p Portfolio) AccountByID(id string) *Account {
	for i := range p.Accounts {
		if sameID(p.Accounts[i].ID, id) {
			return &p.Accounts[i]
		}
	}
	return nil
}

// TickerBySymbol finds a registry entry, using the same normalization as
// everywhere else (" shop.to " finds "SHOP.TO").
func (p Portfolio) TickerBySymbol(symbol string) *EquityTicker {
	normalized := NormalizeSymbol(symbol)
	for i := range p.Tickers {
		if p.Tickers[i].Symbol == normalized {
			return &p.Tickers[i]
		}
	}
	return nil
}

// AccountName returns the display name for listings, or an em dash when the id
// matches no account — history must still render if its account vanished.
func (p Portfolio) AccountName(id string) string {
	if account := p.AccountByID(id); account != nil {
		if account.Name != nil && *account.Name != "" {
			return *account.Name
		}
		return account.ID
	}
	return "—"
}

// TransactionsIn returns the account's transactions in storage order.
func (p Portfolio) TransactionsIn(accountID string) []Transaction {
	out := make([]Transaction, 0, len(p.Transactions))
	for _, transaction := range p.Transactions {
		if sameID(transaction.AccountID, accountID) {
			out = append(out, transaction)
		}
	}
	return out
}

// TransactionsFor returns every transaction involving a symbol.
func (p Portfolio) TransactionsFor(symbol string) []Transaction {
	normalized := NormalizeSymbol(symbol)
	out := make([]Transaction, 0, 8)
	for _, transaction := range p.Transactions {
		if transaction.TickerSymbol() == normalized {
			out = append(out, transaction)
		}
	}
	return out
}

// TrackedSharesHeld sums shares of a symbol across the WHOLE ledger, with no
// as-of cutoff, and may go negative. That is deliberate: positions clamp at
// zero, and a short position must stay visible in the "ends up SHORT" warning.
func (p Portfolio) TrackedSharesHeld(accountID, symbol string) decimal.Decimal {
	total := decimal.Zero
	normalized := NormalizeSymbol(symbol)
	for _, transaction := range p.Transactions {
		if !sameID(transaction.AccountID, accountID) {
			continue
		}
		switch transaction.Kind.Type {
		case KindStockPurchase:
			if transaction.Kind.Stock != nil && transaction.Kind.Stock.Ticker == normalized {
				total = total.Add(transaction.Kind.Stock.Shares)
			}
		case KindStockSale:
			if transaction.Kind.Stock != nil && transaction.Kind.Stock.Ticker == normalized {
				total = total.Sub(transaction.Kind.Stock.Shares)
			}
		}
	}
	return total
}

// sameID compares two UUID strings. Ids are stored upper-cased but typed by
// hand, so comparison ignores case the way the Swift UUID comparison does.
func sameID(a, b string) bool {
	return strings.EqualFold(strings.TrimSpace(a), strings.TrimSpace(b))
}
