package store

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
)

// NewFileStore builds the directory backend: one "<key>.dat" file per key,
// written through a temporary file and renamed.
//
// The rename is the point. A crash halfway through a save then leaves either
// the old file or the new one, never half of either — which is the difference
// between "run it again" and "restore from backup".
func NewFileStore(directory string) (Store, error) {
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return Store{}, &Error{Key: "<directory>",
			Message: fmt.Sprintf("cannot create the store directory %s: %v", directory, err)}
	}
	path := func(key string) string {
		return filepath.Join(directory, SanitizeKey(key)+".dat")
	}

	return Store{
		Location: directory,
		Load: func(key string) ([]byte, error) {
			payload, err := os.ReadFile(path(key))
			if err != nil {
				if os.IsNotExist(err) {
					return nil, nil
				}
				return nil, &Error{Key: key, Message: err.Error()}
			}
			return payload, nil
		},
		Save: func(key string, payload []byte) error {
			temporary, err := os.CreateTemp(directory, ".saving-*")
			if err != nil {
				return &Error{Key: key, Message: err.Error()}
			}
			name := temporary.Name()
			defer os.Remove(name)
			if _, err := temporary.Write(payload); err != nil {
				temporary.Close()
				return &Error{Key: key, Message: err.Error()}
			}
			if err := temporary.Close(); err != nil {
				return &Error{Key: key, Message: err.Error()}
			}
			if err := os.Rename(name, path(key)); err != nil {
				return &Error{Key: key, Message: err.Error()}
			}
			return nil
		},
		Delete: func(key string) error {
			err := os.Remove(path(key))
			if err != nil && !os.IsNotExist(err) {
				return &Error{Key: key, Message: err.Error()}
			}
			return nil
		},
		Keys: func() ([]string, error) {
			entries, err := os.ReadDir(directory)
			if err != nil {
				return nil, &Error{Key: "<directory>", Message: err.Error()}
			}
			keys := make([]string, 0, len(entries))
			for _, entry := range entries {
				name := entry.Name()
				// Anything that is not a ".dat" file stays invisible, so a
				// backup written beside the store is not mistaken for data.
				if entry.IsDir() || filepath.Ext(name) != ".dat" {
					continue
				}
				keys = append(keys, strings.TrimSuffix(name, ".dat"))
			}
			sort.Strings(keys)
			return keys, nil
		},
	}, nil
}

// SanitizeKey maps a key to a filename: anything that is not a letter, digit,
// dot, underscore or hyphen becomes "_", and an empty result becomes "_".
//
// This is a storage detail, not data, and it has to stay byte-identical to the
// Swift implementation or the two binaries would write files the other cannot
// see. Note that it is one-way ("USD/CAD" and "USD-CAD" both land on
// "USD_CAD"): that is why the market document keeps pairs inside one file
// instead of one file per pair.
func SanitizeKey(key string) string {
	var builder strings.Builder
	for _, character := range key {
		if unicode.IsLetter(character) || unicode.IsDigit(character) ||
			character == '.' || character == '_' || character == '-' {
			builder.WriteRune(character)
		} else {
			builder.WriteRune('_')
		}
	}
	if builder.Len() == 0 {
		return "_"
	}
	return builder.String()
}
