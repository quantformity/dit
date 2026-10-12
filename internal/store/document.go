package store

import (
	"encoding/json"

	"dit/internal/model"
)

// The two documents and their asymmetry, in one place.
//
// The ledger is read strictly: it is the source of truth, so half-reading it
// would invent a portfolio, and an "successful" run that quietly dropped
// transactions is the worst failure this tool can have.
//
// The price cache is read leniently: it can be refetched, so a damaged copy
// is a reason to go back to the provider, not a reason for every command to
// refuse to start.

// PortfolioKey is the key the ledger document lives under.
const PortfolioKey = "portfolio"

// MarketKey is the key the price document lives under.
const MarketKey = "market"

// LoadPortfolio reads the ledger. It returns nil for "nothing recorded yet",
// and an error for "something is there and it is not a ledger".
func LoadPortfolio(data Store) (*model.Portfolio, error) {
	payload, err := data.Load(PortfolioKey)
	if err != nil {
		return nil, err
	}
	if payload == nil {
		return nil, nil
	}
	var portfolio model.Portfolio
	if err := json.Unmarshal(payload, &portfolio); err != nil {
		return nil, &Error{Key: PortfolioKey,
			Message: "the portfolio store at " + data.Location + " is not readable: " + err.Error()}
	}
	return &portfolio, nil
}

// SavePortfolio replaces the ledger document.
func SavePortfolio(data Store, portfolio *model.Portfolio) error {
	payload, err := json.Marshal(portfolio)
	if err != nil {
		return &Error{Key: PortfolioKey, Message: "cannot encode the portfolio: " + err.Error()}
	}
	return data.Save(PortfolioKey, payload)
}

// EmptyMarket is the market document of a store that holds no prices.
func EmptyMarket() model.MarketData {
	return model.MarketData{
		LatestQuotes: []model.MarketQuote{},
		LatestRates:  []model.ExchangeRate{},
		Series:       map[string]*model.PriceSeries{},
	}
}

// LoadMarket reads the price cache; damage degrades to empty.
func LoadMarket(data Store) model.MarketData {
	payload, err := data.Load(MarketKey)
	if err != nil || payload == nil {
		return EmptyMarket()
	}
	market := EmptyMarket()
	if err := json.Unmarshal(payload, &market); err != nil {
		return EmptyMarket()
	}
	return market
}

// SaveMarket replaces the price cache.
func SaveMarket(data Store, market *model.MarketData) error {
	payload, err := json.Marshal(market)
	if err != nil {
		return &Error{Key: MarketKey, Message: "cannot encode the market data: " + err.Error()}
	}
	return data.Save(MarketKey, payload)
}
