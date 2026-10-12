package cli

import (
	"strings"

	"dit/internal/model"
)

// accounts prints the account listing: name, institution, currency, tax status
// and whether the account is still open.
func accountsListing(context Context, arguments []string) error {
	// The Swift `accounts` command ignores trailing arguments and unknown
	// options. Keep that permissive behavior for compatibility.
	portfolio, err := context.Ledger()
	if err != nil {
		return err
	}
	if context.JSON {
		// accounts/1 (docs/json.md): every row always carries institution
		// and number (null when unset), opened only when the account has
		// one, and an uppercase id — Swift emits exactly these keys through
		// JSONSerialization with sortedKeys, and dit-chart parses them.
		// A missing store answers with the empty list plus a note; that is
		// still "ok", not an error.
		rows := make([]any, 0, 8)
		if portfolio != nil {
			for _, account := range portfolio.Accounts {
				row := map[string]any{
					"currency": string(account.ReportingCurrency),
					"id":       strings.ToUpper(account.ID),
					"name":     DisplayName(account),
					"taxable":  account.Taxable,
				}
				if account.Institution != nil {
					row["institution"] = *account.Institution
				} else {
					row["institution"] = nil
				}
				if account.AccountNumber != nil {
					row["number"] = *account.AccountNumber
				} else {
					row["number"] = nil
				}
				status := "open"
				if account.ClosedDate != nil {
					status = "closed " + account.ClosedDate.String()
				}
				row["status"] = status
				if account.OpenedDate != nil {
					row["opened"] = account.OpenedDate.String()
				}
				rows = append(rows, row)
			}
		}
		data := map[string]any{"accounts": rows}
		if portfolio == nil {
			data["note"] = "no portfolio found"
		}
		return context.WriteJSON(map[string]any{"ok": true, "schema": "accounts/1", "data": data})
	}
	if portfolio == nil {
		context.printf("No portfolio found (store: %s at %s).\n", context.Layout.Backend, context.PortfolioLocation())
		context.printf("Add accounts and transactions first.\n")
		return nil
	}
	if len(portfolio.Accounts) == 0 {
		context.printf("The portfolio has no accounts yet.\n")
		return nil
	}
	context.printf("Accounts:\n")
	rows := make([][]string, 0, len(portfolio.Accounts))
	for _, account := range portfolio.Accounts {
		status := ""
		if account.ClosedDate != nil {
			status = "closed " + account.ClosedDate.String()
		}
		taxable := "no"
		if account.Taxable {
			taxable = "yes"
		}
		rows = append(rows, []string{
			DisplayName(account),
			OrEmpty(account.Institution),
			string(account.ReportingCurrency),
			taxable,
			status,
		})
	}
	for _, line := range Table(context, []string{"Name", "Institution", "Ccy", "Taxable", "Status"}, rows) {
		context.printf("  %s\n", line)
	}
	return nil
}

// DisplayName is the listing name: the account's own name when it has one,
// otherwise a short form of its id, so a nameless account is still traceable
// to a record.
func DisplayName(account model.Account) string {
	if account.Name != nil {
		name := strings.TrimSpace(*account.Name)
		if name != "" {
			return name
		}
	}
	id := strings.ReplaceAll(account.ID, "-", "")
	if len(id) > 4 {
		id = id[:4]
	}
	return "Account " + id
}

// OrEmpty unwraps an optional string for display.
func OrEmpty(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
