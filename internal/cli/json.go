package cli

import (
	"bytes"
	"encoding/json"
)

// Machine output follows a contract, not an whim (docs/json.md): sorted keys,
// no thousands separators, decimals written as numbers.
//
// Sorted keys matter for more than tidiness. Two runs of the same command must
// produce the same bytes, or every consumer that diffs output goes noisy. The
// Swift side sets .sortedKeys for the same reason, and its *store files* leave
// dictionary order to the hash seed — which is why store files are not
// comparable between runs while --json output must be.
func jsonDocument(document any) (string, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	// HTML escaping would turn a "&" in a note into \u0026, which the Swift
	// side does not do; keep the bytes identical.
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(document); err != nil {
		return "", err
	}
	// Encode appends a newline; the Swift side prints exactly one line per
	// document, so trim it here and let the caller decide the line ending.
	return string(bytes.TrimRight(buffer.Bytes(), "\n")), nil
}

// WriteJSON prints one machine document. A value that cannot be encoded is a
// bug in the command, and it is reported as one rather than printing a partial
// document that looks like an answer.
func (c Context) WriteJSON(document any) error {
	payload, err := jsonDocument(document)
	if err != nil {
		return Runtime("internal: unserializable JSON document")
	}
	c.printf("%s\n", payload)
	return nil
}

// WriteJSONFailure prints a failed machine-mode answer.
func (c Context) WriteJSONFailure(kind, message string) {
	// Flat keys, sorted: {"error":…,"kind":…,"ok":false}.
	payload, err := jsonDocument(map[string]any{
		"error": message,
		"kind":  kind,
		"ok":    false,
	})
	if err != nil {
		payload = `{"error":"internal: unserializable JSON document","kind":"runtime","ok":false}`
	}
	c.printf("%s\n", payload)
}

// MoneyText and QuantityText are the non-grouped machine forms of a number:
// exactly `scale` places for money, trailing zeros trimmed for a quantity.
// Parsers must see "279900.60", never "279,900.60" and never a binary double.
