package model

import (
	"encoding/json"
	"time"
)

// TransactionInstant preserves a new entry's actual instant, just as decoded
// Swift entries preserve theirs. Calculations still use the UTC calendar day.
func TransactionInstant(tx Transaction, instant time.Time) Transaction {
	tx.Date = DayFromUnix(instant.Unix())
	tx.decodedDay = tx.Date
	tx.storedDate, _ = json.Marshal(float64(instant.Unix()-ReferenceDelta) + float64(instant.Nanosecond())/1e9)
	return tx
}

// TransactionStamp exposes the persisted instant for replay ordering. Date is
// a calendar projection and must not decide order between same-day entries.
func TransactionStamp(tx Transaction) Stamp {
	if tx.storedDate != nil && tx.Date == tx.decodedDay {
		var stamp Stamp
		if json.Unmarshal(tx.storedDate, &stamp) == nil {
			return stamp
		}
	}
	return Stamp(tx.Date)
}

// TransactionDate makes an explicit date correction UTC midnight, including
// when it names the same day as a previously stored non-midnight instant.
func TransactionDate(tx Transaction, day Day) Transaction {
	tx.Date = day
	tx.storedDate = nil
	return tx
}
