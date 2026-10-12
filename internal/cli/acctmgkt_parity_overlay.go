//go:build acctmgkt_parity

package cli

// Temporary lane-only wiring for the parity executable; the parent owns table.go.
func init() {
	for name, spec := range acctmgktSpecs {
		summarySpecs[name] = spec
	}
}
