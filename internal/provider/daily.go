package provider

import (
	"dit/internal/decimal"
	"dit/internal/model"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
)

// Uses Yahoo's existing configured transport, never a second HTTP client.
func yahooDaily(cfg YahooConfig, do func(*http.Request) (*http.Response, error), symbol string, from, to model.Day) (DailySeries, error) {
	out := DailySeries{Symbol: symbol, Currency: model.Unknown, Points: []model.DailyPrice{}}
	endpoint := cfg.BaseURL + "/v8/finance/chart/" + url.PathEscape(symbol) + "?period1=" + strconv.FormatInt(int64(from), 10) + "&period2=" + strconv.FormatInt(int64(to)+86400, 10) + "&interval=1d"
	req, err := http.NewRequest("GET", endpoint, nil)
	if err != nil {
		return out, err
	}
	req.Header.Set("User-Agent", cfg.UserAgent)
	req.Header.Set("Accept", "application/json")
	resp, err := do(req)
	if err != nil {
		return out, &Error{Kind: "network", Message: err.Error()}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return out, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return out, &Error{Kind: "http", Message: strconv.Itoa(resp.StatusCode)}
	}
	var wire struct {
		Chart *struct {
			Result []struct {
				Meta struct {
					Currency string `json:"currency"`
				} `json:"meta"`
				Timestamp  []*int64 `json:"timestamp"`
				Indicators struct {
					Quote []struct {
						Close []*json.Number `json:"close"`
					} `json:"quote"`
				} `json:"indicators"`
			} `json:"result"`
			Error *struct {
				Code        string
				Description string
			} `json:"error"`
		} `json:"chart"`
	}
	if err = json.Unmarshal(body, &wire); err != nil {
		return out, &Error{Kind: "decoding", Message: err.Error()}
	}
	if wire.Chart == nil {
		return out, &Error{Kind: "decoding", Message: "response has no 'chart' section"}
	}
	if wire.Chart.Error != nil {
		return out, &Error{Kind: "noData", Symbol: symbol, Message: wire.Chart.Error.Description}
	}
	if len(wire.Chart.Result) == 0 {
		return out, &Error{Kind: "noData", Symbol: symbol, Message: "no chart result in response"}
	}
	r := wire.Chart.Result[0]
	out.Currency = parseCurrency(r.Meta.Currency)
	byDay := map[model.Day]model.DailyPrice{}
	if len(r.Indicators.Quote) > 0 {
		for i, c := range r.Indicators.Quote[0].Close {
			if i >= len(r.Timestamp) || c == nil || r.Timestamp[i] == nil {
				continue
			}
			p, e := decimal.Parse(c.String())
			if e != nil || p.Sign() <= 0 {
				continue
			}
			d := model.DayFromUnix(*r.Timestamp[i])
			byDay[d] = model.DailyPrice{Day: d, Price: p}
		}
	}
	for _, p := range byDay {
		out.Points = append(out.Points, p)
	}
	sort.Slice(out.Points, func(i, j int) bool { return out.Points[i].Day < out.Points[j].Day })
	return out, nil
}
