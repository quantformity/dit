package model

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"dit/internal/decimal"
)

// Account is a place where money is held. It is metadata: positions live in
// the transaction log, not here.
type Account struct {
	// ID is the link key every transaction points back to, so a record
	// without one is unusable and decoding fails on it.
	ID string `json:"id"`
	// ReportingCurrency is what the account's value and P&L are expressed
	// in. Missing means CAD, matching the Swift default.
	ReportingCurrency Currency `json:"reportingCurrency"`
	Name              *string  `json:"name,omitempty"`
	Institution       *string  `json:"institution,omitempty"`
	AccountNumber     *string  `json:"accountNumber,omitempty"`
	// Taxable defaults to TRUE when the key is absent: an account is
	// treated as taxable until someone says otherwise.
	Taxable    bool    `json:"taxable"`
	OpenedDate *Day    `json:"openedDate,omitempty"`
	ClosedDate *Day    `json:"closedDate,omitempty"`
	Notes      *string `json:"notes,omitempty"`
}

// IsActive reports whether the account still holds anything.
func (a Account) IsActive() bool { return a.ClosedDate == nil }

// accountWire exists so absent keys can fall back to Swift's defaults instead
// of Go's zero values: a missing "taxable" means true, a missing
// "reportingCurrency" means CAD.
type accountWire struct {
	ID                string  `json:"id"`
	ReportingCurrency *string `json:"reportingCurrency"`
	Name              *string `json:"name"`
	Institution       *string `json:"institution"`
	AccountNumber     *string `json:"accountNumber"`
	Taxable           *bool   `json:"taxable"`
	OpenedDate        *Day    `json:"openedDate"`
	ClosedDate        *Day    `json:"closedDate"`
	Notes             *string `json:"notes"`
}

// UnmarshalJSON decodes with the Swift defaults: only the id is required.
func (a *Account) UnmarshalJSON(data []byte) error {
	var wire accountWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	if strings.TrimSpace(wire.ID) == "" {
		return fmt.Errorf("account record has no id")
	}
	a.ID = wire.ID
	a.ReportingCurrency = CAD
	if wire.ReportingCurrency != nil && *wire.ReportingCurrency != "" {
		a.ReportingCurrency = Currency(*wire.ReportingCurrency)
	}
	a.Name, a.Institution, a.AccountNumber, a.Notes = wire.Name, wire.Institution, wire.AccountNumber, wire.Notes
	a.Taxable = true
	if wire.Taxable != nil {
		a.Taxable = *wire.Taxable
	}
	a.OpenedDate, a.ClosedDate = wire.OpenedDate, wire.ClosedDate
	return nil
}

// EquityTicker is a registry entry: display metadata for a listed instrument.
// The symbol is the identity, and it doubles as the provider's quote key.
//
// Entries are optional enrichment. A trade for an unregistered symbol works;
// the registry only adds a name, a trading currency and tags.
type EquityTicker struct {
	Symbol   string   `json:"symbol"`
	Name     *string  `json:"name,omitempty"`
	Currency Currency `json:"currency"`
	// Tags is a set in Swift, which means order carries no meaning; it is
	// kept sorted here so a written file is stable.
	Tags  []string `json:"tags"`
	Notes *string  `json:"notes,omitempty"`
}

type tickerWire struct {
	Symbol   string   `json:"symbol"`
	Name     *string  `json:"name"`
	Currency *string  `json:"currency"`
	Tags     []string `json:"tags"`
	Notes    *string  `json:"notes"`
}

// UnmarshalJSON decodes leniently: only the symbol is load-bearing. A missing
// currency means Unknown and missing tags mean none, so a file written before
// a field existed still loads.
func (t *EquityTicker) UnmarshalJSON(data []byte) error {
	var wire tickerWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	if strings.TrimSpace(wire.Symbol) == "" {
		return fmt.Errorf("ticker record has no symbol")
	}
	t.Symbol = NormalizeSymbol(wire.Symbol)
	t.Name, t.Notes = wire.Name, wire.Notes
	t.Currency = Unknown
	if wire.Currency != nil && *wire.Currency != "" {
		t.Currency = Currency(*wire.Currency)
	}
	seen := map[string]bool{}
	t.Tags = []string{}
	for _, tag := range wire.Tags {
		tag = strings.TrimSpace(tag)
		if tag != "" && !seen[tag] {
			seen[tag] = true
			t.Tags = append(t.Tags, tag)
		}
	}
	sort.Strings(t.Tags)
	return nil
}

// MarshalJSON writes tags as a JSON array, empty rather than absent, matching
// what the Swift encoder emits for an empty set.
func (t EquityTicker) MarshalJSON() ([]byte, error) {
	tags := t.Tags
	if tags == nil {
		tags = []string{}
	}
	return json.Marshal(struct {
		Symbol   string   `json:"symbol"`
		Name     *string  `json:"name,omitempty"`
		Currency Currency `json:"currency"`
		Tags     []string `json:"tags"`
		Notes    *string  `json:"notes,omitempty"`
	}{t.Symbol, t.Name, t.Currency, tags, t.Notes})
}

// NormalizeSymbol is the single normalization point: trimmed and upper-cased,
// so " shop.to " matches "SHOP.TO" everywhere (registry, filters, P&L).
func NormalizeSymbol(symbol string) string {
	return strings.ToUpper(strings.TrimSpace(symbol))
}

// GICCompounding is how a GIC's stated annual rate compounds.
type GICCompounding string

const (
	Simple     GICCompounding = "simple"
	Annual     GICCompounding = "annual"
	SemiAnnual GICCompounding = "semiAnnual"
	Monthly    GICCompounding = "monthly"
	Daily      GICCompounding = "daily"
)

// StockDetails stores the two facts measured at a trade. The total is derived
// (shares × price), never stored: three numbers that must agree with each
// other are a consistency problem waiting to happen.
type StockDetails struct {
	Ticker string          `json:"ticker"`
	Shares decimal.Decimal `json:"shares"`
	Price  decimal.Decimal `json:"price"`
}

// Amount is the total trade value.
func (s StockDetails) Amount() decimal.Decimal { return s.Shares.Mul(s.Price) }

// GICDetails are the contract terms, recorded at purchase. A GIC is a private
// contract, not a market instrument: its rate and term are fixed when created
// and never go stale, so they belong on the purchase transaction.
type GICDetails struct {
	Product      string          `json:"product"`
	Principal    decimal.Decimal `json:"principal"`
	Rate         decimal.Decimal `json:"rate"`
	Compounding  GICCompounding  `json:"compounding"`
	MaturityDate Day             `json:"maturityDate"`
	Redeemable   bool            `json:"redeemable"`
}

// GICRedemptionDetails records what was actually received, which may differ
// from the computed maturity value after an early-redemption penalty.
type GICRedemptionDetails struct {
	PurchaseID string          `json:"purchaseID"`
	Proceeds   decimal.Decimal `json:"proceeds"`
}

// DividendDetails is a cash dividend received from a holding.
type DividendDetails struct {
	Ticker string          `json:"ticker"`
	Amount decimal.Decimal `json:"amount"`
}

// FXDetails stores both measured legs of a currency exchange. The implied
// rate (spread included) is derived from them, never entered.
type FXDetails struct {
	FromCurrency Currency        `json:"fromCurrency"`
	FromAmount   decimal.Decimal `json:"fromAmount"`
	ToAmount     decimal.Decimal `json:"toAmount"`
}

// KindType names the event. It doubles as the JSON tag the Swift encoder uses.
type KindType string

const (
	KindDeposit       KindType = "deposit"
	KindWithdrawal    KindType = "withdrawal"
	KindStockPurchase KindType = "stockPurchase"
	KindStockSale     KindType = "stockSale"
	KindGICPurchase   KindType = "gicPurchase"
	KindGICRedemption KindType = "gicRedemption"
	KindDividend      KindType = "dividend"
	KindFXConversion  KindType = "fxConversion"
)

// Kind is what type of event a transaction was, plus its payload. It mirrors
// the Swift enum: exactly one payload field is set.
type Kind struct {
	Type       KindType              `json:"type"`
	Amount     decimal.Decimal       `json:"amount,omitempty"`
	Stock      *StockDetails         `json:"stock,omitempty"`
	GIC        *GICDetails           `json:"gic,omitempty"`
	Redemption *GICRedemptionDetails `json:"redemption,omitempty"`
	Dividend   *DividendDetails      `json:"dividend,omitempty"`
	FX         *FXDetails            `json:"fx,omitempty"`
}

// Transaction is a single financial event.
//
// Transactions are the source of truth: holdings, balances and P&L are all
// derived from this log and never stored separately. Amounts live inside the
// kind because "amount" means different things per event, and direction comes
// from the kind rather than the sign.
type Transaction struct {
	// Keep the persisted instant while Date remains a calendar day for calculations.
	storedDate json.RawMessage
	decodedDay Day
	ID         string           `json:"id"`
	Date       Day              `json:"date"`
	AccountID  string           `json:"accountID"`
	Currency   Currency         `json:"currency"`
	Kind       Kind             `json:"kind"`
	Fee        *decimal.Decimal `json:"fee,omitempty"`
	Notes      *string          `json:"notes,omitempty"`
	ExternalID *string          `json:"externalID,omitempty"`
}

// Amount is the notional value of the transaction in its currency.
func (t Transaction) Amount() decimal.Decimal {
	switch t.Kind.Type {
	case KindDeposit, KindWithdrawal:
		return t.Kind.Amount
	case KindStockPurchase, KindStockSale:
		if t.Kind.Stock != nil {
			return t.Kind.Stock.Amount()
		}
	case KindGICPurchase:
		if t.Kind.GIC != nil {
			return t.Kind.GIC.Principal
		}
	case KindGICRedemption:
		if t.Kind.Redemption != nil {
			return t.Kind.Redemption.Proceeds
		}
	case KindDividend:
		if t.Kind.Dividend != nil {
			return t.Kind.Dividend.Amount
		}
	case KindFXConversion:
		if t.Kind.FX != nil {
			return t.Kind.FX.ToAmount
		}
	}
	return decimal.Zero
}

// CashImpact is the effect on the account's cash, fees included: positive
// adds cash, negative removes it.
func (t Transaction) CashImpact() decimal.Decimal {
	fee := decimal.Zero
	if t.Fee != nil {
		fee = *t.Fee
	}
	switch t.Kind.Type {
	case KindDeposit:
		return t.Kind.Amount
	case KindWithdrawal:
		return t.Kind.Amount.Neg()
	case KindStockPurchase:
		if t.Kind.Stock != nil {
			return t.Kind.Stock.Amount().Add(fee).Neg()
		}
	case KindStockSale:
		if t.Kind.Stock != nil {
			return t.Kind.Stock.Amount().Sub(fee)
		}
	case KindGICPurchase:
		if t.Kind.GIC != nil {
			return t.Kind.GIC.Principal.Add(fee).Neg()
		}
	case KindGICRedemption:
		if t.Kind.Redemption != nil {
			return t.Kind.Redemption.Proceeds.Sub(fee)
		}
	case KindDividend:
		if t.Kind.Dividend != nil {
			return t.Kind.Dividend.Amount.Sub(fee)
		}
	case KindFXConversion:
		if t.Kind.FX != nil {
			return t.Kind.FX.ToAmount.Sub(fee)
		}
	}
	return decimal.Zero
}

// TickerSymbol is the instrument involved, if any.
func (t Transaction) TickerSymbol() string {
	switch t.Kind.Type {
	case KindStockPurchase, KindStockSale:
		if t.Kind.Stock != nil {
			return t.Kind.Stock.Ticker
		}
	case KindDividend:
		if t.Kind.Dividend != nil {
			return t.Kind.Dividend.Ticker
		}
	}
	return ""
}

// kindPayload is the Swift encoding of the enum: externally tagged, with a
// single-payload case wrapped in "_0" when the associated value is unnamed.
// Both shapes appear in real files ("deposit" has no wrapper, "stockSale"
// does), so decoding accepts either and encoding reproduces each exactly.
func (t Transaction) MarshalJSON() ([]byte, error) {
	payload := any(nil)
	wrapped := true
	switch t.Kind.Type {
	case KindDeposit:
		payload, wrapped = map[string]any{"amount": t.Kind.Amount}, false
	case KindWithdrawal:
		payload, wrapped = map[string]any{"amount": t.Kind.Amount}, false
	case KindStockPurchase:
		payload = t.Kind.Stock
	case KindStockSale:
		payload = t.Kind.Stock
	case KindGICPurchase:
		payload = t.Kind.GIC
	case KindGICRedemption:
		payload = t.Kind.Redemption
	case KindDividend:
		payload = t.Kind.Dividend
	case KindFXConversion:
		payload = t.Kind.FX
	default:
		return nil, fmt.Errorf("transaction %s has no kind", t.ID)
	}
	if payload == nil {
		return nil, fmt.Errorf("transaction %s kind %s has no payload", t.ID, t.Kind.Type)
	}
	kind := map[string]any{}
	if wrapped {
		kind[string(t.Kind.Type)] = map[string]any{"_0": payload}
	} else {
		kind[string(t.Kind.Type)] = payload
	}
	date, err := t.Date.MarshalJSON()
	if err != nil {
		return nil, err
	}
	if t.storedDate != nil && t.Date == t.decodedDay {
		date = t.storedDate
	}
	out := struct {
		ID         string           `json:"id"`
		Date       json.RawMessage  `json:"date"`
		AccountID  string           `json:"accountID"`
		Currency   Currency         `json:"currency"`
		Kind       map[string]any   `json:"kind"`
		Fee        *decimal.Decimal `json:"fee,omitempty"`
		Notes      *string          `json:"notes,omitempty"`
		ExternalID *string          `json:"externalID,omitempty"`
	}{t.ID, date, t.AccountID, t.Currency, kind, t.Fee, t.Notes, t.ExternalID}
	return json.Marshal(out)
}

// UnmarshalJSON reads either payload shape. A transaction whose kind is
// missing or unknown is an error rather than a silent no-op: an event nobody
// can price must not quietly disappear from a balance.
func (t *Transaction) UnmarshalJSON(data []byte) error {
	var wire struct {
		ID         string           `json:"id"`
		Date       Day              `json:"date"`
		AccountID  string           `json:"accountID"`
		Currency   Currency         `json:"currency"`
		Kind       json.RawMessage  `json:"kind"`
		Fee        *decimal.Decimal `json:"fee"`
		Notes      *string          `json:"notes"`
		ExternalID *string          `json:"externalID"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	if strings.TrimSpace(wire.ID) == "" {
		return fmt.Errorf("transaction record has no id")
	}
	var tagged map[string]json.RawMessage
	if err := json.Unmarshal(wire.Kind, &tagged); err != nil {
		return fmt.Errorf("transaction %s: unreadable kind: %w", wire.ID, err)
	}
	if len(tagged) != 1 {
		return fmt.Errorf("transaction %s: kind must name exactly one event type", wire.ID)
	}
	var name string
	var body json.RawMessage
	for name, body = range tagged {
	}
	// Unwrap the "_0" wrapper if present.
	var unwrapped json.RawMessage
	var wrapper map[string]json.RawMessage
	if err := json.Unmarshal(body, &wrapper); err == nil && len(wrapper) == 1 {
		if inner, ok := wrapper["_0"]; ok {
			unwrapped = inner
		}
	}
	if unwrapped == nil {
		unwrapped = body
	}

	var original struct {
		Date json.RawMessage `json:"date"`
	}
	if err := json.Unmarshal(data, &original); err != nil {
		return err
	}
	t.storedDate, t.decodedDay = nil, 0
	var instant json.Number
	if json.Unmarshal(original.Date, &instant) == nil {
		seconds, err := instant.Float64()
		if err == nil && seconds != ToReference(int64(wire.Date)) {
			t.storedDate, t.decodedDay = original.Date, wire.Date
		}
	}
	t.ID, t.Date, t.AccountID = wire.ID, wire.Date, wire.AccountID
	t.Currency, t.Fee, t.Notes, t.ExternalID = wire.Currency, wire.Fee, wire.Notes, wire.ExternalID
	t.Kind.Type = KindType(name)
	var err error
	switch t.Kind.Type {
	case KindDeposit, KindWithdrawal:
		var payload struct {
			Amount decimal.Decimal `json:"amount"`
		}
		err = json.Unmarshal(unwrapped, &payload)
		t.Kind.Amount = payload.Amount
	case KindStockPurchase, KindStockSale:
		t.Kind.Stock = &StockDetails{}
		err = json.Unmarshal(unwrapped, t.Kind.Stock)
		t.Kind.Stock.Ticker = NormalizeSymbol(t.Kind.Stock.Ticker)
	case KindGICPurchase:
		t.Kind.GIC = &GICDetails{}
		err = json.Unmarshal(unwrapped, t.Kind.GIC)
	case KindGICRedemption:
		t.Kind.Redemption = &GICRedemptionDetails{}
		err = json.Unmarshal(unwrapped, t.Kind.Redemption)
	case KindDividend:
		t.Kind.Dividend = &DividendDetails{}
		err = json.Unmarshal(unwrapped, t.Kind.Dividend)
		t.Kind.Dividend.Ticker = NormalizeSymbol(t.Kind.Dividend.Ticker)
	case KindFXConversion:
		t.Kind.FX = &FXDetails{}
		err = json.Unmarshal(unwrapped, t.Kind.FX)
	default:
		return fmt.Errorf("transaction %s: unknown kind %q", wire.ID, name)
	}
	if err != nil {
		return fmt.Errorf("transaction %s: kind %s: %w", wire.ID, name, err)
	}
	return nil
}
