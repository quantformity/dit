package model

import (
	"encoding/json"
	"testing"
	"time"
)

func TestTransactionWriteInstantAndExplicitSameDayCorrection(t *testing.T) {
	instant := time.Date(2024, 1, 2, 3, 4, 5, 123000000, time.UTC)
	tx := TransactionInstant(Transaction{ID: "11111111-2222-4333-8444-555555555555", AccountID: "A", Currency: CAD, Kind: Kind{Type: KindDeposit}}, instant)
	raw, err := json.Marshal(tx)
	if err != nil {
		t.Fatal(err)
	}
	var wire struct{ Date float64 }
	if err = json.Unmarshal(raw, &wire); err != nil {
		t.Fatal(err)
	}
	want := float64(instant.Unix()-ReferenceDelta) + 0.123
	if wire.Date != want {
		t.Fatalf("lost instant: %.9f vs %.9f", wire.Date, want)
	}
	if TransactionStamp(tx) <= Stamp(tx.Date) {
		t.Fatal("replay accessor lost time of day")
	}
	edited := TransactionDate(tx, tx.Date)
	if TransactionStamp(edited) != Stamp(tx.Date) {
		t.Fatal("date correction not midnight")
	}
	raw, err = json.Marshal(edited)
	if err != nil {
		t.Fatal(err)
	}
	json.Unmarshal(raw, &wire)
	if wire.Date != ToReference(int64(tx.Date)) {
		t.Fatal("explicit same-day correction retained time")
	}
	raw, _ = json.Marshal(tx)
	json.Unmarshal(raw, &wire)
	if wire.Date != want {
		t.Fatal("value correction changed original")
	}
}
