package market

import (
	"dit/internal/decimal"
	"dit/internal/model"
	"testing"
)

func TestCSVSwiftShapeAndDateRollover(t *testing.T) {
	entries, problems := ParseCSV("# ignored\n\nSymbol,Date,Price\nX,2024-02-31,2xyz\nX,2024-01-01,1,observed\nX,,2024-01-01,3\n")
	if len(entries) != 2 || len(problems) != 1 {
		t.Fatalf("entries %v problems %v", entries, problems)
	}
	if entries[0].Point.Day.String() != "2024-03-02" || entries[0].Point.Price.String() != "2" {
		t.Fatal("Foundation date/decimal leniency differs")
	}
	if problems[0] != "line 4: expected 'SYMBOL,YYYY-MM-DD,PRICE', got 'X,2024-01-01,1,observed'" {
		t.Fatal(problems)
	}
}
func TestMergeRealWinsAndEmptyFetchWatermark(t *testing.T) {
	d, _ := model.ParseDay("2024-06-17")
	data := model.MarketData{Series: map[string]*model.PriceSeries{"X": {Symbol: "X", Currency: model.CAD, Points: []model.DailyPrice{{Day: d, Price: decimal.FromInt(1), Via: "derived via S"}}}}}
	if n := Merge(&data, "X", model.USD, []model.DailyPrice{{Day: d, Price: decimal.FromInt(2)}, {Day: d, Price: decimal.FromInt(3)}}, nil); n != 2 {
		t.Fatal(n)
	}
	Merge(&data, "X", model.USD, []model.DailyPrice{{Day: d, Price: decimal.FromInt(4)}}, nil)
	if data.Series["X"].Points[0].Price.String() != "3" || data.Series["X"].Currency != model.CAD {
		t.Fatal("real/currency changed")
	}
	through := d + 86400
	Merge(&data, "X", model.CAD, nil, &through)
	if *data.Series["X"].CoveredThrough != through {
		t.Fatal("empty successful fetch must advance watermark")
	}
}
