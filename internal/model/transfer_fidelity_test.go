package model

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestTransactionPreservesPersistedInstant(t *testing.T) {
	raw := []byte(`{"id":"AAAAAAAA-0000-0000-0000-000000000001","accountID":"11111111-1111-1111-1111-111111111111","date":813280832.259397,"currency":"CAD","kind":{"deposit":{"amount":1}}}`)
	var tx Transaction
	if err := json.Unmarshal(raw, &tx); err != nil {
		t.Fatal(err)
	}
	if int64(tx.Date) != DayStartUTC(int64(tx.Date)) {
		t.Fatal("calculation date must remain a calendar day")
	}
	encoded, err := json.Marshal(tx)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(encoded, []byte(`"date":813280832.259397`)) {
		t.Fatalf("lost persisted instant: %s", encoded)
	}
	tx.Date += 86400
	encoded, err = json.Marshal(tx)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encoded, []byte(`813280832.259397`)) {
		t.Fatal("date edit retained stale instant")
	}
}

func TestMarketPreservesPersistedUpdatedAt(t *testing.T) {
	var market MarketData
	if err := json.Unmarshal([]byte(`{"updatedAt":813280896.210004,"latestQuotes":[],"latestRates":[],"series":{}}`), &market); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(market)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(encoded, []byte(`"updatedAt":813280896.210004`)) {
		t.Fatalf("lost timestamp precision: %s", encoded)
	}
	changed := *market.UpdatedAt + 1
	market.UpdatedAt = &changed
	encoded, err = json.Marshal(market)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encoded, []byte(`813280896.210004`)) {
		t.Fatal("updatedAt edit retained stale timestamp")
	}
}
