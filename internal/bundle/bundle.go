// Package bundle implements the portable, strictly decoded bundle/1 format.
package bundle

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/google/uuid"
	"reflect"
	"sort"
	"strings"

	"dit/internal/decimal"
	"dit/internal/model"
)

const Schema = "bundle/1"

type Document struct {
	Schema    string            `json:"schema"`
	CreatedAt model.Stamp       `json:"createdAt"`
	Portfolio *model.Portfolio  `json:"portfolio,omitempty"`
	Market    *model.MarketData `json:"market,omitempty"`
}

var ErrNotBundle = fmt.Errorf("not a dit bundle — expected a JSON document with \"schema\": \"bundle/1\" (a single-account 'dit store export' file is imported with 'dit store import')")
var ErrEmpty = fmt.Errorf("the bundle carries neither a ledger nor market data — nothing to import")

func Encode(d Document) ([]byte, error) {
	if d.Schema == "" {
		d.Schema = Schema
	}
	if d.Market != nil {
		normalized := cloneMarket(*d.Market)
		d.Market = &normalized
	}
	// UseNumber keeps decimal tokens exact while sorting struct keys too.
	raw, err := json.Marshal(d)
	if err != nil {
		return nil, err
	}
	var keys any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err = decoder.Decode(&keys); err != nil {
		return nil, err
	}
	return json.MarshalIndent(keys, "", "  ")
}

func IsBundle(data []byte) bool {
	var h map[string]json.RawMessage
	if json.Unmarshal(data, &h) != nil {
		return false
	}
	_, ok := h["schema"]
	return ok
}

func Decode(data []byte) (Document, error) {
	var root map[string]json.RawMessage
	if json.Unmarshal(data, &root) != nil || root == nil {
		return Document{}, ErrNotBundle
	}
	var schema string
	if json.Unmarshal(root["schema"], &schema) != nil || bytes.Equal(root["schema"], []byte("null")) {
		return Document{}, ErrNotBundle
	}
	if schema != Schema {
		return Document{}, fmt.Errorf("unsupported bundle schema '%s' — this build reads 'bundle/1' only", schema)
	}
	d, err := decode(root)
	if err != nil {
		return Document{}, fmt.Errorf("this says it is a bundle but part of it cannot be read (%s) — refusing to import a store that quietly holds less than the file does", err)
	}
	return d, nil
}

func decode(root map[string]json.RawMessage) (Document, error) {
	d := Document{Schema: Schema}
	if err := field(root, "createdAt", "the document.createdAt", &d.CreatedAt, true); err != nil {
		return d, err
	}
	if present(root["portfolio"]) {
		p, err := DecodePortfolio(root["portfolio"])
		if err != nil {
			return d, err
		}
		d.Portfolio = &p
	}
	if present(root["market"]) {
		m, err := decodeMarket(root["market"])
		if err != nil {
			return d, err
		}
		d.Market = &m
	}
	return d, nil
}

// DecodePortfolio adds file strictness without changing the live store reader.
func DecodePortfolio(raw []byte) (model.Portfolio, error) {
	var p model.Portfolio
	root, err := object(raw, "portfolio")
	if err != nil {
		return p, err
	}
	for _, section := range []string{"accounts", "transactions", "tickers"} {
		rr, err := rows(root[section], "portfolio."+section)
		if err != nil {
			return p, err
		}
		for i, raw := range rr {
			path := fmt.Sprintf("portfolio.%s[%d]", section, i)
			r, err := object(raw, path)
			if err != nil {
				return p, err
			}
			switch section {
			case "accounts":
				var value string
				if err = field(r, "id", path+".id", &value, true); err != nil {
					return p, err
				}
				if _, err = uuid.Parse(value); err != nil {
					return p, fmt.Errorf("%s.id: invalid UUID", path)
				}
			case "tickers":
				var symbol string
				if err = field(r, "symbol", path+".symbol", &symbol, true); err != nil {
					return p, err
				}
			case "transactions":
				for _, key := range []string{"id", "accountID"} {
					var value string
					if err = field(r, key, path+"."+key, &value, true); err != nil {
						return p, err
					}
					if _, err = uuid.Parse(value); err != nil {
						return p, fmt.Errorf("%s.%s: invalid UUID", path, key)
					}
				}
				var fee decimal.Decimal
				if err = field(r, "fee", path+".fee", &fee, false); err != nil {
					return p, err
				}
				var day model.Day
				var currency model.Currency
				if err = field(r, "date", path+".date", &day, true); err != nil {
					return p, err
				}
				if err = field(r, "currency", path+".currency", &currency, true); err != nil {
					return p, err
				}
				kind, err := object(r["kind"], path+".kind")
				if err != nil {
					return p, err
				}
				if len(kind) != 1 {
					return p, fmt.Errorf("%s.kind: expected one event", path)
				}
				for name, body := range kind {
					payload, err := object(body, path+".kind."+name)
					if err != nil {
						return p, err
					}
					kpath := path + ".kind." + name
					if inner, ok := payload["_0"]; ok {
						payload, err = object(inner, kpath+"._0")
						if err != nil {
							return p, err
						}
						kpath += "._0"
					}
					var target any
					switch model.KindType(name) {
					case model.KindDeposit, model.KindWithdrawal:
						target = &struct {
							Amount decimal.Decimal `json:"amount"`
						}{}
					case model.KindStockPurchase, model.KindStockSale:
						target = &model.StockDetails{}
					case model.KindGICPurchase:
						target = &model.GICDetails{}
					case model.KindGICRedemption:
						target = &model.GICRedemptionDetails{}
					case model.KindDividend:
						target = &model.DividendDetails{}
					case model.KindFXConversion:
						target = &model.FXDetails{}
					default:
						return p, fmt.Errorf("%s: unknown event", kpath)
					}
					v := reflect.ValueOf(target).Elem()
					typ := v.Type()
					for j := 0; j < typ.NumField(); j++ {
						key := strings.Split(typ.Field(j).Tag.Get("json"), ",")[0]
						if err = field(payload, key, kpath+"."+key, v.Field(j).Addr().Interface(), true); err != nil {
							return p, err
						}
					}
					if name == string(model.KindGICPurchase) {
						switch target.(*model.GICDetails).Compounding {
						case model.Simple, model.Annual, model.SemiAnnual, model.Monthly, model.Daily:
						default:
							return p, fmt.Errorf("%s.compounding: unknown value", kpath)
						}
					}
					if name == string(model.KindGICRedemption) {
						if _, err = uuid.Parse(target.(*model.GICRedemptionDetails).PurchaseID); err != nil {
							return p, fmt.Errorf("%s.purchaseID: invalid UUID", kpath)
						}
					}
				}
			}
		}
	}
	err = json.Unmarshal(raw, &p)
	if err == nil {
		for i := range p.Accounts {
			p.Accounts[i].ID = id(p.Accounts[i].ID)
		}
		for i := range p.Transactions {
			p.Transactions[i].ID = id(p.Transactions[i].ID)
			p.Transactions[i].AccountID = id(p.Transactions[i].AccountID)
			if p.Transactions[i].Kind.Redemption != nil {
				p.Transactions[i].Kind.Redemption.PurchaseID = id(p.Transactions[i].Kind.Redemption.PurchaseID)
			}
		}
	}
	return p, err
}

func present(raw json.RawMessage) bool { return len(raw) != 0 && !bytes.Equal(raw, []byte("null")) }
func object(raw json.RawMessage, path string) (map[string]json.RawMessage, error) {
	var o map[string]json.RawMessage
	if err := json.Unmarshal(raw, &o); err != nil || o == nil {
		return nil, fmt.Errorf("%s: expected Dictionary<String, Any>", path)
	}
	return o, nil
}
func field(o map[string]json.RawMessage, key, path string, target any, required bool) error {
	raw := o[key]
	if !present(raw) {
		if required {
			if len(raw) == 0 {
				return fmt.Errorf("%s: no such field", path)
			}
			return fmt.Errorf("%s: no value", path)
		}
		return nil
	}
	typ := reflect.TypeOf(target)
	for typ.Kind() == reflect.Pointer {
		typ = typ.Elem()
	}
	if typ == reflect.TypeOf(decimal.Decimal{}) && raw[0] == '"' {
		return fmt.Errorf("%s: expected NSDecimal", path)
	}
	if (typ == reflect.TypeOf(model.Day(0)) || typ == reflect.TypeOf(model.Stamp(0))) && raw[0] == '"' {
		return fmt.Errorf("%s: expected number", path)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("%s: %v", path, err)
	}
	return nil
}
func rows(raw json.RawMessage, path string) ([]json.RawMessage, error) {
	if !present(raw) {
		return []json.RawMessage{}, nil
	}
	var r []json.RawMessage
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("%s: expected Array<Any>", path)
	}
	return r, nil
}

func decodeMarket(raw json.RawMessage) (model.MarketData, error) {
	m := model.MarketData{LatestQuotes: []model.MarketQuote{}, LatestRates: []model.ExchangeRate{}, Series: map[string]*model.PriceSeries{}}
	o, err := object(raw, "market")
	if err != nil {
		return m, err
	}
	var updated model.Stamp
	if present(o["updatedAt"]) && field(o, "updatedAt", "market.updatedAt", &updated, false) == nil {
		m.UpdatedAt = &updated
	}
	for _, section := range []string{"latestQuotes", "latestRates"} {
		rr, err := rows(o[section], "market."+section)
		if err != nil {
			return m, err
		}
		for i, raw := range rr {
			path := fmt.Sprintf("market.%s[%d]", section, i)
			r, err := object(raw, path)
			if err != nil {
				return m, err
			}
			currency := model.Unknown
			var asOf *model.Stamp
			var source *string
			if field(r, "asOf", path+".asOf", &asOf, false) != nil {
				asOf = nil
			}
			if field(r, "source", path+".source", &source, false) != nil {
				source = nil
			}
			if section == "latestQuotes" {
				var symbol string
				var price decimal.Decimal
				if err = field(r, "symbol", path+".symbol", &symbol, true); err != nil {
					return m, err
				}
				if err = field(r, "price", path+".price", &price, true); err != nil {
					return m, err
				}
				if err = field(r, "currency", path+".currency", &currency, false); err != nil {
					return m, err
				}
				m.LatestQuotes = append(m.LatestQuotes, model.MarketQuote{Symbol: model.NormalizeSymbol(symbol), Currency: currency, Price: price, AsOf: asOf, Source: source})
			} else {
				var base, quote model.Currency
				var rate decimal.Decimal
				for _, f := range []struct {
					k string
					v any
				}{{"base", &base}, {"quote", &quote}, {"rate", &rate}} {
					if err = field(r, f.k, path+"."+f.k, f.v, true); err != nil {
						return m, err
					}
				}
				m.LatestRates = append(m.LatestRates, model.ExchangeRate{Base: base, Quote: quote, Rate: rate, AsOf: asOf, Source: source})
			}
		}
	}
	if present(o["series"]) {
		ss, err := object(o["series"], "market.series")
		if err != nil {
			return m, err
		}
		keys := make([]string, 0, len(ss))
		for k := range ss {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			path := "market.series." + k
			r, err := object(ss[k], path)
			if err != nil {
				return m, err
			}
			s := model.PriceSeries{Currency: model.Unknown, Points: []model.DailyPrice{}}
			if err = field(r, "symbol", path+".symbol", &s.Symbol, true); err != nil {
				return m, err
			}
			if err = field(r, "currency", path+".currency", &s.Currency, false); err != nil {
				return m, err
			}
			if err = field(r, "coveredThrough", path+".coveredThrough", &s.CoveredThrough, false); err != nil {
				return m, err
			}
			if !present(r["points"]) {
				return m, fmt.Errorf("%s.points: no such field", path)
			}
			pp, err := rows(r["points"], path+".points")
			if err != nil {
				return m, err
			}
			for i, raw := range pp {
				ppath := fmt.Sprintf("%s.points[%d]", path, i)
				p, err := object(raw, ppath)
				if err != nil {
					return m, err
				}
				var point model.DailyPrice
				if err = field(p, "day", ppath+".day", &point.Day, true); err != nil {
					return m, err
				}
				if err = field(p, "price", ppath+".price", &point.Price, true); err != nil {
					return m, err
				}
				if err = field(p, "via", ppath+".via", &point.Via, false); err != nil {
					return m, err
				}
				s.Points = append(s.Points, point)
			}
			byDay := map[model.Day]model.DailyPrice{}
			for _, point := range s.Points {
				byDay[point.Day] = point
			}
			s.Points = []model.DailyPrice{}
			for _, point := range byDay {
				s.Points = append(s.Points, point)
			}
			sort.Slice(s.Points, func(i, j int) bool { return s.Points[i].Day < s.Points[j].Day })
			m.Series[k] = &s
		}
	}
	return m, nil
}
